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
#   ✔ RECONCILE the day's evidence (2026-07-25): close a task the day's log EXPLICITLY
#     shows finished; point current.md / projects-*.md / open-questions.md at a task id
#     instead of restating its status; drain an open-question whose task is now done.
#     The deterministic half runs first (render-tasks.py --lint) so the LLM only has to
#     adjudicate the flagged candidates, not re-scan every file.
#   ✔ flag anything genuinely ambiguous for Roman, rather than guess
#
# CONSERVATIVE BY DESIGN — unsupervised at night, so evidence-gated + mechanical-safe only:
#   ✖ NEVER delete anything, never touch a durable file (me/goals/soul/insights), never
#     local-only/. Close/drain/reconcile ONLY on explicit evidence — when unsure, FLAG.
#
# Autonomy contract (Roman, 2026-07-25): auto-apply only UNAMBIGUOUS changes (every one a
# reversible git commit); push everything judgment-based to '## Needs Roman (reconciliation)'
# in today's log + the phone summary.
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

# ── Step 2: capture the DETERMINISTIC consistency report to feed the LLM. It adjudicates
# only what the lint already flagged (drain/drift/stale candidates) instead of re-scanning
# every file — the same "let the script do the exact-comparison work" philosophy as above.
LINT_REPORT="(context-lint unavailable)"
if [[ -n "${CONTEXT_DIR:-}" && -f "$CONTEXT_DIR/tasks.yaml" ]]; then
  LINT_REPORT="$(python3 "$SCRIPT_DIR/render-tasks.py" --lint "$CONTEXT_DIR/tasks.yaml" 2>/dev/null || echo '(context-lint failed)')"
fi

export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,Edit,Write,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git status *)"
export AGENT_MAX_TURNS=30
export AGENT_TIMEOUT_SEC=300
export PUSH_OUTPUT=1   # summarise the night's cleanup to the phone

"$SCRIPT_DIR/run-agent.sh" nightly-maintenance \
"You are Kairo doing end-of-day memory hygiene AND reconciliation. Today is $TODAY. Be
CONSERVATIVE — you run unsupervised at night. The autonomy contract (Roman, 2026-07-25):
AUTO-APPLY only UNAMBIGUOUS changes (each is a reversible git commit); everything that needs
judgment goes to '## Needs Roman (reconciliation)' in logs/daily/$TODAY.md — DO NOT guess.

⚠️ tasks.md is ALREADY regenerated from tasks.yaml (overdue-flagging is deterministic in that
render — never compute overdue yourself, never hand-edit tasks.md; it's overwritten on render).

A deterministic consistency check already ran. THESE are your reconciliation candidates —
act on them, do not re-scan every file looking for more:
--- context-lint ---
$LINT_REPORT
---------------------

Do these, in order:

1. current.md — any dated line whose date is now PAST:
   - Strike it through and add '(passed $TODAY)'. Do NOT delete it.
   - If it was purely ephemeral (a one-time event that's over), MOVE it into logs/daily/$TODAY.md
     under '## Expired from current.md', then remove it from current.md (git preserves it).
   - Update current.md's 'Last reviewed:' line to $TODAY.

2. RECONCILE — close tasks the day's log PROVES done. Read logs/daily/$TODAY.md (today's journal)
   and today's git diff. For any open task the log EXPLICITLY states finished — shipped /
   merged / sent / submitted / signed / paid / 'done' — move it tasks:->done: in tasks.yaml,
   set done_date: $TODAY, TRIM notes to a one-line summary. EVIDENCE GATE: 'worked on',
   'made progress', 'drafted', or anything short of explicit completion is NOT done — leave
   it open and add a bullet to '## Needs Roman (reconciliation)'. (Same guard as the course
   sweep: if unsure, FLAG, don't act.)

3. RECONCILE — pointer drift. For each [drift] lint finding (current.md narrates a DONE
   task as if live) and any place current.md / projects-work.md / projects-personal.md /
   open-questions.md restates a task's STATUS in a way that contradicts tasks.yaml: edit the
   prose to POINT at the task id (e.g. 'Live tracker: T69') instead of re-narrating status.
   Keep the durable WHY (the science, the stake); drop the duplicated live-state. Unambiguous
   contradictions only; if it's a judgment call, flag it instead.

4. RECONCILE — drain answered open-questions. For each [drain] lint finding, move that
   question in open-questions.md into its '## ✅ Answered' section as a one-line pointer to
   the task that closed it. Only when that task is genuinely in tasks.yaml 'done:'.

5. tasks.yaml — sweep FINISHED ephemeral courses out of the live list (Roman's rule: a class
   must never linger once it's over):
   - 'done:' entries with domain: school naming a specific course; check current.md's 'The
     term' section for what's still active. If a course is clearly over (not the active term,
     no open task references it), distill into archive/courses/<term>-<course>.md (template in
     courses/README.md) and REMOVE those done entries. If unsure it's finished, DO NOT sweep — flag.

6. Anything else AMBIGUOUS — do NOT guess; add a short bullet to logs/daily/$TODAY.md under
   '## Needs Roman (reconciliation)' and move on.

If tasks.yaml changed at all, re-render: python3 \"$SCRIPT_DIR/render-tasks.py\" \"\$CONTEXT_DIR/tasks.yaml\"

RULES:
- EVIDENCE GATE governs everything: auto-apply only what is UNAMBIGUOUS; when in doubt, FLAG.
- NEVER delete content outright. Strike, annotate, archive, or move — never delete.
- Files you MAY edit: current.md, tasks.yaml (never tasks.md directly), projects-work.md,
  projects-personal.md, open-questions.md, archive/courses/, and today's log. NEVER a durable
  file (me.md, goals.md, soul.md, insights.md, academics.md, voice.md), NEVER local-only/.
- If nothing is stale and the lint is clean, change nothing and say 'nothing stale today.'
- When done, git add + commit with ONE message starting 'maint:'.

Reply in UNDER 400 characters (phone notification): counts + what you CLOSED / reconciled /
drained / swept vs FLAGGED — or 'nothing stale today.'"
