#!/usr/bin/env bash
# nightly-journal.sh — writes today's log entry from the day's actual conversations.
#
# REWRITTEN 2026-07-14 (twice).
#
# v1 read only `git diff` on the context repo — so anything DECIDED IN CONVERSATION but
# never written to a file was invisible. A changelog, not a journal.
#
# v2 asked the model to run `find` itself. IT FAILED: `Bash(find *)` is denied by the
# permission rules, and in a headless run a denied tool cannot prompt — the job just died.
# Caught by test-firing it; it would have failed at 01:45 tonight and pushed a failure alert.
#
# v3 (this): THE SCRIPT computes the transcript list in bash and injects it into the prompt.
# The model only needs Read. No shelling out, no permission surface, nothing to deny.
# General rule: compute the inputs in the wrapper; don't make the LLM go get them.
#
# Write access is deliberately scoped to logs/ — the journal records, it does not reorganize.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TODAY="$(date +%F)"

# BOTH transcript sources:
#   ~/.claude/projects   — sessions that ran ON THE SERVER (Paseo, ssh)
#   ~/mac-transcripts    — sessions from VS CODE ON THE MAC, rsynced up by mac-sync-install.sh
# Without the second, the journal covers only half his life — and the half it misses is
# the half where he actually writes code.
mapfile -t FILES < <(
  find "$HOME/.claude/projects" "$HOME/mac-transcripts" \
       -name '*.jsonl' -mtime -1 -size +2k 2>/dev/null | head -30
)

# SECOND SOURCE (added 2026-07-24): the day's HEADLESS job outputs. run-agent.sh now passes
# --no-session-persistence, so scheduled runs (triage, brief, maintenance…) leave NO
# transcript in ~/.claude/projects — their record is the per-job output log run-agent.sh
# writes. Without this source, a day with no interactive sessions would journal as "nothing
# happened" while the automations all ran. (Job logs are named YYYY-MM-DD-<job>.log.)
mapfile -t JOBLOGS < <(
  find "${AGENT_LOG_DIR:-$HOME/.agent-logs}" -maxdepth 1 -type f \
       -name '20*-*.log' -mtime -1 2>/dev/null | head -20
)

if [[ ${#FILES[@]} -eq 0 && ${#JOBLOGS[@]} -eq 0 ]]; then
  echo "No transcripts or job logs in the last 24h — nothing to journal. Exiting cleanly."
  exit 0
fi

FILE_LIST="  (none — no interactive sessions in the last 24h)"
[[ ${#FILES[@]} -gt 0 ]] && FILE_LIST=$(printf '  - %s\n' "${FILES[@]}")
JOBLOG_LIST="  (none — no scheduled jobs ran in the last 24h)"
[[ ${#JOBLOGS[@]} -gt 0 ]] && JOBLOG_LIST=$(printf '  - %s\n' "${JOBLOGS[@]}")
echo "Journaling from ${#FILES[@]} transcript(s) + ${#JOBLOGS[@]} job log(s)."

export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,Edit,Write,Bash(git diff *),Bash(git log *),Bash(git status *)"
export AGENT_MAX_TURNS=40
export PUSH_OUTPUT=0

"$SCRIPT_DIR/run-agent.sh" nightly-journal \
"You are Kairo, writing today's log entry. Today is $TODAY.

TODAY'S SESSION TRANSCRIPTS — read these with the Read tool (they are JSONL, one JSON
object per line; they may be large, so read in chunks and skim for substance rather than
reading every line):
$FILE_LIST

TODAY'S SCHEDULED-JOB OUTPUT LOGS — read these too. Each is a headless job's own output
(triage decisions, brief content, maintenance actions). Record what the automations DID,
briefly — routine no-op runs ('no new mail', 'nothing stale') get at most one line total:
$JOBLOG_LIST

ALSO read:
- git diff and git log for today in this repo (what actually changed on disk).
- logs/daily/$TODAY.md if it already exists. APPEND to it; never clobber what's there.

WRITE logs/daily/$TODAY.md using the existing section shape:
  ## What happened   — concise and factual. SUMMARIZE, do not transcribe.
  ## Decisions       — each with its reasoning.
  ## Open loops      — what's unfinished, and what is going stale.

RULES:
- Only record what is EVIDENCED by a transcript or the repo diff. Never invent.
- If today's log already contains detailed hand-written entries, do NOT duplicate them.
  Add only what is genuinely missing, or a short synthesis at the end. Redundancy makes
  the log unreadable, and an unreadable log is one nobody reads.
- If a lesson RECURS (you can see the same pattern in an older log), say so explicitly and
  recommend promoting it to insights.md. Do NOT edit insights.md yourself — recommend only.
- Never write secrets. Never copy anything out of local-only/.
- Do not edit ANY file outside logs/. Not tasks.md, not current.md. The journal records;
  it does not reorganize."
