#!/usr/bin/env bash
# nightly-maintenance.sh — end-of-day memory hygiene. Keeps current.md and tasks.yaml
# honest against today's date, so the memory doesn't rot the way it did (a passed
# midterm sat in current.md for days).
#
# ══════════════════════════════════════════════════════════════════════════════
# REWRITTEN 2026-07-17 alongside the tasks.yaml migration.
#
# Overdue-detection used to be an LLM job: read tasks.md prose, compare dates by eye,
# prepend "OVERDUE" text. That is the exact failure class this system has been bitten
# by before (LLM inference doing a job a script does exactly). Now that tasks.yaml has
# a real `due:` field, overdue-detection is DETERMINISTIC and lives entirely in
# render-tasks.py — it recomputes "is this overdue" from today() vs the due date on
# every render, so it can never go stale and this script doesn't need to touch it.
#
# What's LEFT for an LLM to judge (genuinely ambiguous, so it stays here):
#   ✔ current.md hygiene — strike passed dates, archive expired ephemera, bump
#     "Last reviewed" (current.md is still prose; it's state notes, not a task list)
#   ✔ sweep a FINISHED course's done-tasks out of tasks.yaml into archive/courses/,
#     per Roman's rule (2026-07-17): a class must never linger in the live list once
#     it's over. This needs a judgment call (is the course actually over?), so it's
#     not automated further than "flag + do it carefully."
#   ✔ flag anything genuinely ambiguous for Roman, rather than guess
#
# CONSERVATIVE BY DESIGN — unsupervised at night, so mechanical-safe parts only:
#   ✖ NEVER delete anything, never touch a durable file, never touch local-only/.
#
# Every change is git-committed (reversible) and summarised to the phone.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TODAY="$(date +%F)"

# ── Step 1: DETERMINISTIC re-render, always, regardless of what the LLM does below.
# Cheap safety net — if any earlier edit to tasks.yaml never got re-rendered (a missed
# outbox commit, a manual edit), this guarantees tasks.md is never more than a day stale.
if [[ -f "$REPO_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
fi
if [[ -n "${CONTEXT_DIR:-}" && -f "$CONTEXT_DIR/tasks.yaml" ]]; then
  python3 "$SCRIPT_DIR/render-tasks.py" "$CONTEXT_DIR/tasks.yaml" \
    && echo "[$(date -Is)] nightly-maintenance: re-rendered tasks.md" >> "${AGENT_LOG_DIR:-$HOME/.agent-logs}/maintenance.log"
fi

export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,Edit,Write,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git status *)"
export AGENT_MAX_TURNS=30
export AGENT_TIMEOUT_SEC=300
export PUSH_OUTPUT=1   # summarise the night's cleanup to the phone

"$SCRIPT_DIR/run-agent.sh" nightly-maintenance \
"You are Kairo doing end-of-day memory hygiene. Today is $TODAY. Be CONSERVATIVE — you are
running unsupervised at night, so do only the safe judgment-call parts and FLAG the rest.

⚠️ tasks.md has ALREADY been regenerated from tasks.yaml (deterministic overdue-flagging
happens automatically in that render step — you do NOT need to compute or mark overdue
tasks yourself, and you must NEVER hand-edit tasks.md, it will be silently overwritten on
the next render).

Do these, in order:

1. current.md — 'Hard deadlines' / any dated line whose date is now PAST:
   - Strike it through and add '(passed $TODAY)'. Do NOT delete it.
   - If it was a purely ephemeral item (a one-time event that's over), MOVE it into
     logs/$TODAY.md under an '## Expired from current.md' heading, then remove it from
     current.md. (git preserves it; this is archiving, not deleting.)
   - Update current.md's 'Last reviewed:' line to $TODAY.

2. tasks.yaml — sweep FINISHED ephemeral courses out of the live list (Roman's rule,
   2026-07-17: a class must never linger here once it's over):
   - Look at 'done:' entries with domain: school whose title references a specific
     course. Check current.md's 'The term' section for what's actually still active.
   - If a course is clearly over (not the active term, no open tasks reference it),
     write a short distillation into archive/courses/<term>-<course>.md (create it if
     needed — see courses/README.md for the template) and REMOVE those done entries
     from tasks.yaml's 'done:' list. This is the one place removal is correct — the
     content isn't lost, it moved to archive/.
   - If you're not sure a course is actually finished, DO NOT sweep it. Flag it instead.
   - If tasks.yaml changed, re-render: python3 \"$SCRIPT_DIR/render-tasks.py\" \"\$CONTEXT_DIR/tasks.yaml\"

3. Anything AMBIGUOUS (is this still relevant? did this happen? should this be dropped?):
   - Do NOT guess. Write it into logs/$TODAY.md under '## Needs Roman (staleness review)'
     as a short bullet, and move on.

RULES:
- NEVER delete content outright. Strike, annotate, archive, or move — never delete.
- Touch ONLY current.md, tasks.yaml (never tasks.md directly), archive/courses/, and
  today's log. Never a durable file (me.md, goals.md, soul.md, insights.md), never
  local-only/.
- If nothing is stale and no course needs sweeping, change nothing and say 'nothing stale today.'
- When done, git add + commit with a message starting 'maint:'.

Reply in UNDER 400 characters (it's a phone notification): what you struck, archived, swept,
or flagged — or 'nothing stale today.'"
