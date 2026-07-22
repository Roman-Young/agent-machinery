#!/usr/bin/env bash
# weekly-rollup.sh — distils a completed week's daily logs into logs/weekly/YYYY-Www.md.
#
# ADDED 2026-07-22 (Roman's directive): the middle tier of memory. Daily logs are read
# three-deep at session start, so anything older used to fall into a void until it recurred
# hard enough to reach insights.md. This job closes that gap: every Monday it condenses the
# finished week's dailies into one capped rollup, and session start loads the two most
# recent rollups — full detail for ~72h, condensed detail for ~2.5 weeks, insights forever.
# Dailies are never deleted; older history stays on disk for "go back in time" requests.
#
# Follows the nightly-journal v3 rule: THE SCRIPT computes the input list in bash and
# injects it into the prompt. The model only needs Read + Write — no shelling out, no
# permission surface, nothing to deny in a headless run.
#
# Usage: weekly-rollup.sh              → roll up the last COMPLETED ISO week (cron path)
#        weekly-rollup.sh 2026-W29    → backfill / regenerate a specific week
#
# Idempotent: if the target rollup already exists, exits 0 without touching it (cron
# reruns and the DST twin cost nothing). Delete the file first to regenerate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# CONTEXT_DIR is needed HERE, in bash, to build the input list (the v3 rule again).
if [[ -f "$REPO_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
fi
: "${CONTEXT_DIR:?CONTEXT_DIR not set — copy example.env to .env and fill it in}"

# ── Which week? ───────────────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
  WEEK="$1"
  if [[ ! "$WEEK" =~ ^([0-9]{4})-W([0-9]{2})$ ]]; then
    echo "usage: weekly-rollup.sh [YYYY-Www]   e.g. weekly-rollup.sh 2026-W29" >&2
    exit 2
  fi
  YEAR="${BASH_REMATCH[1]}"
  WNUM="${BASH_REMATCH[2]}"
  # ISO week 1 always contains Jan 4; its Monday anchors the whole year.
  DOW=$(date -d "$YEAR-01-04" +%u)
  MON_W1=$(date -d "$YEAR-01-04 - $((DOW - 1)) days" +%F)
  MONDAY=$(date -d "$MON_W1 + $(( (10#$WNUM - 1) * 7 )) days" +%F)
else
  # Last COMPLETED week = the week ending on the most recent past Sunday. On the Monday
  # cron run that Sunday is yesterday; run by hand mid-week it still targets the same
  # finished week, never the one still in progress.
  SUNDAY=$(date -d "last sunday" +%F)
  MONDAY=$(date -d "$SUNDAY - 6 days" +%F)
  WEEK=$(date -d "$MONDAY" +%G-W%V)
fi
WEEK_END=$(date -d "$MONDAY + 6 days" +%F)

OUT_REL="logs/weekly/$WEEK.md"
mkdir -p "$CONTEXT_DIR/logs/weekly"

if [[ -f "$CONTEXT_DIR/$OUT_REL" ]]; then
  echo "$OUT_REL already exists — nothing to do. Delete it first to regenerate."
  exit 0
fi

# ── The week's daily logs that actually exist (a partial week is fine) ────────
DAILIES=()
for i in 0 1 2 3 4 5 6; do
  D=$(date -d "$MONDAY + $i days" +%F)
  [[ -f "$CONTEXT_DIR/logs/$D.md" ]] && DAILIES+=("logs/$D.md")
done

if [[ ${#DAILIES[@]} -eq 0 ]]; then
  echo "No daily logs for $WEEK ($MONDAY..$WEEK_END) — nothing to roll up. Exiting cleanly."
  exit 0
fi
FILE_LIST=$(printf '  - %s\n' "${DAILIES[@]}")
echo "Rolling up $WEEK from ${#DAILIES[@]} daily log(s)."

# ── The newest rollup BEFORE this week, for carried loops and recurrence ──────
# (Strictly before: during backfill the weeks arrive out of order.)
PREV_LINE="(none yet — this is the first weekly rollup)"
for F in "$CONTEXT_DIR/logs/weekly/"*.md; do
  [[ -e "$F" ]] || continue
  B="$(basename "$F")"
  [[ "$B" < "$WEEK.md" ]] && PREV_LINE="logs/weekly/$B"
done

export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,Write"
export AGENT_MAX_TURNS=30
export PUSH_OUTPUT=0

"$SCRIPT_DIR/run-agent.sh" weekly-rollup \
"You are Kairo, distilling a finished week into its weekly rollup. The week is $WEEK,
Monday $MONDAY through Sunday $WEEK_END.

THE WEEK'S DAILY LOGS — read every one of them:
$FILE_LIST

PREVIOUS WEEKLY ROLLUP — read it too (for loops carried forward and recurrence):
  - $PREV_LINE

WRITE $OUT_REL (it does not exist yet). HARD CAP: 150 lines — this file is loaded at
every session start, so every line has a permanent cost. Sections:

  ## Week in brief
     Condensed narrative of the week. SUMMARIZE aggressively; drop day-by-day play-by-play.
  ## Decisions that stuck
     Each with its one-line reasoning. Skip decisions that were reversed within the week.
  ## Open loops carried forward
     Unfinished threads leaving the week, and which of them are going stale.
  ## Insight candidates
     Patterns about Roman or about how this system works, observed 2+ times this week —
     or once this week AND in the previous rollup. Cite the DATES for each. These are
     recommendations only.

RULES:
- Only record what is EVIDENCED by the daily logs. Never invent, never pad a thin week.
- Do NOT edit insights.md. Candidates are proposals; an interactive session raises them
  with Roman (propose-and-wait).
- Never write secrets. Never copy anything out of local-only/.
- Write ONLY $OUT_REL — no other file, nothing outside logs/weekly/."
