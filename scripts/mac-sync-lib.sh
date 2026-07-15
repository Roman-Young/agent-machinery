#!/usr/bin/env bash
# mac-sync-lib.sh — the Mac↔server sync. Runs ON THE MAC, pulled fresh each tick by the
# bootstrap (~/.cairn/run.sh), so edits here reach the Mac within 5 min with no re-install.
#
# ══════════════════════════════════════════════════════════════════════════════
# THE MODEL — two Cairns, a clean division of labour (simplified 2026-07-15).
#
#   VS Code Cairn  = does the CODING. Has your code natively (it's on the Mac) + your
#                    memory (synced DOWN). It never needs anything mirrored.
#   Server Cairn   = KNOWS and BRIEFS. Learns what you're working on from your VS Code
#                    CONVERSATIONS (synced UP → the nightly journal reads them).
#
# So NO CODE crosses between Mac and server. That entire effort — mirroring working
# trees, project discovery, size caps, the 400MB prune saga — was the server trying to
# do VS Code Cairn's job. Removed. Your conversations carry what you're doing better than
# a pile of files ever could, and the code lives where you code.
#
# FOUR flows remain, and that's the whole story:
#   DOWN  memory      → VS Code Cairn knows you
#   UP    transcripts → server Cairn knows your work (journal reads them)
#   UP    outbox      → memory-change requests VS Code Cairn leaves for the server
#   DOWN  backups     → the 2nd copy that makes the backup a real backup (3-2-1)
#
# Reads two things from the environment (set by the bootstrap), so it holds no personal
# data and is safe in a public repo:  SERVER (user@host)  ·  CAIRN_HOME (default ~/cairn)
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

: "${SERVER:?mac-sync-lib: SERVER not set (the bootstrap must export it)}"
CAIRN_HOME="${CAIRN_HOME:-$HOME/cairn}"

ssh "$SERVER" "mkdir -p ~/mac-transcripts ~/mac-outbox ~/.agent-logs" 2>/dev/null

# ── DOWN: memory. --delete so a file removed on the server disappears here too, instead
#    of VS Code Cairn reading a ghost. local-only/ deliberately stays server-side.
rsync -az --delete --exclude '.git' --exclude 'local-only' \
  "$SERVER:agent/my-context/" "$CAIRN_HOME/my-context/" 2>/dev/null || true

# ── UP: your VS Code Cairn conversations. THIS is how the server learns your work — the
#    nightly journal reads them and writes the log. Only .jsonl transcripts, nothing else.
[ -d "$HOME/.claude/projects" ] && \
  rsync -az --include '*/' --include '*.jsonl' --exclude '*' \
    "$HOME/.claude/projects/" "$SERVER:mac-transcripts/" 2>/dev/null || true

# ── UP: the OUTBOX. VS Code Cairn can't write memory (one-writer rule); it leaves requests
#    here and the server applies them. Without this, a task you add while coding goes nowhere.
mkdir -p "$HOME/cairn/outbox"
rsync -az "$HOME/cairn/outbox/" "$SERVER:mac-outbox/" 2>/dev/null || true

# ── DOWN: the backup tarballs. A tarball on the box it backs up is one copy, not a backup.
#    Pulling it here is the second machine — this is what makes 3-2-1 real.
mkdir -p "$HOME/cairn/backups"
rsync -az "$SERVER:backups/" "$HOME/cairn/backups/" 2>/dev/null || true

# ── HEARTBEAT: record WHEN THE SYNC ACTUALLY RAN, in server time. rsync -a preserves
#    source mtimes, so file timestamps say when you last EDITED something, not when the
#    Mac last synced. Detecting "the laptop stopped talking to us" needs a real heartbeat.
ssh "$SERVER" "date +%s > ~/.agent-logs/last-mac-sync" 2>/dev/null || true

echo "$(date '+%F %T') cairn sync ok"
