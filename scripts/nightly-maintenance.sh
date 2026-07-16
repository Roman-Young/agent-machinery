#!/usr/bin/env bash
# nightly-maintenance.sh — end-of-day memory hygiene. Keeps current.md and tasks.md honest
# against today's date, so the memory doesn't rot the way it did (a passed midterm sat in
# current.md for days).
#
# ══════════════════════════════════════════════════════════════════════════════
# CONSERVATIVE BY DESIGN — this is an UNSUPERVISED agent editing the memory at night, so
# it does the SAFE, MECHANICAL parts only and FLAGS everything else:
#   ✔ strike a hard deadline whose date is in the past (annotate, don't delete)
#   ✔ move a clearly-expired ephemeral item from current.md into today's log (archive)
#   ✔ update current.md's "Last reviewed" date
#   ✔ flag a NOW-task whose due date has passed (mark ⏰ OVERDUE — never auto-complete it;
#     only Roman knows if it's done)
#   ✖ NEVER delete anything, never resolve a judgment call, never touch a durable file,
#     never touch local-only/. Ambiguous things get written into today's log for Roman.
#
# Every change is git-committed (reversible) and summarised to the phone (transparent).
# It runs right after the nightly journal so it sees the day's final state.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TODAY="$(date +%F)"

export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,Edit,Write,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git status *)"
export AGENT_MAX_TURNS=30
export AGENT_TIMEOUT_SEC=300
export PUSH_OUTPUT=1   # summarise the night's cleanup to the phone

"$SCRIPT_DIR/run-agent.sh" nightly-maintenance \
"You are Cairo doing end-of-day memory hygiene. Today is $TODAY. Be CONSERVATIVE — you are
running unsupervised at night, so do only the safe mechanical parts and FLAG the rest.

Read current.md and tasks.md. Then, comparing every date against today ($TODAY):

1. current.md — 'Hard deadlines' / any dated line whose date is now PAST:
   - Strike it through and add '(passed $TODAY)'. Do NOT delete it.
   - If it was a purely ephemeral item (a one-time event that's over), MOVE it into
     logs/$TODAY.md under an '## Expired from current.md' heading, then remove it from
     current.md. (git preserves it; this is archiving, not deleting.)
   - Update current.md's 'Last reviewed:' line to $TODAY.

2. tasks.md — a task in the NOW/dated section whose due date has PASSED:
   - Prepend '⏰ OVERDUE — ' to its task text. Do NOT move it to Done and do NOT complete
     it — only Roman knows if it actually happened. Just make it visibly overdue.

3. Anything AMBIGUOUS (is this still relevant? did this happen? should this be dropped?):
   - Do NOT guess. Write it into logs/$TODAY.md under '## Needs Roman (staleness review)'
     as a short bullet, and move on.

RULES:
- NEVER delete content. Strike, annotate, or move-to-log only.
- Touch ONLY current.md, tasks.md, and today's log. Never a durable file (me.md, goals.md,
  soul.md, insights.md), never local-only/, never courses/ or archive/.
- If nothing is stale, change nothing and say 'nothing stale today.'
- When done, git add + commit with a message starting 'maint:'.

Reply in UNDER 400 characters (it's a phone notification): what you struck, moved, or
flagged — or 'nothing stale today.'"
