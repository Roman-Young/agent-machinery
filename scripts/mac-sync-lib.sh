#!/usr/bin/env bash
# mac-sync-lib.sh — the actual Mac↔server sync logic. Runs ON THE MAC.
#
# ══════════════════════════════════════════════════════════════════════════════
# THIS FILE IS THE FIX FOR "every sync change needs a manual re-install."
#
# Before: the installer FROZE this logic into ~/.cairn/sync.sh as a heredoc. Any fix
# lived in the installer and never reached the Mac until Roman re-ran it — which is why
# the --max-size fix sat inert while 400MB of TCGA data re-synced every 5 minutes.
#
# Now: this file lives in the repo (so it's on the server), and the Mac's tiny bootstrap
# (~/.cairn/run.sh) PULLS THE LATEST COPY each tick and runs it. Edit this file, commit,
# and the next Mac sync (≤5 min) adopts it. No re-install, ever again.
#
# It reads two things from the ENVIRONMENT (set by the bootstrap), so it carries NO
# personal data and is safe in a public repo:
#     SERVER      user@host of the server
#     CAIRN_HOME  where the memory mirror lives on the Mac (default ~/cairn)
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

: "${SERVER:?mac-sync-lib: SERVER not set (the bootstrap must export it)}"
CAIRN_HOME="${CAIRN_HOME:-$HOME/cairn}"

DENY_RE='/(Downloads|Library|Applications|\.Trash|node_modules|\.git)(/|$)'
MAX_PROJECTS=12
EXTRA_PROJECTS=()   # escape hatch: folders that don't match the project heuristic

# Big build junk and datasets must never cross the wire.
# --max-size=25m: keep CODE, skip DATA. A source file is essentially never >25MB; raw
#   data (a 197MB TCGA matrix, a .bam, an .rds) is not something Cairn needs to READ.
# --delete-excluded: REMOVE already-mirrored files that match an --exclude PATTERN
#   (node_modules, venv, …) — this reclaims those correctly.
#
# ⚠️ BUT --delete-excluded does NOT reclaim files skipped by --max-size. A size-capped
# file still EXISTS on the sender, so --delete won't remove the receiver's copy, and
# --max-size is not an --exclude pattern so --delete-excluded ignores it. (My first fix
# wrongly claimed it did; 400MB of TCGA data persisted in the mirror as a result.)
# The real reclaim is the explicit prune AFTER the sync, below.
EX=(--max-size=25m --delete-excluded
    --exclude '.git/objects' --exclude node_modules --exclude venv --exclude .venv
    --exclude target --exclude __pycache__ --exclude '*.pyc' --exclude .DS_Store
    --exclude '*.pepidx' --exclude '*.pkl' --exclude '*.so' --exclude dist
    --exclude build --exclude .next --exclude '*.rds' --exclude '*.h5' --exclude '*.bam')

ssh "$SERVER" "mkdir -p ~/mac-transcripts ~/agent/mac-mirror ~/mac-outbox" 2>/dev/null

# ── DOWN: memory. --delete so a file removed on the server disappears here too, instead
#    of Mac-Cairn reading a ghost. local-only/ deliberately stays server-side.
rsync -az --delete --exclude '.git' --exclude 'local-only' \
  "$SERVER:agent/my-context/" "$CAIRN_HOME/my-context/" 2>/dev/null || true

# ── UP: this Mac's Claude Code transcripts → the server's nightly journal reads them.
[ -d "$HOME/.claude/projects" ] && \
  rsync -az --include '*/' --include '*.jsonl' --exclude '*' \
    "$HOME/.claude/projects/" "$SERVER:mac-transcripts/" 2>/dev/null || true

