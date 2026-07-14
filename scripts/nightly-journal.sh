#!/usr/bin/env bash
# nightly-journal.sh — writes today's log entry.
#
# REWRITTEN 2026-07-14. The old version only read `git diff` on the context repo,
# so anything DECIDED IN CONVERSATION but never written to a file was invisible to
# it. That's a changelog, not a journal.
#
# It now reads the actual session transcripts (~/.claude/projects/**/*.jsonl) plus
# the repo diff, and distills both.
#
# Write access is deliberately scoped to logs/ only — the journal records, it does
# not reorganize. (Scheduled runs stay inside their prompt's scope.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TODAY="$(date +%F)"
TRANSCRIPTS="$HOME/.claude/projects"

export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,Edit,Write,Bash(git diff *),Bash(git log *),Bash(ls *),Bash(find *)"
export AGENT_MAX_TURNS=40
export PUSH_OUTPUT=0

"$SCRIPT_DIR/run-agent.sh" nightly-journal \
"You are Cairn, writing today's log entry. Today is $TODAY.

SOURCES — read all of these:
1. Session transcripts modified today, under $TRANSCRIPTS (*.jsonl, one JSON object
   per line). These are the actual conversations. Find them with:
   find $TRANSCRIPTS -name '*.jsonl' -newermt '$TODAY'
   They can be large — grep/sample rather than reading every line end to end. You are
   looking for what was DECIDED, what was LEARNED, and what was left OPEN.
2. git diff and git log for today in the context repo — what actually changed on disk.
3. logs/$TODAY.md if it already exists (append; never clobber).

WRITE logs/$TODAY.md using the existing section shape:
  ## What happened   — concise and factual. Summarize, do NOT transcribe.
  ## Decisions       — each dated, each with its reasoning.
  ## Open loops      — what's unfinished, and what's going stale.

RULES:
- Only record what is EVIDENCED by a transcript or the repo. Never invent.
- If a lesson RECURS (you can see it in an older log too), say so explicitly and
  recommend promoting it to insights.md. Do not edit insights.md yourself — recommend.
- Never write secrets. Never copy anything out of local-only/.
- Do not edit ANY file outside logs/. Not tasks.md, not current.md. The journal
  records; it does not reorganize."
