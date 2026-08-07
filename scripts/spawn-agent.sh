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
#     (If that 4th level is EVER opened, it opens bounded: spawn-depth <= 2, children <= 3 per
#      parent, within AGENT_MAX_CONCURRENT. Pre-decided — see docs/message-bus.md "gated 4th level".)
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
THREAD="${1:?usage: spawn-agent.sh <thread-id> [--tools ...] [--label ...] [--dir ...] [--tier cheap|deep]}"; shift
TOOLS="Read,Glob,Grep"          # safe default; NO Bash, NO Edit/Write, NO send
LABEL="worker"
WORKDIR=""
TIER="cheap"                    # P6: default cheap; orchestrator sets 'deep' for hard milestones
MODEL=""                        # an explicit --model wins over --tier
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tools) TOOLS="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --dir)   WORKDIR="$2"; shift 2;;
    --tier)  TIER="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    *) echo "spawn-agent: unknown arg '$1'"; exit 2;;
  esac
done
# P6 — model tiering: resolve the tier to a model (explicit --model overrides). Cheap by default;
# escalate to deep only for hard milestones per the rubric in docs/message-bus.md. Models are
# env-overridable so the mapping isn't hardcoded to today's model names.
# Validate the tier unconditionally (even when --model overrides it) so a typo is never silent.
case "$TIER" in cheap|deep) ;; *) echo "🔴 spawn-agent: --tier must be 'cheap' or 'deep' (got '$TIER')"; exit 2;; esac
if [[ -z "$MODEL" ]]; then
  case "$TIER" in
    cheap) MODEL="${AGENT_MODEL_CHEAP:-sonnet}";;
    deep)  MODEL="${AGENT_MODEL_DEEP:-opus}";;
  esac
fi
# Refuse Bash/push/send in a spawned worker — the trust boundary is not optional.
if echo "$TOOLS" | grep -qiE 'bash|create_draft|send'; then
  echo "🔴 spawn-agent: refusing — a worker must not have Bash or a send/draft tool."; exit 2
fi

# P-trust (2026-08-07): classify this worker's OUTPUT provenance from the tools it was granted.
# A worker with any content-ingesting tool (web fetch/search, a browser, or a read connector like
# Gmail/Drive/Calendar/Notion/Granola/PubMed) can pull UNTRUSTED text off the internet or an inbox
# and relay it onto the bus. We tag every such worker's writes 'untrusted' so a shell-capable
# reader (the orchestrator, and spawn-agent.sh itself when it builds the NEXT worker's prompt from
# `bus.py read`) treats that content as DATA, never instructions. Mirrors the Bash/send refusal
# above: the wrapper knows the granted tools, so it — not the (possibly-injected) worker — sets trust.
TRUST="trusted"
if echo "$TOOLS" | grep -qiE 'webfetch|websearch|fetch|browser|gmail|drive|calendar|notion|granola|pubmed|zoom|mcp__'; then
  TRUST="untrusted"
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
# P6 cache-stable prefix: the invariant instruction block is IDENTICAL for every worker and comes
# FIRST, so re-spawns of a thread (and different threads) hit the provider prompt cache. The only
# variable content — the thread's title, workdir, and growing history — trails at the very end.
PROMPT="You are a focused deep-work agent in Roman's system, assigned to ONE bus thread.
Do NOT run any session-start routine and do NOT read the personal context files — you are a worker, not the orchestrator. Do only the work described under YOUR ASSIGNMENT below.

RULES:
- Do the NEXT SINGLE MILESTONE — one coherent, reviewable chunk of progress — then STOP. Do not try to finish the whole job in one run.
- You may Read/Edit/Write files. You may NOT push, commit, or send anything, and you have no shell. Leave irreversible/outward actions to Roman.
- If you need a decision from Roman, or you are blocked or unsure, STOP and ask instead of guessing.
- SKILL CANDIDATE (optional): if in doing this work you worked out a REPEATABLE procedure worth reusing (a workflow, a setup, a protocol), note it on its own line as 'skill-candidate: <kebab-name> — <=60-char description'. It rides your report to the bus and gets proposed to Roman later; do NOT write any skill file yourself.
- APPROVAL PROTOCOL: if you have PREPARED anything irreversible or outward-facing (an email/message draft, a commit-ready diff, a form submission, a file-write that needs sign-off), do NOT apply it — surface it for approval. Put the EXACT artifact VERBATIM (not a summary) between the two markers below, then use the needs_input line to ask. Roman approves/edits/rejects it via an override; you are approving a concrete thing, not an intention.
      -----BEGIN ARTIFACT-----
      <the exact draft / diff / action, verbatim>
      -----END ARTIFACT-----

END your final message with EXACTLY ONE status line, on its own line, one of:
  <<BUS milestone>> one-sentence summary of what you did this run
  <<BUS needs_input>> the specific question or decision you need from Roman (or, per the approval protocol, APPROVE: <one-line label> with the artifact surfaced in the markers just above this line)
  <<BUS blocked>> what is blocking you
  <<BUS done>> one-sentence summary (ONLY if the entire job is now complete)

