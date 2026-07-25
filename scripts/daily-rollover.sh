#!/usr/bin/env bash
# daily-rollover.sh — the daily workspace + Claude Code sidebar hygiene.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHAT IT DOES (two jobs, one nightly pass, NO LLM — pure deterministic bash):
#
#   1. Ensures TODAY'S workspace folder exists:  ~/daily/YYYY-MM-DD/
#      This is the standardized place Roman opens Kairo (VS Code Remote-SSH) and talks
#      to it. It is NOT a copy of any code — code lives in ~/agent/codebases/. The folder
#      is the desk; what gets FILED is the day's log (see below).
#
#   2. Archives STALE *conversations* out of the Claude Code sidebar:
#      ~/.claude/projects/<project>/<uuid>.jsonl  →  ~/daily/_archive/<project>/<uuid>.jsonl
#      The left panel lists one entry per conversation transcript. They pile up. This sweeps
#      the old, already-logged ones so the panel collapses to just recent work.
#
#      PER-CONVERSATION, not per-project (changed 2026-07-24). The old version archived a
#      whole project dir only when EVERY chat in it was stale — so a project used daily
#      (agent, daily) kept its ENTIRE pile pinned behind one fresh chat and never tidied.
#      Now each conversation is judged on its own, so a live project collapses to its
#      recent chats while staying open. A conversation is <uuid>.jsonl PLUS an optional
#      <uuid>/ sidecar dir (subagent transcripts); both move together.
#
# WHY THIS ISN'T THE JOURNAL: the journal (nightly-journal.sh) SUMMARIZES each day's chats
# into my-context/logs/YYYY-MM-DD.md — that already exists and is the durable per-day record
# that Kairo reads to learn Roman. THIS script only manages the WORKSPACE and the SIDEBAR.
# The two are ordered deliberately in cron: journal first (01:45) so the day is captured,
# THEN this rollover (03:00) so nothing is archived before it's been logged.
#
# ── THE SAFETY MODEL (why this can't eat un-logged work) ──────────────────────
# A conversation is archived ONLY if BOTH hold:
#   (a) it is idle >= IDLE_HOURS (default 24h) — so the currently-ACTIVE chat, and anything
#       you paused over lunch or overnight and might resume, is never yanked out from under
#       you. Raise ROLLOVER_IDLE_HOURS to keep more days visible; lower it for a tighter panel.
#   (b) its transcript predates the most recent log we wrote — i.e. it has already been
#       journaled. nightly-journal reads from ~/.claude/projects, NOT from _archive, so
#       archiving an un-journaled chat would drop it from the record forever. If the journal
#       stops firing, no new log appears, the cutoff stops advancing, and nothing new is
#       ever archived. This is the literal "never archive an un-logged chat" guarantee.
# Archiving is a MOVE — reversible. The ONE deletion in the whole system is step 3 below:
# archived raw transcripts are purged after RETENTION_DAYS (default 14). Roman's directive
# (2026-07-24): don't hoard raw transcripts — the durable record is the distilled chain
# (daily log → weekly rollup → insights.md). By purge time a transcript has been journaled
# (guard b) and weekly-rolled; the raw text is dead weight and PII surface. NOTE: mv
# preserves mtime, so the 14 days count from the chat's LAST ACTIVITY, not from archiving.
#
# Run  `daily-rollover.sh --dry-run`  to see exactly what it WOULD archive/purge, touching nothing.
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
IDLE_HOURS="${ROLLOVER_IDLE_HOURS:-24}"
IDLE_SECS=$(( IDLE_HOURS * 3600 ))

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
# Kairo — $TODAY

Today's Kairo workspace. Open it in VS Code (Remote-SSH) and talk to Kairo here.

