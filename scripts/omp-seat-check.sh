#!/usr/bin/env bash
# omp-seat-check.sh — acceptance test for the omp terminal seat. Run it after installing
# the seat, after EVERY omp upgrade, and whenever something feels off.
#
# omp ships ~1.5 releases/day and a quarter of recent ones carried breaking changes
# (renamed settings, changed context-file loading, changed defaults). A setting that
# silently stops applying is exactly the failure this system has been bitten by before —
# so this script checks what omp ACTUALLY resolved, not what the file says.
#
# USAGE
#   omp-seat-check.sh          static checks (no model call, no credential needed)
#   omp-seat-check.sh --live   + one real `omp -p` identity probe (needs the profile's
#                              API-key credential; costs one small API call)
# ENV: KAIRO_OMP_PROFILE (default kairo), KAIRO_HOME (default: parent of this repo),
#      KAIRO_OMP_PIN (optional: the omp version this seat was last validated on)
# Exit: 0 = no FAIL (WARNs allowed), 1 = at least one FAIL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
KAIRO_HOME="${KAIRO_HOME:-$(dirname "$REPO_DIR")}"
# Same owner-choices file the seat launcher reads (KAIRO_* keys only; explicit env wins).
SEAT_ENV="${KAIRO_SEAT_ENV:-$HOME/.config/kairo/seat.env}"
if [[ -f "$SEAT_ENV" ]]; then
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^KAIRO_[A-Z_]+$ ]] || continue
    if [[ -z "${!k:-}" ]]; then export "$k=$v"; fi
  done < <(grep -E '^[[:space:]]*KAIRO_[A-Z_]+=' "$SEAT_ENV" | sed 's/^[[:space:]]*//')
fi
P="${KAIRO_OMP_PROFILE:-kairo}"
# omp's default profile lives at ~/.omp/agent; named profiles at ~/.omp/profiles/<name>/agent.
if [[ -z "$P" || "$P" == "default" ]]; then PROFILE_DIR="$HOME/.omp/agent"; else PROFILE_DIR="$HOME/.omp/profiles/$P/agent"; fi
OAUTH_OK="${KAIRO_ALLOW_SUBSCRIPTION_OAUTH:-}"
TEMPLATE="$REPO_DIR/config/omp-kairo-profile.yml"
LIVE=0; [[ "${1:-}" == "--live" ]] && LIVE=1

npass=0; nwarn=0; nfail=0
pass() { echo "  PASS  $*"; npass=$((npass+1)); }
warn() { echo "  WARN  $*"; nwarn=$((nwarn+1)); }
fail() { echo "  FAIL  $*"; nfail=$((nfail+1)); }
o()    { OMP_PROFILE="$P" omp "$@" </dev/null; }   # </dev/null: omp reads a non-TTY stdin to EOF

echo "omp terminal seat check — profile '$P', workspace $KAIRO_HOME"

# ── 1. Binary + version ──────────────────────────────────────────────────────────
echo "[binary]"
if ! command -v omp >/dev/null; then fail "omp not on PATH"; echo "FAIL=1"; exit 1; fi
ver="$(omp --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [[ -n "${KAIRO_OMP_PIN:-}" && "$ver" != "$KAIRO_OMP_PIN" ]]; then
  warn "omp $ver differs from the validated pin $KAIRO_OMP_PIN — read the CHANGELOG's Breaking sections, then re-run this check before trusting the seat"
else
  pass "omp $ver"
fi

# ── 2. Effective profile config == the repo template ─────────────────────────────
echo "[profile config]"
if [[ ! -f "$PROFILE_DIR/config.yml" ]]; then
  fail "no config for profile '$P' at $PROFILE_DIR/config.yml — start from: $TEMPLATE"
else
  if o config list --json >"/tmp/omp-seat-check.$$.json" 2>/dev/null; then
    pyout="$(python3 - "$TEMPLATE" "/tmp/omp-seat-check.$$.json" <<'EOF'
