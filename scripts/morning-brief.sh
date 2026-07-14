#!/usr/bin/env bash
# morning-brief.sh — the daily brief, pushed to phone via ntfy.
#
# Reads: tasks.md (the single source of truth for actions), current.md,
# recent logs, Gmail, and Google Calendar.
#
# ══════════════════════════════════════════════════════════════════════════
# THE FAIL-LOUD RULE — do not remove this.
#
# A brief that silently can't see Gmail is WORSE than no brief, because Roman
# would trust it and stop checking his own inbox. Verified 2026-07-14: in a
# headless run, an un-allowlisted MCP tool is DENIED with no prompt, and the
# model will happily report "0 threads found" — not because the inbox is empty,
# but because the search never ran.
#
# So: the brief must declare its coverage on line 1, and this script CHECKS it.
# No gmail=ok → no brief. An alert instead.
# ══════════════════════════════════════════════════════════════════════════
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Read-only MCP + read-only files. The brief must never write or send.
# NOTE: create_draft is deliberately ABSENT. The brief reports; it does not act.
export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,\
mcp__claude_ai_Gmail__search_threads,\
mcp__claude_ai_Gmail__get_thread,\
mcp__claude_ai_Gmail__list_labels,\
mcp__claude_ai_Google_Calendar__list_events,\
mcp__claude_ai_Google_Calendar__list_calendars"
export AGENT_MAX_TURNS=30
export PUSH_OUTPUT=0   # we push manually below, AFTER verifying coverage

OUT=$("$SCRIPT_DIR/run-agent.sh" morning-brief \
"You are Cairn, writing Roman's morning brief. Today is $(date +'%A %B %d, %Y').

READ FIRST: tasks.md (the single source of truth for all actions and deadlines),
current.md, and today's + yesterday's files in logs/.

THEN CHECK, in this order:
1. Gmail: search 'newer_than:1d' AND 'label:UCSD newer_than:3d' AND
   'is:starred newer_than:7d'. Look for: anything from dmarrama@lji.org,
   dumar@salk.edu, itam@salk.edu, EAnsaldo@scripps.edu, dramanan@ucsd.edu;
   anything about bills, housing, tuition, deadlines, registration; anything
   from GitHub about IEDB/PEPMatch.
2. Google Calendar: today's events.

OUTPUT FORMAT — obey exactly:

Line 1 MUST be a coverage line, literally:
SOURCES: gmail=ok calendar=ok
Use 'gmail=FAIL' or 'calendar=FAIL' if you could NOT actually retrieve data from
that source. Do not write ok unless a call genuinely returned data. If a tool was
denied, blocked, or errored, that is FAIL. Never guess. Never write 'ok' to be
agreeable — a false ok is the worst possible outcome, because Roman will trust it
and stop checking himself.

Then, after the coverage line, 4-7 SHORT plain-text lines, no markdown:
- Anything DUE today or tomorrow (from tasks.md)
- New email that actually matters (name the sender; skip all retail/newsletter spam)
- Today's calendar, if anything
- The single most important thing to do today
- One open loop going stale, if any

Under 900 characters total — it goes to a phone notification.
Be specific and blunt. No pleasantries. Do not modify any files.")

# ── The check. A brief we can't trust is not sent as a brief. ────────────────
if grep -qi 'gmail=ok' <<<"$OUT"; then
  "$SCRIPT_DIR/notify.sh" "☀️ Morning brief" "$OUT"
else
  "$SCRIPT_DIR/notify.sh" "⚠️ BRIEF DEGRADED — Gmail unreachable" \
"The morning brief could NOT read your email. Do not trust it as complete.
Check your inbox yourself today.

$OUT"
  exit 1   # fail loud: systemd records the failure
fi