- Tonight's journal writes the durable summary of today's chats to
  \`my-context/logs/$TODAY.md\`, and it appears HERE as \`$TODAY-log.md\`
  once it exists — What happened / Decisions / Open loops. Full history: \`../logs/\`.
  That log is what Kairo reads to keep learning you; this folder is just the desk.
- Older, already-logged conversations are swept out of the sidebar to \`$ARCHIVE/\`
  (moved, never deleted).
- Code you actually edit lives in \`~/agent/codebases/\` — open those folders to code.
EOF
  note "created workspace: $DAYDIR"
fi

# ── 1b. LINK EACH DAY'S LOG INTO ITS WORKSPACE ────────────────────────────────
# The day folder is where Roman looks for "what happened that day" (2026-07-25 —
# he opened ~/daily expecting the record and found only the README). Put the log
# where he looks: symlink logs/<day>.md into <day>/. Idempotent, covers every day
# folder (so it backfills old ones), and skips days whose log doesn't exist yet —
# the next nightly run picks those up (journal fires at 01:45, before this).
for d in "$DAILY_HOME"/20*/; do
  day="$(basename "${d%/}")"
  [[ -f "$LOGDIR/$day.md" && ! -e "$d$day-log.md" ]] || continue
  if [[ $DRY_RUN -eq 1 ]]; then
    note "[dry-run] would link log into $day/"
  else
    ln -s "$LOGDIR/$day.md" "$d$day-log.md"
    note "linked log into $day/"
  fi
done

# ── 2. ARCHIVE STALE CONVERSATIONS (per-chat, so an ACTIVE project still tidies) ─
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
  proj="$(basename "$dir")"
  for jsonl in "$dir"/*.jsonl; do
    mt="$(stat -c %Y "$jsonl" 2>/dev/null)" || { kept=$((kept+1)); continue; }
    idle_ok=$(( (NOW - mt) >= IDLE_SECS ? 1 : 0 ))
    journaled=$(( mt < CUTOFF ? 1 : 0 ))
    idle_h=$(( (NOW - mt) / 3600 ))
    uuid="$(basename "$jsonl" .jsonl)"

    if (( idle_ok == 1 && journaled == 1 )); then
      if [[ $DRY_RUN -eq 1 ]]; then
        note "[dry-run] would archive chat: $proj/$uuid  (idle ${idle_h}h, already journaled)"
      else
        pdest="$ARCHIVE/$proj"; mkdir -p "$pdest"
        # The transcript and its optional <uuid>/ sidecar dir move together.
        for part in "$jsonl" "$dir/$uuid"; do
          [[ -e "$part" ]] || continue
          d="$pdest/$(basename "$part")"
          [[ -e "$d" ]] && d="$pdest/$(basename "$part").$(date +%Y%m%d%H%M%S)"
          mv "$part" "$d"
        done
        note "archived chat: $proj/$uuid  (idle ${idle_h}h)"
      fi
      moved=$((moved+1))
    else
      kept=$((kept+1))
    fi
  done
done

note "done: $moved chat(s) archived, $kept kept active$([[ $DRY_RUN -eq 1 ]] && echo '  (dry-run — nothing moved)')"

# ── 3. RETENTION: purge distilled raw transcripts from _archive ───────────────
# The one sanctioned deletion (see header). Everything here has already been journaled
# (guard b gated its arrival) and weekly-rolled at least once by day 14.
RETENTION_DAYS="${ROLLOVER_RETENTION_DAYS:-14}"
if [[ -d "$ARCHIVE" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    n=$(find "$ARCHIVE" -type f -mtime +"$RETENTION_DAYS" 2>/dev/null | wc -l)
    note "[dry-run] would purge $n archived file(s) older than ${RETENTION_DAYS}d"
  else
    purged=$(find "$ARCHIVE" -type f -mtime +"$RETENTION_DAYS" -print -delete 2>/dev/null | wc -l)
    find "$ARCHIVE" -mindepth 1 -type d -empty -delete 2>/dev/null
    if (( purged > 0 )); then
      note "purged $purged archived file(s) older than ${RETENTION_DAYS}d (already distilled into logs/)"
    fi
  fi
fi
