#!/usr/bin/env python3
"""taskctl.py — deterministic, LLM-free mutations of tasks.yaml.

WHY THIS EXISTS (2026-08-25): adding/completing/rescheduling a task is a MECHANICAL
transform of structured data — it never needed an LLM. Routing those edits through a
reasoning agent (a delegated `claude -p` that first loads Kairo's whole context) made
them slow (~190s) and flaky (~40% fail on --max-turns) — see the OMP-seat healthcheck
findings. This script does the same edits in <1s, 100% reliably, and — crucially —
encodes the task-system's own rules IN CODE instead of trusting a model to follow them:
  * IDs are never reused          (id = meta.next_id, then next_id++)
  * nothing is ever deleted       ("done" MOVES an entry to done:, never removes it)
  * tasks.md is regenerated       (runs render-tasks.py after every successful write)

DESIGN — why text-splicing, not yaml.safe_dump(load(f)):
tasks.yaml is hand-maintained and carries a header block PLUS ~24 in-list section
dividers (`# ─── SCHOOL ───` …) that are Roman's organization. A full load/dump rewrite
would erase every one of them. So we edit the file as TEXT (preserving everything
except the targeted change), then re-parse the candidate with the SAME yaml.safe_load
the renderer uses and assert the change is exactly right before atomically swapping it
in. A malformed edit can never reach disk: the original is only replaced on success.

Usage:
    taskctl.py add   --title "…" --domain work --urgency yellow [--due 2026-09-01]
                     [--project PEPMatch] [--notes "…"] [--file PATH]
    taskctl.py done  T146 [--notes "short summary"] [--file PATH]
    taskctl.py set   T146 due 2026-09-15        # reschedule / re-prioritize / re-domain
    taskctl.py set   T146 urgency red
Exit 0 on success (prints the assigned/changed id); non-zero + original untouched on any error.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

import yaml

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VALID_DOMAINS = {"work", "school", "personal", "other"}
VALID_URGENCY = {"red", "yellow", "green"}
# Fields a `set` may touch. Deliberately excludes id (never mutable) and status/done_date
# (owned by the add/done lifecycle, not a free edit).
SETTABLE = {"title", "domain", "project", "urgency", "due", "notes", "blocked_on", "status"}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def die(msg):
    print(f"taskctl: ERROR — {msg}", file=sys.stderr)
    sys.exit(1)


def default_path():
    return os.path.join(os.environ.get("CONTEXT_DIR", "."), "tasks.yaml")


def read_text(path):
    with open(path) as f:
        return f.read()


def parse(text):
    """Parse with the SAME loader the renderer uses. Returns the data dict."""
    return yaml.safe_load(text)


def block_bounds(lines, start_idx):
    """Given the index of a `  - id:` line, return the exclusive end index of that task's
    block. A block runs until the next line at list/comment/top level — i.e. the next
    `  - ` item, `  #` divider, or a column-0 key (done:). Field lines (4-space) and
    block-scalar note bodies (6-space) are deeper, so they stay inside the block."""
    i = start_idx + 1
    while i < len(lines):
        ln = lines[i]
        if re.match(r"  (- |#)", ln) or re.match(r"^\S", ln):
            break
        i += 1
    return i


def find_task(lines, tid):
    """Return (start, end) line indices of task `tid` in the tasks: section, or None."""
    in_tasks = False
    for idx, ln in enumerate(lines):
        if re.match(r"^tasks:", ln):
            in_tasks = True
            continue
        if re.match(r"^done:", ln):
            break
        if in_tasks and re.match(rf"  - id:\s*{re.escape(tid)}\b", ln):
            return idx, block_bounds(lines, idx)
    return None


def emit_entry(d, indent="  "):
    """Render one task dict to YAML text via safe_dump (correct escaping, no manual
    quoting bugs), field order preserved, then indent to match the file's list style."""
    dumped = yaml.safe_dump([d], sort_keys=False, allow_unicode=True, width=100000)
    return "".join(indent + ln if ln.strip() else ln for ln in dumped.splitlines(keepends=True))


