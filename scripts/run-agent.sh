#!/usr/bin/env bash
# run-agent.sh — the ONE wrapper every headless agent run goes through.
# Usage: run-agent.sh <job-name> <prompt> [extra claude flags...]
#
# ══════════════════════════════════════════════════════════════════════════════
# THIS IS THE CHOKE POINT. Every guardrail lives here, so no job can forget one.
#
# Dan's warning — "put checks on persistent usage and infinite cycles with agent calls" —
# was correct, and until 2026-07-14 there were ZERO such guards. An agent that can call
# itself, on a timer, with a credit card attached, is a machine for burning money in your
# sleep. The five guards below are, in order of how badly you need them:
#
#   1. LOCK        (flock)     — one instance per job. If yesterday's run hung, today's
#                                does NOT stack on top of it. Without this, a single hang
#                                silently becomes N concurrent claude processes on an 8GB
#                                box, each holding tokens and RAM.
#   2. TIMEOUT     (timeout)   — a hard wall-clock kill. `claude -p` CAN hang (network,
#                                MCP stall). Cron will happily wait forever; this won't.
#   3. CIRCUIT BREAKER         — max runs per job per 24h. This is the one that catches a
#                                genuine runaway: a loop, a bad cron edit, a script calling
#                                itself. It trips, refuses to run, and PAGES YOU.
#   4. TURN CAP  (--max-turns) — bounds a single run's tool-call depth.
#   5. FAIL LOUD               — every failure pushes to the phone. A silent failure is
#                                worse than a crash, because you keep trusting the output.
#
# The rule this encodes: A SCHEDULED AGENT MUST BE BOUNDED IN TIME, IN CONCURRENCY,
# AND IN FREQUENCY. Any one of those left unbounded is an unbounded bill.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# The CALLER's job config must win over .env.
# (Bug fixed 2026-07-14: .env set AGENT_ALLOWED_TOOLS="Read,Glob,Grep" and silently
# clobbered what the calling script exported — so the morning brief asked for Gmail,
# .env took it away, every MCP call was denied, and the model reported "0 threads found".
# Each job knows its own least-privilege tool set. .env holds SECRETS, not POLICY.)
_CALLER_TOOLS="${AGENT_ALLOWED_TOOLS:-}"
_CALLER_TURNS="${AGENT_MAX_TURNS:-}"