import json, sys, yaml
want = yaml.safe_load(open(sys.argv[1]))
got  = json.load(open(sys.argv[2]))
RECORDS = {"tools.approval", "modelRoles"}          # record-typed: compare whole value
PREFERENCES = {"modelRoles", "symbolPreset"}         # owner's taste, not safety: report, never fail
def resolved(path):
    # `omp config list --json` is FLAT, keyed by the full dotted name ("tools.approvalMode"),
    # each entry {"value", "type", "description"}. Fall back to a nested walk in case a
    # future version changes shape — a shape change must surface as FAIL, never a false PASS.
    x = got.get(path)
    if x is None:
        x = got
        for part in path.split("."):
            if not isinstance(x, dict) or part not in x: return None
            x = x[part]
    return x.get("value") if isinstance(x, dict) and "type" in x else x
def leaves(x, p=""):
    if isinstance(x, dict) and p not in RECORDS:
        for k, v in x.items(): yield from leaves(v, f"{p}.{k}" if p else k)
    else: yield p, x
for key, v in leaves(want):
    g = resolved(key)
    if key in PREFERENCES:
        print(f"  INFO  {key} = {g!r} (owner preference; template suggests {v!r})"[:150])
        continue
    if g is None:
        print(f"  FAIL  {key}: not a setting in this omp version (renamed/removed?) — template wants {v!r}")
    elif g == v or str(g).lower() == str(v).lower():
        print(f"  PASS  {key} = {g!r}"[:110])
    elif isinstance(v, dict) and isinstance(g, dict) and all(g.get(k) == vv for k, vv in v.items()):
        print(f"  PASS  {key} ⊇ {v!r}"[:110])
    else:
        print(f"  FAIL  {key}: effective {g!r} ≠ template {v!r}"[:160])
EOF
)" || pyout="  FAIL  config validator crashed"
    echo "$pyout"
    npass=$((npass + $(grep -c '^  PASS' <<<"$pyout")))
    nfail=$((nfail + $(grep -c '^  FAIL' <<<"$pyout")))
  else
    fail "omp config list failed for profile '$P'"
  fi
  rm -f "/tmp/omp-seat-check.$$.json"
fi

# ── 3. Model credential: API key yes, subscription OAuth never ───────────────────
echo "[credentials]"
if [[ -n "${ANTHROPIC_OAUTH_TOKEN:-}" ]]; then
  fail "ANTHROPIC_OAUTH_TOKEN is set — a subscription token in the environment"
else
  pass "no ANTHROPIC_OAUTH_TOKEN in env"
fi
if o token anthropic --list >/dev/null 2>&1; then
  if [[ "$OAUTH_OK" == 1 ]]; then
    # Owner's recorded choice (seat.env). Still surface the two standing consequences.
    warn "profile '$P' uses an Anthropic SUBSCRIPTION login — owner's choice (seat.env). Grant expires ~30 days after login: re-login before then. Consumer-Terms/account risk accepted."
  else
    fail "profile '$P' stores an Anthropic SUBSCRIPTION login (OAuth) — against Anthropic's Consumer Terms outside Claude Code; /logout it and use an API key"
  fi
else
  pass "no Anthropic subscription login stored in profile '$P'"
  if tok="$(o token anthropic 2>/dev/null)" && [[ "$tok" == sk-ant-api* ]]; then
    pass "an Anthropic API key is available to the profile"
  else
    warn "no Anthropic credential available to profile '$P' — the seat can't call Claude yet"
  fi
  unset tok
fi

# ── 4. Identity files the seat will load ─────────────────────────────────────────
echo "[identity]"
if [[ -f "$KAIRO_HOME/AGENTS.md" ]]; then
  pass "AGENTS.md present (under omp it is the seat's identity; it shadows CLAUDE.md at the same depth)"
else
  fail "no $KAIRO_HOME/AGENTS.md — omp would fall back to CLAUDE.md, whose Claude-Code-only instructions don't fit this seat"
