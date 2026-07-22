#!/usr/bin/env bash
# spawn-agent.sh — run ONE milestone of a deep-work agent for a bus thread, then STOP.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHY THIS SHAPE (Phase 2, 2026-07-20)
#
# The message bus (bus.py) is the board; this is how the orchestrator staffs it. The
# design is deliberately the safest version of Dan's vision, per Roman's two calls:
#
#   * MANUAL CONTINUATION. One run does ONE milestone: the agent works a single coherent
#     chunk, reports to the bus, and the process EXITS. Nothing continues on its own —
#     the next milestone only runs when Roman approves and the orchestrator re-fires this
#     script. There is no timer, no self-continuation. "Propose and wait", enforced by
#     the process model, not by a prompt we hope the model obeys.
#   * ORCHESTRATOR-ONLY. Only Kairo runs this. A worker cannot spawn its own workers.
#
# It is bounded by construction, three ways:
#   1. Every milestone is a fresh run through run-agent.sh — so it inherits ALL of that
#      choke point's guards (flock per-thread, timeout, circuit breaker, --max-turns,
#      fail-loud). This script adds nothing that can bypass them.
#   2. A GLOBAL concurrency semaphore (flock slots) caps how many deep-work agents run at
#      once — the existing flock is per-job-NAME only; an 8GB box needs a hard total cap.
#   3. State lives in the BUS, not in a long-running process. The agent is stateless per
#      run and reconstructs context by reading the thread. Nothing sits blocked holding
#      RAM waiting for a human.
#
# TRUST BOUNDARY. Workers get NO Bash and cannot push/commit/send (those are ask->denied
# headless anyway). They Read/Edit/Write (code) or use read-only connectors (research),
# and end their output with a status line. THIS WRAPPER — trusted — is the only thing that
# writes to the bus. So even an agent that ingested untrusted content never has a shell,
# and untrusted text never becomes a bus write except through us. (docs/permissions.md:
# never give Bash to a job that reads untrusted input.)
#
# USAGE:  spawn-agent.sh <thread-id> [--tools "Read,Edit,Write"] [--label worker-1] [--dir /abs/project]
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
[[ -f "$REPO_DIR/.env" ]] && { set +u; source "$REPO_DIR/.env"; set -u; }

STATE="${AGENT_LOG_DIR:-$HOME/.agent-logs}/state"; mkdir -p "$STATE"
MAXC="${AGENT_MAX_CONCURRENT:-2}"
BUS=("python3" "$SCRIPT_DIR/bus.py")
notify_fyi() { "$SCRIPT_DIR/notify.sh" fyi "🤖 bus: $1" "$2" >/dev/null 2>&1 || true; }
notify_alert() { "$SCRIPT_DIR/notify.sh" alert "🤖 bus: $1" "$2" >/dev/null 2>&1 || true; }

# ── args ──────────────────────────────────────────────────────────────────────
THREAD="${1:?usage: spawn-agent.sh <thread-id> [--tools ...] [--label ...] [--dir ...]}"; shift
TOOLS="Read,Glob,Grep"          # safe default; NO Bash, NO Edit/Write, NO send
LABEL="worker"
WORKDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tools) TOOLS="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --dir)   WORKDIR="$2"; shift 2;;
    *) echo "spawn-agent: unknown arg '$1'"; exit 2;;
  esac
done
# Refuse Bash/push/send in a spawned worker — the trust boundary is not optional.
if echo "$TOOLS" | grep -qiE 'bash|create_draft|send'; then
  echo "🔴 spawn-agent: refusing — a worker must not have Bash or a send/draft tool."; exit 2
fi

# ── thread must exist and be continuable ──────────────────────────────────────
STATUS="$("${BUS[@]}" get "$THREAD" status 2>/dev/null)" || { echo "🔴 no such thread: $THREAD"; exit 2; }
case "$STATUS" in
  done|killed) echo "🔴 thread $THREAD is '$STATUS' — nothing to continue."; exit 2;;
esac
TITLE="$("${BUS[@]}" get "$THREAD" title)"

# ── GLOBAL concurrency semaphore (flock slots) ────────────────────────────────
SLOT_FD=""
for i in $(seq 1 "$MAXC"); do
  exec {fd}>"$STATE/deepwork.slot.$i" || continue
  if flock -n "$fd"; then SLOT_FD="$fd"; break; fi
  exec {fd}>&-
done
if [[ -z "$SLOT_FD" ]]; then
  echo "⏳ at capacity: $MAXC deep-work agents already running. $THREAD not started."
  notify_alert "$THREAD" "At capacity ($MAXC agents). '$TITLE' was NOT started — approve or finish a running one first."
  exit 9
