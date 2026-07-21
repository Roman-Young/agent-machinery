#!/usr/bin/env bash
# daily-rollover.sh — the daily workspace + Claude Code history hygiene.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHAT IT DOES (two jobs, one nightly pass, NO LLM — pure deterministic bash):
#
#   1. Ensures TODAY'S workspace folder exists:  ~/daily/YYYY-MM-DD/
#      This is the standardized place Roman opens Cairo (VS Code Remote-SSH) and talks
#      to it. It is NOT a copy of any code — code lives in ~/agent/codebases/. The folder
#      is the desk; what gets FILED is the day's log (see below).
#
#   2. Archives STALE Claude Code session histories out of the sidebar:
#      ~/.claude/projects/<session>  →  ~/daily/_archive/<session>
#      Every folder ever opened leaves a history entry that piles up on the left. This
#      sweeps the old ones so the sidebar collapses to ~today.
#
# WHY THIS ISN'T THE JOURNAL: the journal (nightly-journal.sh) SUMMARIZES each day's chats
# into my-context/logs/YYYY-MM-DD.md — that already exists and is the durable per-day record
# that Cairo reads to learn Roman. THIS script only manages the WORKSPACE and the SIDEBAR.
# The two are ordered deliberately in cron: journal first (01:45) so the day is captured,
# THEN this rollover (03:00) so nothing is archived before it's been logged.
#
# ── THE SAFETY MODEL (why this can't eat un-logged work) ──────────────────────
# A session dir is archived ONLY if BOTH hold:
#   (a) its newest transcript is idle >= 48h — so today's and yesterday's work, and the
#       currently-ACTIVE session (mtime ~now), are never touched. 48h also tolerates up to
#       two consecutive journal failures, which the weekly healthcheck would catch anyway.
#   (b) its newest transcript predates the most recent log we wrote — i.e. it has already
#       been journaled. If the journal stops firing, no new log appears, the cutoff stops
#       advancing, and nothing new is ever archived. This is the literal "never archive an
#       un-logged day" guarantee, not a proxy for it.
# And archiving is a MOVE, never a delete — fully reversible, nothing leaves the disk.
#
# Run  `daily-rollover.sh --dry-run`  to see exactly what it WOULD archive, moving nothing.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

DAILY_HOME="${DAILY_HOME:-$HOME/daily}"
ARCHIVE="$DAILY_HOME/_archive"
PROJECTS="$HOME/.claude/projects"
CONTEXT_DIR="${CONTEXT_DIR:-$HOME/agent/my-context}"
LOGDIR="$CONTEXT_DIR/logs"
TODAY="$(date +%F)"
NOW="$(date +%s)"

note() { echo "$(date '+%F %T') rollover: $*"; }

# ── 1. TODAY'S WORKSPACE ──────────────────────────────────────────────────────
DAYDIR="$DAILY_HOME/$TODAY"
if [[ -d "$DAYDIR" ]]; then
  note "workspace exists: $DAYDIR"
elif [[ $DRY_RUN -eq 1 ]]; then
  note "[dry-run] would create workspace: $DAYDIR"
else
  mkdir -p "$DAYDIR"
  cat > "$DAYDIR/README.md" <<EOF
# Cairo — $TODAY

Today's Cairo workspace. Open it in VS Code (Remote-SSH) and talk to Cairo here.

- Tonight's journal writes the durable summary of today's chats to:
  \`my-context/logs/$TODAY.md\`  — What happened / Decisions / Open loops.
  That log is what Cairo reads to keep learning you; this folder is just the desk.
- Older Claude Code histories are swept out of the sidebar to \`$ARCHIVE/\`
  (moved, never deleted).
- Code you actually edit lives in \`~/agent/codebases/\` — open those folders to code.
EOF
  note "created workspace: $DAYDIR"
fi

# ── 2. ARCHIVE STALE SESSION HISTORIES ────────────────────────────────────────
if [[ ! -d "$PROJECTS" ]]; then
  note "no $PROJECTS — nothing to archive."; exit 0
fi

# Guardrail (b): cutoff = mtime of the most recent log file. Anything older has been
# journaled. No logs yet => we have journaled nothing => archive nothing.
CUTOFF="$(find "$LOGDIR" -maxdepth 1 -name '20*.md' -printf '%T@\n' 2>/dev/null | sort -nr | head -1)"
if [[ -z "$CUTOFF" ]]; then
  note "no journal logs found in $LOGDIR — refusing to archive anything (nothing is logged yet)."
  exit 0
fi
CUTOFF="${CUTOFF%.*}"

[[ $DRY_RUN -eq 0 ]] && mkdir -p "$ARCHIVE"
moved=0; kept=0
shopt -s nullglob
for dir in "$PROJECTS"/*/; do
  dir="${dir%/}"
  name="$(basename "$dir")"
  newest="$(find "$dir" -name '*.jsonl' -printf '%T@\n' 2>/dev/null | sort -nr | head -1)"
  if [[ -z "$newest" ]]; then
    idle_days=999; predates_log=1          # empty/dead dir: safe to archive
  else
    newest="${newest%.*}"
    idle_days=$(( (NOW - newest) / 86400 ))
    predates_log=$(( newest < CUTOFF ? 1 : 0 ))
  fi

  if (( idle_days >= 2 && predates_log == 1 )); then
    if [[ $DRY_RUN -eq 1 ]]; then
      note "[dry-run] would archive: $name  (idle ${idle_days}d, already journaled)"
    else
      dest="$ARCHIVE/$name"
      [[ -e "$dest" ]] && dest="$ARCHIVE/${name}.$(date +%Y%m%d%H%M%S)"
      if mv "$dir" "$dest"; then note "archived: $name  (idle ${idle_days}d)"; fi
    fi
    moved=$((moved+1))
  else
    kept=$((kept+1))
  fi
done

note "done: $moved archived, $kept kept active$([[ $DRY_RUN -eq 1 ]] && echo '  (dry-run — nothing moved)')"
