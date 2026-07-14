#!/usr/bin/env bash
# mac-sync-install.sh — RUN THIS ON YOUR MAC, ONCE.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHAT IT SOLVES: the split brain.
#
# Your code lives on the Mac. Cairn lives on the server. So Cairn cannot see a single
# line of the work it is supposed to help with — and GitHub only shows PUSHED state, so
# everything you haven't committed is invisible too. That is most of what you're
# actually working on at any given moment.
#
# This installs a background job on the MAC that pushes two things up to the server
# every 5 minutes:
#
#   1. Your project WORKING TREES — including uncommitted, half-finished, dirty files.
#      Cairn can then read what you're actually editing, right now, before any commit.
#   2. Your Claude Code SESSION TRANSCRIPTS (~/.claude/projects/*.jsonl).
#      The nightly journal then covers the work you do in VS Code, not just on the server.
#
# YOU NEVER SSH ANYWHERE. The Mac pushes; you don't log in. That was the whole point.
#
# ⚠️ ONE-WAY, AND THAT IS DELIBERATE. Mac -> server. Cairn READS the mirror; it must never
# write to it, because the next rsync would silently overwrite anything it wrote. If Cairn
# has a change to propose, it hands you a diff and you apply it on the Mac. The Mac is the
# source of truth for code; the server is the source of truth for memory. One writer each.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SERVER="${SERVER:-roman@46.224.54.65}"

# Which directories to mirror. EDIT THIS LIST.
PROJECTS=(
  "$HOME/Desktop/PEPMatch2.0"
  # "$HOME/Desktop/LabReach"
  # "$HOME/Desktop/rapacon"
)

REMOTE_CODE="agent/mac-mirror"
REMOTE_TRANSCRIPTS="mac-transcripts"

echo "═══ Cairn Mac sync — installer ═══"
echo "server: $SERVER"

# ── 1. SSH key, so the background job never prompts for a password ──────────────
if [[ ! -f "$HOME/.ssh/id_ed25519" && ! -f "$HOME/.ssh/id_rsa" ]]; then
  echo "No SSH key found. Creating one..."
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
fi
echo "Copying your key to the server (enter your server password ONCE, if asked)..."
ssh-copy-id -o StrictHostKeyChecking=accept-new "$SERVER" 2>/dev/null || true

if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$SERVER" true 2>/dev/null; then
  echo "❌ Passwordless SSH to $SERVER is not working. Fix that first — the background"
  echo "   job cannot type a password. Try:  ssh-copy-id $SERVER"
  exit 1
fi
echo "✅ passwordless SSH works"

# ── 2. The sync script itself ──────────────────────────────────────────────────
mkdir -p "$HOME/.cairn"
cat > "$HOME/.cairn/sync.sh" <<SYNC
#!/usr/bin/env bash
# Pushes the Mac's live working trees + Claude transcripts to the server. One-way.
set -uo pipefail
SERVER="$SERVER"

# Exclusions matter: without them you'd ship gigabytes of build junk over and over,
# and the .pepidx index files alone are enormous.
EX=(
  --exclude '.git/objects' --exclude 'node_modules' --exclude 'venv' --exclude '.venv'
  --exclude 'target' --exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store'
  --exclude '*.pepidx' --exclude '*.pkl' --exclude '*.so' --exclude 'dist' --exclude 'build'
  --exclude '.next' --exclude '*.rds' --exclude '*.h5' --exclude '*.bam'
)

ssh "\$SERVER" "mkdir -p ~/$REMOTE_CODE ~/$REMOTE_TRANSCRIPTS" 2>/dev/null

for P in $(printf '"%s" ' "${PROJECTS[@]}"); do
  [ -d "\$P" ] || continue
  rsync -az --delete "\${EX[@]}" "\$P/" "\$SERVER:~/$REMOTE_CODE/\$(basename "\$P")/" 2>/dev/null
done

# Claude Code session transcripts -> so the nightly journal sees your VS Code work.
[ -d "\$HOME/.claude/projects" ] && \
  rsync -az --include '*/' --include '*.jsonl' --exclude '*' \
    "\$HOME/.claude/projects/" "\$SERVER:~/$REMOTE_TRANSCRIPTS/" 2>/dev/null

echo "\$(date '+%F %T') sync ok"
SYNC
chmod +x "$HOME/.cairn/sync.sh"

# ── 3. launchd — runs every 5 min, survives reboots, invisible to you ───────────
PLIST="$HOME/Library/LaunchAgents/dev.cairn.sync.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.cairn.sync</string>
  <key>ProgramArguments</key><array><string>$HOME/.cairn/sync.sh</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/.cairn/sync.log</string>
  <key>StandardErrorPath</key><string>$HOME/.cairn/sync.log</string>
</dict></plist>
PL

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "✅ launchd job installed — syncs every 5 minutes, starts at login"
echo
echo "Running the first sync now..."
"$HOME/.cairn/sync.sh"
echo
echo "═══════════════════════════════════════════════════════"
echo "Done. Cairn can now read your UNCOMMITTED code at:"
echo "   ~/$REMOTE_CODE/   (on the server)"
echo
echo "Check it's working:  tail ~/.cairn/sync.log"
echo "Add more projects:   edit the PROJECTS list in this script and re-run it"
echo "Stop it:             launchctl unload $PLIST"
echo "═══════════════════════════════════════════════════════"
