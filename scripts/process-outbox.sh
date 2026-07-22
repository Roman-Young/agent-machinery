#!/usr/bin/env bash
# process-outbox.sh — apply memory changes REQUESTED by Mac-Kairo.
#
# ══════════════════════════════════════════════════════════════════════════════
# THE GAP THIS CLOSES
#
# Mac-Kairo cannot write memory — the mirror is read-only and overwritten every 5 minutes
# (the one-writer rule; two writers = silent divergence = memory you can't trust).
# And the nightly journal writes only to logs/, deliberately, so an unsupervised agent
# can't mangle the to-do list at 1:45am.
#
# Net effect before this script: if Roman said "add a task" while coding in VS Code, it
# went NOWHERE. It would surface as a line in a log entry and never reach tasks.md — his
# to-do list would silently miss it. That is the exact failure the system exists to prevent.
#
# THE FIX: an OUTBOX, not a second writer.
#
#   Mac-Kairo APPENDS a request  →  ~/cairn/outbox/<timestamp>.md   (on the Mac)
#   rsync ships it up            →  ~/mac-outbox/                   (on the server)
#   THIS script applies it       →  tasks.md / current.md / etc.
#
# The server is still the ONLY writer. The Mac can *request* a change; it cannot *make*
# one. That preserves the invariant while closing the hole.
#
# Requests are IMMUTABLE, TIMESTAMPED FILES, and a ledger records what has been applied —
# so a re-sync can never double-apply, and nothing is ever lost mid-flight.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
[[ -f "$REPO_DIR/.env" ]] && { set +u; source "$REPO_DIR/.env"; set -u; }

OUTBOX="$HOME/mac-outbox"
LEDGER="${AGENT_LOG_DIR:-$HOME/.agent-logs}/outbox-processed.txt"
mkdir -p "$OUTBOX" "$(dirname "$LEDGER")"; touch "$LEDGER"

# Cheap check FIRST: if there's nothing new, exit without spending a single token.
# (This runs hourly. An agent call every hour for nothing would be exactly the kind of
# unbounded spend the boundedness guards exist to prevent.)
PENDING=()
while IFS= read -r f; do
  grep -qxF "$(basename "$f")" "$LEDGER" || PENDING+=("$f")
done < <(find "$OUTBOX" -name '*.md' -type f 2>/dev/null | sort)

if [[ ${#PENDING[@]} -eq 0 ]]; then
  exit 0   # nothing to do, no agent call, no cost
fi

echo "$(date -Is) outbox: ${#PENDING[@]} pending request(s)"
REQUESTS=""
for f in "${PENDING[@]}"; do
  REQUESTS+="--- from $(basename "$f") ---"$'\n'"$(cat "$f")"$'\n\n'
done

export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,Edit,Write,Bash(git add *),Bash(git commit *),Bash(git diff *)"
export AGENT_MAX_TURNS=25
export AGENT_TIMEOUT_SEC=300
export PUSH_OUTPUT=0

OUT=$("$SCRIPT_DIR/run-agent.sh" process-outbox \
"You are Kairo on the server. Mac-Kairo (running in Roman's VS Code) could not write to
memory — that is by design, the server is the only writer — so it left these REQUESTS for
you to apply.

REQUESTS:
$REQUESTS

Apply each one to the right file, following the existing conventions exactly:
- A new task  -> tasks.yaml, under 'tasks:'. Assign the NEXT FREE ID from meta.next_id
                 and increment it. Classify domain (work/school/personal/other) and
                 urgency (red/yellow/green) as best you can. Give it a stake in 'notes',
                 not just an imperative.
- A completed task -> move its entry from 'tasks:' to 'done:' in tasks.yaml, set
                 done_date to today, TRIM notes to a short summary (the full story
                 belongs in today's log, not duplicated in tasks.yaml). NEVER delete it.
- A decision / project-state change -> the relevant projects-*.md or current.md.
- A recurring pattern worth keeping -> recommend it for insights.md, but do NOT edit
  insights.md yourself. Recommend only.
- If tasks.yaml changed AT ALL, run this to regenerate tasks.md (it is a generated
  view — never hand-edit tasks.md directly, it will be silently overwritten):
    python3 \"$REPO_DIR/scripts/render-tasks.py\" \"\$CONTEXT_DIR/tasks.yaml\"

RULES:
- If a request is ambiguous, DO NOT GUESS. Write it into today's log under
  'Needs Roman' and say so in your summary. A wrong task is worse than a missing one.
- Never delete anything. Never touch local-only/.
- Then git add + commit with a message starting 'outbox:'.

Reply with ONE line per request saying what you did.")
RC=$?

if [[ $RC -eq 0 ]]; then
  for f in "${PENDING[@]}"; do basename "$f" >> "$LEDGER"; done
  echo "$OUT"
  "$SCRIPT_DIR/notify.sh" fyi "📥 Applied ${#PENDING[@]} request(s) from VS Code" "$OUT" >/dev/null 2>&1 || true
else
  # Do NOT mark as processed — a failed apply must be retried, never silently dropped.
  echo "$(date -Is) outbox: FAILED (rc=$RC) — requests left pending for the next run"
  exit "$RC"
fi
