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
TRANSCRIPT_DIR="$HOME/.claude/projects"

# Transcripts touched in the last 24h. Bash does this; the model never runs find.
mapfile -t FILES < <(find "$TRANSCRIPT_DIR" -name '*.jsonl' -mtime -1 -size +2k 2>/dev/null | head -25)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No session transcripts in the last 24h — nothing to journal. Exiting cleanly."
  exit 0
fi

FILE_LIST=$(printf '  - %s\n' "${FILES[@]}")
echo "Journaling from ${#FILES[@]} transcript(s)."

export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,Edit,Write,Bash(git diff *),Bash(git log *),Bash(git status *)"
export AGENT_MAX_TURNS=40
export PUSH_OUTPUT=0

"$SCRIPT_DIR/run-agent.sh" nightly-journal \
"You are Cairn, writing today's log entry. Today is $TODAY.

TODAY'S SESSION TRANSCRIPTS — read these with the Read tool (they are JSONL, one JSON
object per line; they may be large, so read in chunks and skim for substance rather than
reading every line):
$FILE_LIST

ALSO read:
- git diff and git log for today in this repo (what actually changed on disk).
- logs/$TODAY.md if it already exists. APPEND to it; never clobber what's there.

WRITE logs/$TODAY.md using the existing section shape:
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
