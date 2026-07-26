#!/usr/bin/env bash
# daily-rollover.sh — the daily workspace + Claude Code sidebar hygiene.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHAT IT DOES (two jobs, one nightly pass, NO LLM — pure deterministic bash):
#
#   1. Keeps ~/daily/ stocked with REAL COPIES of the recent daily logs, one file per
#      day (YYYY-MM-DD.md), refreshed nightly — so Roman opens ~/daily in the Claude
#      Code app and reads his diaries right in the file panel.
#      (Rewritten 2026-07-26, Roman's call: the old per-day "desk" folders held only a
#      README and read as clutter to the one person they were for; and the app's file
#      panel does NOT display symlinks — the logs→my-context symlink never appeared for
#      him — so linking the logs in was invisible. Real files or nothing.)
#      Canonical logs stay in my-context/logs/daily — git-tracked, kept forever. The copies
#      here are a read-only VIEW; removing an aged-out copy is sanctioned because the
#      original is never touched.
#
#   2. Archives STALE *conversations* out of the SERVER's session store:
#      ~/.claude/projects/<project>/<uuid>.jsonl  →  ~/daily/_archive/<project>/<uuid>.jsonl
#      This clears the lists that read that store (VS Code extension picker, claude
#      --resume) and drives transcript retention/purge (the privacy job).
#      ⚠️ HONEST LIMIT (confirmed by test, 2026-07-26): the Claude desktop/phone app's
#      chat list is the app's OWN history — archiving here does NOT remove entries there,
#      and opening one re-creates a stub jsonl. Only Roman can delete those, in the app.
#      So the sweep pushes him the list of freshly-stale chats instead (step 2b) — he
#      deletes in-app with zero guesswork, or ignores it at zero cost.
#
#      PER-CONVERSATION, not per-project (changed 2026-07-24). The old version archived a
#      whole project dir only when EVERY chat in it was stale — so a project used daily
#      (agent, daily) kept its ENTIRE pile pinned behind one fresh chat and never tidied.
#      Now each conversation is judged on its own, so a live project collapses to its
#      recent chats while staying open. A conversation is <uuid>.jsonl PLUS an optional
#      <uuid>/ sidecar dir (subagent transcripts); both move together.
#
# WHY THIS ISN'T THE JOURNAL: the journal (nightly-journal.sh) SUMMARIZES each day's chats
# into my-context/logs/daily/YYYY-MM-DD.md — that already exists and is the durable per-day record
# that Kairo reads to learn Roman. THIS script only manages the DAILY PANEL and the SIDEBAR.
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

DAILY_HOME="${DAILY_HOME:-$HOME/daily}"
ARCHIVE="$DAILY_HOME/_archive"
PROJECTS="$HOME/.claude/projects"
CONTEXT_DIR="${CONTEXT_DIR:-$HOME/agent/my-context}"
LOGDIR="$CONTEXT_DIR/logs/daily"
TODAY="$(date +%F)"
NOW="$(date +%s)"
IDLE_HOURS="${ROLLOVER_IDLE_HOURS:-24}"
IDLE_SECS=$(( IDLE_HOURS * 3600 ))

note() { echo "$(date '+%F %T') rollover: $*"; }

# ── 1. THE DAILY PANEL: real copies of recent diaries ─────────────────────────
LOG_DAYS="${ROLLOVER_LOG_DAYS:-14}"

# 1a. Self-healing migration: retire legacy per-day desk folders (2026-07-2x/).
#     Symlinks inside are pointers, not data — dropped; the folders themselves
#     (script-generated READMEs) are MOVED to _archive/day-desks, never deleted.
for d in "$DAILY_HOME"/20*/; do
  d="${d%/}"
  [[ -d "$d" ]] || continue
  day="$(basename "$d")"
  if [[ $DRY_RUN -eq 1 ]]; then
    note "[dry-run] would retire desk folder $day/ to _archive/day-desks/"
    continue
  fi
  find "$d" -maxdepth 1 -type l -delete
  if [[ -z "$(ls -A "$d")" ]]; then
    rmdir "$d"
    note "desk folder $day/ was empty (links only) — removed, nothing to archive"
  else
    mkdir -p "$ARCHIVE/day-desks"
    dest="$ARCHIVE/day-desks/$day"
    [[ -e "$dest" ]] && dest="$dest.$(date +%Y%m%d%H%M%S)"
    mv "$d" "$dest"
    note "retired desk folder $day/ → _archive/day-desks/"
  fi
done

# 1b. Refresh copies of the last LOG_DAYS diaries. chmod a-w marks the copy as a
#     view — the canonical, editable file is the one in my-context/logs/daily. cp -p
#     preserves mtime, so sort-by-modified in the file panel = chronological.
for (( i=0; i<LOG_DAYS; i++ )); do
  day="$(date -d "-$i day" +%F)"
  src="$LOGDIR/$day.md"
  dst="$DAILY_HOME/$day.md"
  [[ -f "$src" ]] || continue
  if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      note "[dry-run] would refresh $day.md"
    else
      rm -f "$dst"; cp -p "$src" "$dst"; chmod a-w "$dst"
      note "refreshed $day.md"
    fi
  fi