--- YOUR ASSIGNMENT ---
Thread: \"$TITLE\"  (id $THREAD).
$DIRLINE
Here is the thread so far (your brief, prior milestones, and any steering from Roman) — read it, then continue from where it left off:
-------------------- THREAD $THREAD --------------------
$HISTORY
-------------------------------------------------------

Now do the next single milestone as described above, and end with EXACTLY ONE <<BUS ...>> status line."

# ── run ONE milestone through the choke point (inherits all guards) ───────────
echo "▶ spawning worker '$LABEL' on $THREAD (slot held; tools: $TOOLS; tier: $TIER → model: $MODEL)"
export AGENT_ALLOWED_TOOLS="$TOOLS"
export AGENT_MAX_TURNS="${AGENT_MAX_TURNS_DW:-40}"
OUT="$("$SCRIPT_DIR/run-agent.sh" "$THREAD" "$PROMPT" --model "$MODEL" 2>>"${AGENT_LOG_DIR:-$HOME/.agent-logs}/spawn-agent.log")"

# ── relay the result to the bus (assert the status line; never infer) ─────────
LINE="$(printf '%s\n' "$OUT" | grep -oE '<<BUS (milestone|needs_input|blocked|done)>>.*' | tail -1)"
KIND="$(printf '%s' "$LINE" | sed -E 's/^<<BUS ([a-z_]+)>>.*/\1/')"
BODY="$(printf '%s' "$LINE" | sed -E 's/^<<BUS [a-z_]+>> ?//')"

# P2 approval protocol: if the worker surfaced an irreversible artifact for approval, capture it
# VERBATIM (the single-line status parser above would otherwise truncate a multi-line draft/diff).
# The markers themselves are stripped; only the content between them is carried onto the bus. Require
# BOTH markers — an unmatched BEGIN would otherwise let the sed range run to EOF and swallow the tail.
ARTIFACT=""
if printf '%s\n' "$OUT" | grep -q -- '-----BEGIN ARTIFACT-----' \
   && printf '%s\n' "$OUT" | grep -q -- '-----END ARTIFACT-----'; then
  ARTIFACT="$(printf '%s\n' "$OUT" | sed -n '/-----BEGIN ARTIFACT-----/,/-----END ARTIFACT-----/{/-----\(BEGIN\|END\) ARTIFACT-----/d;p;}')"
fi

# P5: relay any worker-surfaced skill candidate onto the bus so it is NOT silently dropped — the
# worker prompt promises it "rides your report to the bus". The orchestrator surfaces it to Roman
# (propose-and-wait; workers never write skills). Independent of the status line's kind.
SKILLC="$(printf '%s\n' "$OUT" | grep -iE '^[[:space:]]*skill-candidate:' || true)"
[[ -n "$SKILLC" ]] && "${BUS[@]}" write "$THREAD" --kind note --by "$LABEL" --trust "$TRUST" "$SKILLC" >/dev/null

case "$KIND" in
  milestone)
    "${BUS[@]}" write "$THREAD" --kind milestone --by "$LABEL" --trust "$TRUST" "${BODY:-(no summary)}" >/dev/null
    "${BUS[@]}" status "$THREAD" --set needs_input >/dev/null
    notify_fyi "$THREAD" "Milestone ready — approve to continue: ${BODY:-$TITLE}"
    echo "✅ milestone written; thread PAUSED awaiting your approval."
    ;;
  needs_input)
    MSG="${BODY:-needs a decision}"
    # Carry the full artifact (if any) onto the bus so Roman approves the concrete thing, not a label.
    [[ -n "$ARTIFACT" ]] && MSG="$MSG"$'\n\n-----ARTIFACT (for approval)-----\n'"$ARTIFACT"
    "${BUS[@]}" write "$THREAD" --kind question --by "$LABEL" --needs-input --trust "$TRUST" "$MSG" >/dev/null
    echo "🔔 needs_input written (phone alerted); thread paused.$([[ -n "$ARTIFACT" ]] && echo ' Artifact attached for approval.')"
    ;;
  blocked)
    "${BUS[@]}" write "$THREAD" --kind uncertainty --by "$LABEL" --needs-input --trust "$TRUST" "BLOCKED: ${BODY:-unspecified}" >/dev/null
    "${BUS[@]}" status "$THREAD" --set blocked >/dev/null
    echo "🔔 blocked written (phone alerted)."
    ;;
  done)
    "${BUS[@]}" write "$THREAD" --kind completion --by "$LABEL" --trust "$TRUST" "${BODY:-complete}" >/dev/null
    notify_fyi "$THREAD" "Thread complete: ${BODY:-$TITLE}"
    echo "🏁 thread marked done."
    ;;
  *)
    # No clean status line — do NOT guess what happened. Record the tail and flag for review.
    TAIL="$(printf '%s\n' "$OUT" | tail -8)"
    "${BUS[@]}" write "$THREAD" --kind note --by "$LABEL" --trust "$TRUST" "raw output tail: $TAIL" >/dev/null
    "${BUS[@]}" write "$THREAD" --kind question --by "$LABEL" --needs-input --trust "$TRUST" \
      "The worker did not report a clean status line — review its output on this thread." >/dev/null
    echo "⚠️  worker gave no <<BUS …>> status — flagged for your review."
    ;;
esac
# slot releases when this process exits (SLOT_FD closes)