fi
"${BUS[@]}" status "$THREAD" --set working >/dev/null

# ── build the milestone prompt from the thread's history on the bus ───────────
HISTORY="$("${BUS[@]}" read "$THREAD")"
DIRLINE=""; [[ -n "$WORKDIR" ]] && DIRLINE="The project lives at: $WORKDIR  (use ABSOLUTE paths for all file work — your working directory is elsewhere)."
PROMPT="You are a focused deep-work agent in Roman's system, assigned to ONE thread: \"$TITLE\".
Do NOT run any session-start routine and do NOT read the personal context files — you are a worker, not the orchestrator. Just do the work below.

$DIRLINE

Here is the thread so far (your brief, prior milestones, and any steering from Roman) — read it, then continue from where it left off:
-------------------- THREAD $THREAD --------------------
$HISTORY
-------------------------------------------------------

RULES:
- Do the NEXT SINGLE MILESTONE — one coherent, reviewable chunk of progress — then STOP. Do not try to finish the whole job in one run.
- You may Read/Edit/Write files. You may NOT push, commit, or send anything, and you have no shell. Leave irreversible/outward actions to Roman.
- If you need a decision from Roman, or you are blocked or unsure, STOP and ask instead of guessing.

END your final message with EXACTLY ONE status line, on its own line, one of:
  <<BUS milestone>> one-sentence summary of what you did this run
  <<BUS needs_input>> the specific question or decision you need from Roman
  <<BUS blocked>> what is blocking you
  <<BUS done>> one-sentence summary (ONLY if the entire job is now complete)"

# ── run ONE milestone through the choke point (inherits all guards) ───────────
echo "▶ spawning worker '$LABEL' on $THREAD (slot held; tools: $TOOLS)"
export AGENT_ALLOWED_TOOLS="$TOOLS"
export AGENT_MAX_TURNS="${AGENT_MAX_TURNS_DW:-40}"
OUT="$("$SCRIPT_DIR/run-agent.sh" "$THREAD" "$PROMPT" 2>>"${AGENT_LOG_DIR:-$HOME/.agent-logs}/spawn-agent.log")"

# ── relay the result to the bus (assert the status line; never infer) ─────────
LINE="$(printf '%s\n' "$OUT" | grep -oE '<<BUS (milestone|needs_input|blocked|done)>>.*' | tail -1)"
KIND="$(printf '%s' "$LINE" | sed -E 's/^<<BUS ([a-z_]+)>>.*/\1/')"
BODY="$(printf '%s' "$LINE" | sed -E 's/^<<BUS [a-z_]+>> ?//')"

case "$KIND" in
  milestone)
    "${BUS[@]}" write "$THREAD" --kind milestone --by "$LABEL" "${BODY:-(no summary)}" >/dev/null
    "${BUS[@]}" status "$THREAD" --set needs_input >/dev/null
    notify_fyi "$THREAD" "Milestone ready — approve to continue: ${BODY:-$TITLE}"
    echo "✅ milestone written; thread PAUSED awaiting your approval."
    ;;
  needs_input)
    "${BUS[@]}" write "$THREAD" --kind question --by "$LABEL" --needs-input "${BODY:-needs a decision}" >/dev/null
    echo "🔔 needs_input written (phone alerted); thread paused."
    ;;
  blocked)
    "${BUS[@]}" write "$THREAD" --kind uncertainty --by "$LABEL" --needs-input "BLOCKED: ${BODY:-unspecified}" >/dev/null
    "${BUS[@]}" status "$THREAD" --set blocked >/dev/null
    echo "🔔 blocked written (phone alerted)."
    ;;
  done)
    "${BUS[@]}" write "$THREAD" --kind completion --by "$LABEL" "${BODY:-complete}" >/dev/null
    notify_fyi "$THREAD" "Thread complete: ${BODY:-$TITLE}"
    echo "🏁 thread marked done."
    ;;
  *)
    # No clean status line — do NOT guess what happened. Record the tail and flag for review.
    TAIL="$(printf '%s\n' "$OUT" | tail -8)"
    "${BUS[@]}" write "$THREAD" --kind note --by "$LABEL" "raw output tail: $TAIL" >/dev/null
    "${BUS[@]}" write "$THREAD" --kind question --by "$LABEL" --needs-input \
      "The worker did not report a clean status line — review its output on this thread." >/dev/null
    echo "⚠️  worker gave no <<BUS …>> status — flagged for your review."
    ;;
esac
# slot releases when this process exits (SLOT_FD closes)