done

# 1c. Roll copies older than the window out of the panel. Identical to canonical →
#     remove (original kept forever in my-context/logs/daily). DIFFERS from canonical →
#     move to _archive instead and say so; never lose an edit, even one that
#     shouldn't exist.
CUTOFF_DAY="$(date -d "-$((LOG_DAYS-1)) day" +%F)"
for f in "$DAILY_HOME"/20*.md; do
  [[ -f "$f" ]] || continue
  day="$(basename "$f" .md)"
  [[ "$day" < "$CUTOFF_DAY" ]] || continue
  if [[ $DRY_RUN -eq 1 ]]; then
    note "[dry-run] would roll $day.md out of the panel"
    continue
  fi
  if [[ -f "$LOGDIR/$day.md" ]] && cmp -s "$f" "$LOGDIR/$day.md"; then
    rm -f "$f"
    note "rolled $day.md out of the panel (original lives on in my-context/logs/daily)"
  else
    mkdir -p "$ARCHIVE"
    mv "$f" "$ARCHIVE/$day.md.$(date +%Y%m%d%H%M%S)"
    note "panel copy $day.md DIFFERED from canonical — moved to _archive (investigate)"
  fi
done

# 1d. One top-level README explaining the layout (rewritten only when stale).
readme_tmp="$(mktemp)"
cat > "$readme_tmp" <<EOF
# Kairo — daily

Each file here is one day's diary — What happened / Decisions / Open loops —
refreshed automatically every night. The last $LOG_DAYS days stay in view.

- Today's file appears after tonight's journal writes it; anything from today's
  sessions shows up at the next nightly refresh.
- The permanent originals live in \`my-context/logs/daily/\` and are kept forever.
  These copies are read-only — to add to today's record, just tell Kairo.
- \`_archive/\` holds already-journaled raw chat transcripts (purged after 14 days).
- Code you actually edit lives in \`~/agent/codebases/\`.
EOF
if ! cmp -s "$readme_tmp" "$DAILY_HOME/README.md" 2>/dev/null; then
  if [[ $DRY_RUN -eq 1 ]]; then
    note "[dry-run] would refresh README.md"
  else
    rm -f "$DAILY_HOME/README.md"
    cp "$readme_tmp" "$DAILY_HOME/README.md"
    chmod 644 "$DAILY_HOME/README.md"
    note "refreshed README.md"
  fi
fi
rm -f "$readme_tmp"

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

# Human-readable title of a transcript, for the phone push (the app names chats by
# these). Transcripts carry a summary and/or aiTitle record; fall back to the uuid.
chat_title() {
  local t
  t="$(grep -m1 -o '"summary":"[^"]*' "$1" 2>/dev/null | head -1 | sed 's/^"summary":"//')"
  [[ -z "$t" ]] && t="$(grep -m1 -o '"aiTitle":"[^"]*' "$1" 2>/dev/null | sed 's/^"aiTitle":"//')"
  [[ -z "$t" ]] && t="(untitled $(basename "$1" .jsonl | cut -c1-8))"
  echo "${t:0:70}"
}

[[ $DRY_RUN -eq 0 ]] && mkdir -p "$ARCHIVE"
moved=0; kept=0
TITLES=()
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
      TITLES+=("$(chat_title "$jsonl")")
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

# ── 2b. TELL ROMAN WHICH CHATS WENT STALE (2026-07-26) ────────────────────────
# The Claude app's chat list is app-side history — confirmed by test: a chat stayed
# listed after its transcript was archived server-side AND its tab was closed. No
# server script can prune that list; only Roman can, in the app. So the sweep's job
# here is to remove the GUESSWORK: one silent push naming exactly the chats that are
# stale + already journaled, delivered at a human hour (ntfy Delay), never at 3am.
# Deleting them in the app is cosmetic — content is in the diary, raw text purges
# after RETENTION_DAYS regardless — so an ignored push costs nothing.
if (( moved > 0 )); then
  n=${#TITLES[@]}; shown=("${TITLES[@]:0:10}")
  LIST="$(printf -- '- %s\n' "${shown[@]}")"
  (( n > 10 )) && LIST="$LIST
…and $((n-10)) more"
  MSG="These chats went stale (idle 24h+, already in your diary). If they clutter your Claude app list, they're safe to delete there — nothing is lost:
$LIST"
  if [[ $DRY_RUN -eq 1 ]]; then
    note "[dry-run] would push cleanup list ($n chat(s)) at ${ROLLOVER_NOTIFY_AT:-8am}"
  else
    NOTIFY_DELAY="${ROLLOVER_NOTIFY_AT:-8am}" "$SCRIPT_DIR/notify.sh" fyi \
      "Swept $moved stale chat(s)" "$MSG" || note "WARN: cleanup push failed (sweep itself succeeded)"
  fi
fi

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