fi
if [[ -f "$KAIRO_HOME/AGENTS.md" ]] && grep -qE '^\s*@' "$KAIRO_HOME/AGENTS.md"; then
  # omp leaves a missing @-import as literal text with only a debug log — check targets exist.
  while read -r imp; do
    t="${imp#@}"; [[ "$t" == ~/* ]] && t="$HOME/${t#~/}"; [[ "$t" != /* ]] && t="$KAIRO_HOME/$t"
    [[ -f "$t" ]] && pass "@-import resolves: $imp" || fail "@-import target missing (omp fails SILENTLY on this): $imp"
  done < <(grep -oE '^\s*@[^[:space:]]+' "$KAIRO_HOME/AGENTS.md" | tr -d ' ')
fi

# ── 5. The read-only worker (trust boundary) ─────────────────────────────────────
echo "[fleet-researcher]"
agent="$KAIRO_HOME/.omp/agents/fleet-researcher.md"
if [[ ! -e "$agent" ]]; then
  warn "not activated: $agent missing — omp ignores .claude/agents, so the no-shell worker doesn't exist in this seat (phase B: link agent-machinery/.omp/agents)"
else
  tools_line="$(grep -m1 -E '^tools:' "$agent" || true)"
  if grep -qiE '\b(bash|eval|task|write|edit|browser|computer)\b' <<<"$tools_line"; then
    fail "fleet-researcher grants a shell/act tool: $tools_line"
  else
    pass "fleet-researcher tools = ${tools_line#tools: }"
  fi
fi
mcp_found=""
for f in "$KAIRO_HOME/.mcp.json" "$KAIRO_HOME/.claude/.mcp.json" "$KAIRO_HOME/.claude/mcp.json" \
         "$HOME/.omp/profiles/$P/agent/mcp.json" "$KAIRO_HOME/.omp/mcp.json"; do
  [[ -f "$f" ]] && mcp_found+=" $f"
done
if [[ -n "$mcp_found" ]]; then
  warn "MCP config present:$mcp_found — omp attaches MCP tools to EVERY subagent regardless of its tools: list; audit each server's tools and add tools.approval prompts for anything that can send/act"
else
  pass "no MCP servers configured (subagent tool boundary holds)"
fi

# ── 6. Seat plumbing ─────────────────────────────────────────────────────────────
echo "[seat]"
sock="kairo-check-$$"
if tmux -L "$sock" -f "$REPO_DIR/config/tmux-kairo.conf" new-session -d -s probe 'sleep 5' 2>/tmp/omp-seat-tmux.$$ \
   && tmux -L "$sock" kill-server 2>/dev/null; then
  pass "tmux-kairo.conf loads cleanly"
else
  fail "tmux-kairo.conf errors: $(head -c 200 /tmp/omp-seat-tmux.$$)"
fi
rm -f /tmp/omp-seat-tmux.$$
[[ -x "$SCRIPT_DIR/kairo-term.sh" ]] && pass "kairo-term.sh executable" || fail "kairo-term.sh not executable"
[[ -x "$SCRIPT_DIR/hooks/seat-notify.sh" && -x "$SCRIPT_DIR/notify.sh" ]] \
  && pass "notification path executable (seat-notify.sh → notify.sh)" \
  || warn "notification scripts not executable"

# ── 7. Live identity probe (optional) ────────────────────────────────────────────
if (( LIVE )); then
  echo "[live probe]"
  out="$(cd "$KAIRO_HOME" && timeout 180 env OMP_PROFILE="$P" omp -p --no-session --no-title \
          --tools read --approval-mode write --max-time 150 \
          "Answer in exactly 3 short lines, no preamble. 1) Your name. 2) Which instruction file defines you (filename only). 3) The FIRST file your session-start procedure tells you to read (filename only). Do not read any files to answer." \
          </dev/null 2>/tmp/omp-seat-live.$$)"; rc=$?
  if (( rc != 0 )); then
    fail "omp -p exited $rc: $(tail -c 300 /tmp/omp-seat-live.$$)"
  else
    grep -qi 'kairo' <<<"$out" && pass "identity: answers as Kairo" || fail "identity NOT loaded — answer: $(head -c 200 <<<"$out")"
    grep -qi 'soul' <<<"$out" && pass "session-start procedure visible (first read = soul.md)" \
                             || warn "session-start procedure not recognised — answer: $(head -c 200 <<<"$out")"
  fi
  rm -f /tmp/omp-seat-live.$$
fi

echo "summary: $npass pass, $nwarn warn, $nfail fail"
(( nfail == 0 ))
