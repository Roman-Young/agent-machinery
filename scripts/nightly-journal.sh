#!/usr/bin/env bash
# nightly-journal.sh — appends a structured entry to today's log by
# reviewing what changed in the context repo today. Write access is
# deliberately scoped to the logs/ directory only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENT_ALLOWED_TOOLS="Read,Glob,Grep,Edit,Write,Bash(git diff *),Bash(git log *)" \
"$SCRIPT_DIR/run-agent.sh" nightly-journal \
  "Review today's changes in this context repo (git diff/log) and
today's log file if it exists. Create or update logs/$(date +%F).md
following the existing log format: What happened / Decisions / Open
loops. Be concise and factual; only record what is evidenced by the
repo or today's entries. Do not edit any file outside logs/."
