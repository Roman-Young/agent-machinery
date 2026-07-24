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

- Tonight's journal writes the durable summary of today's chats to:
  \`my-context/logs/$TODAY.md\`  — What happened / Decisions / Open loops.
  That log is what Kairo reads to keep learning you; this folder is just the desk.
- Older, already-logged conversations are swept out of the sidebar to \`$ARCHIVE/\`
  (moved, never deleted).
- Code you actually edit lives in \`~/agent/codebases/\` — open those folders to code.
EOF
  note "created workspace: $DAYDIR"
fi

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