# ── Discover project folders from the transcripts. Every folder you've run Claude in
#    self-announces (its cwd is recorded), so a new project needs no setup. Guarded so
#    "everything the user ever cd'd into" can't ship a data dump: must exist, be under
#    $HOME, look like a project, not be denied, capped at MAX_PROJECTS.
discover_projects() {
  { for D in "$HOME"/.claude/projects/*/; do
      F=$(find "$D" -maxdepth 1 -name '*.jsonl' -print -quit 2>/dev/null)
      [ -n "$F" ] || continue
      python3 -c "
import json,sys
for l in open(sys.argv[1], errors='ignore'):
    try:
        o=json.loads(l)
        if o.get('cwd'): print(o['cwd']); break
    except Exception: pass
" "$F" 2>/dev/null
    done
    for E in ${EXTRA_PROJECTS[@]+"${EXTRA_PROJECTS[@]}"}; do printf '%s\n' "$E"; done
  } | sort -u | while IFS= read -r P; do
      [ -d "$P" ]                          || continue
      case "$P" in "$HOME"/*) ;; *) continue;; esac
      [ "$P" = "$HOME" ] && continue
      printf '%s' "$P" | grep -qE "$DENY_RE" && continue
      if [ -d "$P/.git" ] || [ -f "$P/package.json" ] || [ -f "$P/pyproject.toml" ] \
         || [ -f "$P/Cargo.toml" ] || [ -f "$P/requirements.txt" ] \
         || [ -f "$P/go.mod" ] || [ -f "$P/Gemfile" ] || [ -f "$P/CLAUDE.md" ] \
         || ls "$P"/*.Rproj >/dev/null 2>&1; then
        printf '%s\n' "$P"
      else
        printf 'SKIP\t%s\n' "$P" >&2   # never skip in silence
      fi
    done | head -n "$MAX_PROJECTS"
}

SKIPPED=$(discover_projects 2>&1 >/dev/null | grep '^SKIP' | cut -f2- || true)
if [ -n "$SKIPPED" ]; then
  echo "  ⚠️  NOT synced (no project marker — run 'git init' and it registers):"
  echo "$SKIPPED" | sed 's|^|        |'
fi

# ── UP: the working trees, including UNCOMMITTED work. No -s / no tilde in the remote
#    path (both were bugs): -s stops the remote shell expanding ~, so it wrote a literal
#    '~' dir. Remote path is relative → rsync-over-ssh lands in $HOME. Errors are SHOWN.
discover_projects 2>/dev/null | while IFS= read -r P; do
  REMOTE_NAME=$(basename "$P" | tr ' ' '-')
  if ERR=$(rsync -az --delete "${EX[@]}" "$P/" "$SERVER:agent/mac-mirror/$REMOTE_NAME/" 2>&1); then
    echo "  synced: $REMOTE_NAME"
  else
    echo "  FAILED: $REMOTE_NAME"; echo "$ERR" | head -3 | sed 's/^/          /'
  fi
done

# ── PRUNE: enforce "no file >25MB in the mirror", the invariant --max-size can't.
#    --max-size stops NEW big files from transferring; this removes ones already there
#    (and any that ever slip through). Self-healing: it asserts the end state rather than
#    trusting rsync's delete semantics. Runs on the server, scoped to the mirror only, so
#    it can never touch anything but oversized cache copies of data that lives on the Mac.
ssh "$SERVER" "find agent/mac-mirror -type f -size +25M -delete" 2>/dev/null || true

# ── UP: the OUTBOX. Mac-Cairn can't write memory (one-writer rule); it leaves requests
#    here and the server applies them. Without this, a task added in VS Code goes nowhere.
mkdir -p "$HOME/cairn/outbox"
rsync -az "$HOME/cairn/outbox/" "$SERVER:mac-outbox/" 2>/dev/null || true

# ── DOWN: the backup tarballs. A tarball on the box it backs up is one copy, not a
#    backup. Pulling it here is the second machine — this is what makes 3-2-1 real.
mkdir -p "$HOME/cairn/backups"
rsync -az "$SERVER:backups/" "$HOME/cairn/backups/" 2>/dev/null || true

# ── HEARTBEAT: record WHEN THE SYNC ACTUALLY RAN, in server time.
#    rsync -a preserves source mtimes, so file timestamps tell you when Roman last EDITED
#    something — not when the Mac last synced. Detecting "the laptop stopped talking to us"
#    needs a real heartbeat: a server-side file stamped with the current time each run.
ssh "$SERVER" "mkdir -p ~/.agent-logs && date +%s > ~/.agent-logs/last-mac-sync" 2>/dev/null || true

echo "$(date '+%F %T') cairn sync ok"