def write_verified(path, new_text, assert_fn):
    """Atomically install new_text ONLY if it parses and passes assert_fn. Original file
    is never touched on failure."""
    try:
        data = parse(new_text)
    except yaml.YAMLError as e:
        die(f"candidate is not valid YAML ({e}) — original left untouched")
    try:
        assert_fn(data)
    except AssertionError as e:
        die(f"post-edit invariant failed ({e}) — original left untouched")
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".taskctl.", suffix=".yaml")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(new_text)
        os.replace(tmp, path)  # atomic on POSIX
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def render(path):
    """Regenerate tasks.md. A write that didn't re-render leaves the view stale."""
    r = subprocess.run(
        [sys.executable, os.path.join(SCRIPT_DIR, "render-tasks.py"), path],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        die(f"write succeeded but render-tasks.py failed: {r.stderr.strip()}")
    return r.stdout.strip()


def cmd_add(args):
    path = args.file or default_path()
    text = read_text(path)
    data = parse(text)
    meta = data.get("meta", {}) or {}
    nid = meta.get("next_id")
    if not isinstance(nid, int):
        die("meta.next_id is missing or not an integer")
    if args.domain not in VALID_DOMAINS:
        die(f"domain must be one of {sorted(VALID_DOMAINS)}")
    if args.urgency not in VALID_URGENCY:
        die(f"urgency must be one of {sorted(VALID_URGENCY)}")
    if args.due and not DATE_RE.match(args.due):
        die("--due must be YYYY-MM-DD")
    new_id = f"T{nid}"
    entry = {
        "id": new_id,
        "title": args.title,
        "domain": args.domain,
        "project": args.project,       # None -> null
        "urgency": args.urgency,
        "due": args.due,               # None -> null
        "status": "open",
        "notes": args.notes,           # None -> null
    }
    lines = text.splitlines(keepends=True)
    # Insert immediately after the `tasks:` line (top of the list) — never disturbs a
    # section divider; the renderer re-sorts for display anyway, so source order is
    # cosmetic. Bump next_id in meta.
    out = []
    inserted = False
    for ln in lines:
        out.append(ln)
        if not inserted and re.match(r"^tasks:", ln):
            out.append(emit_entry(entry))
            inserted = True
    if not inserted:
        die("could not find a `tasks:` line to insert under")
    new_text = re.sub(r"(?m)^(\s*next_id:\s*)\d+", rf"\g<1>{nid + 1}", "".join(out), count=1)

    def check(d):
        ids = [t.get("id") for t in d.get("tasks", [])]
        assert new_id in ids, f"{new_id} not present after add"
        assert ids.count(new_id) == 1, f"{new_id} duplicated"
        assert d.get("meta", {}).get("next_id") == nid + 1, "next_id not incremented"
        assert new_id not in {t.get("id") for t in d.get("done", [])}, "new id leaked into done:"

    write_verified(path, new_text, check)
    print(new_id)
    print(render(path), file=sys.stderr)


def cmd_done(args):
    path = args.file or default_path()
    text = read_text(path)
    lines = text.splitlines(keepends=True)
    data = parse(text)
    found = find_task(lines, args.id)
    if not found:
        die(f"{args.id} not found in the open tasks: section (already done? never existed?)")
    start, end = found
    # Pull the entry DICT from the full-file parse (keyed by id) rather than re-parsing an
    # extracted text block — dedenting a slice by hand is where a subtle YAML bug hides.
    entry = next((t for t in data.get("tasks", []) if t.get("id") == args.id), None)
    if entry is None:
        die(f"{args.id} found in text but not in parsed tasks: — file may be malformed")
    # Done entries are intentionally trimmed: drop live-only fields (status/urgency/due/
    # blocked_on), keep the record fields, stamp the date, allow a short note override.
    done_entry = {
        "id": entry.get("id"),
        "done_date": args.date,
        "title": entry.get("title"),
        "domain": entry.get("domain"),
        "project": entry.get("project"),
        "notes": args.notes if args.notes is not None else entry.get("notes"),
    }
    # Remove the block from tasks:, then insert the done entry right after the `done:` line.
    remaining = lines[:start] + lines[end:]
    out, inserted = [], False
    for ln in remaining:
        out.append(ln)
        if not inserted and re.match(r"^done:", ln):
            out.append(emit_entry(done_entry))
            inserted = True
    if not inserted:
        die("could not find a `done:` line to move the task under")
    new_text = "".join(out)

    def check(d):
        openids = {t.get("id") for t in d.get("tasks", [])}
        doneids = [t.get("id") for t in d.get("done", [])]
        assert args.id not in openids, f"{args.id} still in open tasks:"
        assert args.id in doneids, f"{args.id} not in done:"
        assert doneids.count(args.id) == 1, f"{args.id} duplicated in done:"

    write_verified(path, new_text, check)
    print(args.id)
    print(render(path), file=sys.stderr)


def cmd_set(args):
    path = args.file or default_path()
    if args.field not in SETTABLE:
        die(f"field must be one of {sorted(SETTABLE)} (id/done_date are not free-settable)")
    if args.field == "domain" and args.value not in VALID_DOMAINS:
        die(f"domain must be one of {sorted(VALID_DOMAINS)}")
    if args.field == "urgency" and args.value not in VALID_URGENCY:
        die(f"urgency must be one of {sorted(VALID_URGENCY)}")
    if args.field == "due" and args.value not in ("null", "none") and not DATE_RE.match(args.value):
        die("due must be YYYY-MM-DD (or 'null' to clear)")
    text = read_text(path)
    lines = text.splitlines(keepends=True)
    data = parse(text)
    found = find_task(lines, args.id)
    if not found:
        die(f"{args.id} not found in the open tasks: section")
    start, end = found
    # Rebuild just this entry via safe_dump so escaping/quoting is always correct and a
    # multi-line note collapses cleanly to the new scalar. Entry dict comes from the
    # full-file parse (not a hand-dedented slice).
    entry = next((t for t in data.get("tasks", []) if t.get("id") == args.id), None)
    if entry is None:
        die(f"{args.id} found in text but not in parsed tasks: — file may be malformed")
    val = None if args.value in ("null", "none") else args.value
    entry[args.field] = val
    new_block = emit_entry(entry)
    new_text = "".join(lines[:start] + [new_block] + lines[end:])

    def check(d):
        match = [t for t in d.get("tasks", []) if t.get("id") == args.id]
        assert match, f"{args.id} vanished after set"
        got = match[0].get(args.field)
        assert got == val, f"{args.field} is {got!r}, expected {val!r}"

    write_verified(path, new_text, check)
    print(f"{args.id} {args.field}={val}")
    print(render(path), file=sys.stderr)


def main():
    p = argparse.ArgumentParser(prog="taskctl", description="Deterministic tasks.yaml edits")
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("add", help="add a new open task")
    a.add_argument("--title", required=True)
    a.add_argument("--domain", required=True)
    a.add_argument("--urgency", required=True)
    a.add_argument("--due")
    a.add_argument("--project")
    a.add_argument("--notes")
    a.add_argument("--file")
    a.set_defaults(fn=cmd_add)

    d = sub.add_parser("done", help="move an open task to done:")
    d.add_argument("id")
    d.add_argument("--notes", help="trimmed summary; defaults to the task's existing notes")
    d.add_argument("--date", help="done_date (YYYY-MM-DD); defaults to today (owner tz)")
    d.add_argument("--file")
    d.set_defaults(fn=cmd_done)

    s = sub.add_parser("set", help="change one field of an open task")
    s.add_argument("id")
    s.add_argument("field")
    s.add_argument("value")
    s.add_argument("--file")
    s.set_defaults(fn=cmd_set)

    args = p.parse_args()
    # today() in the owner's timezone — same source-of-truth rule as render-tasks.py.
    if getattr(args, "cmd", None) == "done" and not args.date:
        from datetime import datetime
        from zoneinfo import ZoneInfo
        tz = ZoneInfo(os.environ.get("OWNER_TZ", "America/Los_Angeles"))
        args.date = datetime.now(tz).date().isoformat()
    args.fn(args)


if __name__ == "__main__":
    main()
