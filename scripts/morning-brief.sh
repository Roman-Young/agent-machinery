#!/usr/bin/env bash
# morning-brief.sh — the first automation. Summarizes goals, project
# next-actions, and yesterday's log into a short brief pushed to phone.
# Calendar/tasks get added to the prompt once those MCP servers exist.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PUSH_OUTPUT=1 "$SCRIPT_DIR/run-agent.sh" morning-brief \
  "Produce my morning brief for today. Read goals.md, the Next actions
sections of both project files, and yesterday's and today's log files.
Output: 3-6 short lines — top priorities today, any open loops going
stale, one goal worth keeping in view. Plain text, no markdown, under
500 characters (it goes to a phone notification). Do not modify any
files."