if [[ -f "$REPO_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
else
  echo "ERROR: $REPO_DIR/.env not found. Copy example.env to .env and fill it in." >&2
  exit 1
fi

[[ -n "$_CALLER_TOOLS" ]] && AGENT_ALLOWED_TOOLS="$_CALLER_TOOLS"
[[ -n "$_CALLER_TURNS" ]] && AGENT_MAX_TURNS="$_CALLER_TURNS"

JOB_NAME="${1:?usage: run-agent.sh <job-name> <prompt> [flags...]}"
PROMPT="${2:?usage: run-agent.sh <job-name> <prompt> [flags...]}"
shift 2

LOG_DIR="${AGENT_LOG_DIR:-$HOME/.agent-logs}"
STATE_DIR="$LOG_DIR/state"
mkdir -p "$LOG_DIR" "$STATE_DIR"
LOG_FILE="$LOG_DIR/$(date +%F)-$JOB_NAME.log"

notify() { "$SCRIPT_DIR/notify.sh" "$1" "$2" >/dev/null 2>&1 || true; }

# ── GUARD 3: CIRCUIT BREAKER ──────────────────────────────────────────────────
# Runs per job per day. If a job fires far more often than its schedule allows,
# something is wrong — a loop, a duplicated cron entry, a script calling itself.
# Trip, refuse, and page. Better a missed brief than an unbounded bill.
MAX_RUNS_PER_DAY="${AGENT_MAX_RUNS_PER_DAY:-12}"
COUNT_FILE="$STATE_DIR/${JOB_NAME}.$(date +%F).count"
COUNT=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$COUNT" > "$COUNT_FILE"

if (( COUNT > MAX_RUNS_PER_DAY )); then
  echo "[$(date -Is)] job=$JOB_NAME CIRCUIT BREAKER TRIPPED ($COUNT > $MAX_RUNS_PER_DAY today)" >> "$LOG_FILE"
  notify "🔴 CIRCUIT BREAKER: $JOB_NAME" \
"'$JOB_NAME' has tried to run $COUNT times today (limit $MAX_RUNS_PER_DAY). That is far more
than its schedule allows, so it is being REFUSED — something is looping.

Check:  crontab -l    and    tail ~/.agent-logs/$(date +%F)-$JOB_NAME.log
Reset:  rm $COUNT_FILE"
  exit 9
fi

# Yesterday's counters are dead weight — prune anything older than 7 days.
find "$STATE_DIR" -name '*.count' -mtime +7 -delete 2>/dev/null || true

# ── GUARD 1: LOCK — one instance per job, ever ────────────────────────────────
LOCK="$STATE_DIR/${JOB_NAME}.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "[$(date -Is)] job=$JOB_NAME SKIPPED — a previous run is still going" >> "$LOG_FILE"
  notify "⚠️ $JOB_NAME skipped" \
    "A previous '$JOB_NAME' run is STILL RUNNING and blocked this one. If that keeps happening, a run is hung — check ~/.agent-logs/."
  exit 0   # not an error: skipping is the correct behaviour
fi

cd "$CONTEXT_DIR"   # run from the context repo so CLAUDE.md + relative paths resolve

# ── GUARD 2 + 4: TIMEOUT and TURN CAP ─────────────────────────────────────────
TIMEOUT_SEC="${AGENT_TIMEOUT_SEC:-600}"

echo "[$(date -Is)] job=$JOB_NAME starting (run $COUNT/$MAX_RUNS_PER_DAY today, timeout ${TIMEOUT_SEC}s)" >> "$LOG_FILE"
START=$(date +%s)

OUTPUT=$(timeout --kill-after=30s "$TIMEOUT_SEC" \
  claude -p "$PROMPT" \
    --allowedTools "${AGENT_ALLOWED_TOOLS:-Read,Glob,Grep}" \
    --max-turns "${AGENT_MAX_TURNS:-25}" \
    "$@" 2>>"$LOG_FILE")
RC=$?
ELAPSED=$(( $(date +%s) - START ))

# ── GUARD 5: FAIL LOUD ────────────────────────────────────────────────────────
if [[ $RC -eq 124 || $RC -eq 137 ]]; then
  echo "[$(date -Is)] job=$JOB_NAME TIMED OUT after ${TIMEOUT_SEC}s" >> "$LOG_FILE"
  notify "⏱️ $JOB_NAME TIMED OUT" \
    "'$JOB_NAME' was killed after ${TIMEOUT_SEC}s. It hung — do NOT assume its output is complete. Check ~/.agent-logs/."
  exit 124
elif [[ $RC -ne 0 ]]; then
  echo "[$(date -Is)] job=$JOB_NAME FAILED (rc=$RC, ${ELAPSED}s)" >> "$LOG_FILE"
  notify "⚠️ $JOB_NAME failed" "Exit $RC after ${ELAPSED}s. Check ~/.agent-logs/$(date +%F)-$JOB_NAME.log on the server."
  exit "$RC"
fi

echo "$OUTPUT" >> "$LOG_FILE"
echo "[$(date -Is)] job=$JOB_NAME ok (${ELAPSED}s)" >> "$LOG_FILE"

# Emit on stdout so callers can INSPECT the output before deciding to push it.
# (Bug fixed 2026-07-14: this used to go only to the log file, so OUT=$(run-agent.sh ...)
# captured an empty string, and the brief's coverage check cried DEGRADED on a good brief.)
echo "$OUTPUT"

# Jobs that want their output pushed verbatim, without inspection:
if [[ "${PUSH_OUTPUT:-0}" == "1" ]]; then
  notify "$JOB_NAME" "$OUTPUT"
fi
