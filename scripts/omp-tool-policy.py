#!/usr/bin/env python3
"""omp-tool-policy.py — render config/omp-tool-policy.yml into omp's `tools.approval`.

WHY THIS EXISTS (2026-10-14): omp approval rules take EXACT tool names — no wildcards — and a
user rule beats every approval mode (including yolo / Paseo's "Full Access" and sub-agents).
So the per-connector rules are the real enforcement of draft-only email and no sharing/deleting,
and there are dozens of them (Google alone exposes ~70 tools). Hand-typing them would drift; this
script derives them deterministically from a short policy file + the servers' live tool lists.

Inputs:
  * policy   — config/omp-tool-policy.yml: ordered fnmatch rules over "<server>:<tool>",
               plus `always_deny` names. Unmatched tools fall back on the server's own hint:
               readOnlyHint → allow, otherwise prompt.
  * tools    — omp's own cache of each connected server's tool list (agent.db, `mcp_tools:*`
               keys, read-only; nothing else in that DB is touched — it also holds credentials),
               plus optional --tools-json SERVER=FILE for a server not connected yet (so its
               rules exist BEFORE its first connection).
  * names    — minted by omp's own exported createMCPToolName (via bun), so a long name's hash
               suffix matches omp exactly instead of re-implementing it.

Merge rule: non-MCP keys in tools.approval (bash/eval/task, …) are kept as-is; MCP entries for
servers whose tools we can see are replaced; MCP entries for unseen servers are kept (a rule is
never dropped silently).

Usage:
    omp-tool-policy.py            # dry run: print what would change
    omp-tool-policy.py --apply    # write via `omp config set tools.approval …`
    omp-tool-policy.py --check    # exit 1 if the live config differs (seat check / nightly)
    omp-tool-policy.py --tools-json workspace=/path/tools.json --apply
"""
import argparse
import fnmatch
import json
import os
import sqlite3
import subprocess
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POLICY = os.path.join(REPO, "config", "omp-tool-policy.yml")
AGENT_DIR = os.path.expanduser(os.environ.get("PI_CODING_AGENT_DIR", "~/.omp/agent"))
OMP_SRC = os.path.expanduser("~/.npm-global/lib/node_modules/@oh-my-pi/pi-coding-agent/src")
BUN = os.path.expanduser("~/.bun/bin/bun")
VALID = {"allow", "prompt", "deny"}


def die(msg):
    print(f"omp-tool-policy: {msg}", file=sys.stderr)
    sys.exit(2)


def load_policy(path):
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    rules = data.get("rules") or []
    for r in rules:
        if r.get("approval") not in VALID or not r.get("match"):
            die(f"bad rule in {path}: {r}")
    return rules, list(data.get("always_deny") or [])


def cached_tools():
    """{server: [{name, readOnly}]} from omp's tool cache (read-only open)."""
    db = os.path.join(AGENT_DIR, "agent.db")
    if not os.path.exists(db):
        return {}
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    out = {}
    for key, value in con.execute("select key, value from cache where key like 'mcp_tools:%'"):
        data = json.loads(value)
        tools = data.get("tools", data) if isinstance(data, dict) else data
        out[key.split(":", 1)[1]] = [
            {"name": t["name"], "readOnly": bool((t.get("annotations") or {}).get("readOnlyHint"))}
            for t in tools
        ]
    return out


def json_tools(path):
    with open(path) as f:
        data = json.load(f)
    return [{"name": t["name"], "readOnly": bool(t.get("ro", t.get("readOnly")))} for t in data]


def mint(pairs):
    """Exact omp tool names for [(server, tool)] using omp's own createMCPToolName."""
    if not pairs:
        return []
    script = (
        f"import {{createMCPToolName}} from {json.dumps(os.path.join(OMP_SRC, 'mcp', 'tool-bridge.ts'))};"
        "const pairs = JSON.parse(await Bun.stdin.text());"
        "console.log(JSON.stringify(pairs.map(([s, t]) => createMCPToolName(s, t))));"
    )
    res = subprocess.run([BUN, "-e", script], input=json.dumps(pairs), capture_output=True,
                         text=True, cwd="/tmp", timeout=120)
    if res.returncode != 0:
        die(f"bun mint failed: {res.stderr.strip()[-400:]}")
    names = json.loads(res.stdout.strip().splitlines()[-1])
    if len(names) != len(pairs):
        die("mint returned the wrong number of names")
    return names


def decide(server, tool, read_only, rules):
    key = f"{server}:{tool}"
    for r in rules:
        if fnmatch.fnmatchcase(key, r["match"]):
            return r["approval"]
    return "allow" if read_only else "prompt"


def live_approval():
    res = subprocess.run(["omp", "config", "get", "tools.approval", "--json"],
                         capture_output=True, text=True, timeout=60)
    if res.returncode != 0:
        die(f"omp config get failed: {res.stderr.strip()}")
    data = json.loads(res.stdout)
    value = data.get("value", data) if isinstance(data, dict) and "value" in data else data
    return dict(value or {})


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--check", action="store_true")
    ap.add_argument("--tools-json", action="append", default=[], metavar="SERVER=FILE")
    ap.add_argument("--policy", default=POLICY)
    args = ap.parse_args()

    rules, always_deny = load_policy(args.policy)
    servers = cached_tools()
    for spec in args.tools_json:
        server, _, path = spec.partition("=")
        if not server or not path:
            die(f"--tools-json wants SERVER=FILE, got {spec!r}")
        servers[server] = json_tools(path)

    pairs, flags = [], []
    for server in sorted(servers):
        for t in servers[server]:
            pairs.append((server, t["name"]))
            flags.append(t["readOnly"])
    deny_pairs = [tuple(x.split(":", 1)) for x in always_deny]
    names = mint(pairs + deny_pairs)

    desired = {}
    for (server, tool), ro, name in zip(pairs, flags, names):
        desired[name] = decide(server, tool, ro, rules)
    for name in names[len(pairs):]:
        desired[name] = "deny"

    live = live_approval()
    seen_servers = {n.split("_", 3)[2] for n in desired}  # "mcp__<server>_<tool>" → server
    merged = {k: v for k, v in live.items()
              if not k.startswith("mcp__") or k.split("_", 3)[2] not in seen_servers}
    merged.update(desired)

    changes = sorted(set(merged) | set(live))
    diff = [(k, live.get(k), merged.get(k)) for k in changes if live.get(k) != merged.get(k)]
    counts = {a: sum(1 for v in desired.values() if v == a) for a in sorted(VALID)}
    print(f"servers: {', '.join(sorted(servers)) or '(none)'} · tools: {len(desired)} · {counts}")
    for k, old, new in diff:
        print(f"  {k}: {old} → {new}")

    if args.check:
        sys.exit(1 if diff else 0)
    if not args.apply:
        print("(dry run — pass --apply to write)" if diff else "(no changes)")
        return
    if diff:
        res = subprocess.run(["omp", "config", "set", "tools.approval", json.dumps(merged)],
                             capture_output=True, text=True, timeout=60)
        if res.returncode != 0:
            die(f"omp config set failed: {res.stderr.strip() or res.stdout.strip()}")
        if live_approval() != merged:
            die("write did not verify — live tools.approval differs from what was written")
        print(f"applied {len(diff)} change(s); verified.")


if __name__ == "__main__":
    main()
