#!/usr/bin/env bash
# cairn-on-mac-install.sh — RUN THIS ON YOUR MAC, ONCE. It is the ONLY Mac installer.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHAT IT DOES, IN ONE LINE:
#   Makes the Claude Code on your Mac BE Cairn — and keeps it in sync with the server.
#
# Cairn is not a program. It is a Claude Code session that has read your context files.
# The Claude in your VS Code has never read them, so it doesn't know who you are. This
# fixes that by putting the context ON the Mac and pointing every session at it.
#
# THE GAP THIS ACTUALLY CLOSES: the Claude converting your Python to Rust — for a paper
# you are FIRST-AUTHORING, under active review by an IEDB maintainer — has no idea Rust is
# high-stakes for you, or that "unearned fluency is a liability" is your own thesis. It
# just writes the Rust and hands it over. After this, it teaches instead.
#
# THERE IS NO LIVE CONNECTION between the two Cairns. They are not talking to each other.
# They SHARE FILES, synced every 5 minutes. That's the whole mechanism.
#
#   memory      server ──▶ Mac   (so Mac-Cairn knows you)
#   transcripts Mac    ──▶ server (so the nightly journal sees your VS Code work)
#   code        Mac    ──▶ server (optional; so you can ask Cairn about uncommitted
#                                  code FROM YOUR PHONE)
#
# ⚠️ THE ONE-WRITER RULE — everything depends on it:
#   The SERVER owns memory.  Mac-Cairn reads it, never writes it.
#   The MAC owns code.       Server-Cairn reads it, never writes it.
#   Two writers to one memory = silent divergence = memory you can't trust = system dead.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── The server address. Supply it however you like; if you don't, we ask. ─────
# It is NOT hardcoded: this repo is public, and a server IP + login in a public repo is
# an invitation to brute-force. (An earlier version DID hardcode it. Scrubbing that is
# what broke this script — the default was removed and nothing replaced it, so SERVER was
# empty and ssh-copy-id hung on nothing. Fixed 2026-07-14.)
SERVER="${1:-${SERVER:-}}"
if [[ -z "$SERVER" ]]; then
  read -rp "Server (user@host, e.g. roman@203.0.113.9): " SERVER
fi
[[ -n "$SERVER" ]] || { echo "❌ No server given. Re-run: bash $0 user@host"; exit 1; }

CAIRN_HOME="$HOME/cairn"

# Working trees to push UP, so you can ask Cairn about uncommitted code from your phone.
# Leave empty to skip. Editing this list and re-running is safe — it's idempotent.
# ── PROJECT DISCOVERY — you should never have to edit this file again ─────────
#
# A hardcoded list means every new project needs an edit and a re-install. That is not a
# system, it is a chore, and chores get skipped — after which Cairn is silently blind to
# your newest work and nobody notices.
#
# So it DISCOVERS instead. Claude Code records the working directory of every session in
# ~/.claude/projects/*/*.jsonl. Any folder where you have ever run `claude` is therefore
# self-announcing. Start a new project, use Cairn in it once, and the next sync (≤5 min)
# picks it up. Zero maintenance, forever.
#
# Guarded, because "sync everything the user ever cd'd into" is how you ship 40GB of
# Downloads over a home connection:
#   - must still exist
#   - must live under $HOME
#   - must LOOK like a project (.git / package.json / pyproject.toml / Cargo.toml / *.Rproj)
#     -> this alone excludes ~/Downloads/filtered_gene_bc_matrices (a dataset, not code)
#   - must not be a denied path (Downloads, Library, .Trash, the home dir itself)
#   - capped at MAX_PROJECTS, so a runaway can't fill the server
#
# EXTRA_PROJECTS below is an escape hatch for anything that doesn't fit the heuristic.
EXTRA_PROJECTS=()
DENY_RE='/(Downloads|Library|Applications|\.Trash|node_modules|\.git)(/|$)'
MAX_PROJECTS=12

echo "═══ Installing Cairn on this Mac ═══"
echo "server: $SERVER"
echo

# ── 1. NON-INTERACTIVE SSH ────────────────────────────────────────────────────
# The background sync runs with no terminal. It cannot type a password, and it cannot
# type a KEY PASSPHRASE either — which is the subtler trap, because interactive ssh works
# fine and you'd never notice. On macOS the fix is the login Keychain: store the passphrase
# once, and ssh (including from launchd) retrieves it silently.
HOST="${SERVER#*@}"

ssh_works() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$SERVER" true 2>/dev/null; }

if ssh_works; then
  echo "✅ non-interactive SSH already works"
else
  echo "Setting up non-interactive SSH…"

  if [[ ! -f "$HOME/.ssh/id_ed25519" && ! -f "$HOME/.ssh/id_rsa" ]]; then
    echo "  no SSH key found — creating one (no passphrase, for automation)"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
  fi
  KEY="$HOME/.ssh/id_ed25519"; [[ -f "$KEY" ]] || KEY="$HOME/.ssh/id_rsa"

  # Teach ssh to use the Keychain for this host, so launchd never sees a prompt.
  touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
  if ! grep -qE "^[[:space:]]*Host[[:space:]].*\b${HOST}\b" "$HOME/.ssh/config" 2>/dev/null; then
    printf '\nHost %s\n  User %s\n  AddKeysToAgent yes\n  UseKeychain yes\n  IdentityFile %s\n  ServerAliveInterval 60\n' \
      "$HOST" "${SERVER%@*}" "$KEY" >> "$HOME/.ssh/config"
    echo "  ✅ added a Host block to ~/.ssh/config (UseKeychain)"
  fi

  # Store the passphrase in the login Keychain. Prompts ONCE, here, with a terminal.
  # This is the step that makes the background job work.
  echo "  → If your key has a passphrase, enter it ONCE now. macOS will remember it."
  ssh-add --apple-use-keychain "$KEY" 2>/dev/null || ssh-add -K "$KEY" 2>/dev/null || true

  # Only now, if we still can't get in, is the key actually not authorized on the server.
  if ! ssh_works; then
    echo "  key not authorized on the server yet — copying it up (enter your SERVER password once)"
    ssh-copy-id -o StrictHostKeyChecking=accept-new "$SERVER" || true
  fi

  if ! ssh_works; then
    cat <<EOF

❌ Non-interactive SSH still isn't working, and the background sync cannot type anything.

Try, in order:
  1.  ssh-add --apple-use-keychain ~/.ssh/id_ed25519     # store the passphrase
  2.  ssh-copy-id $SERVER                                # authorize this Mac
  3.  ssh -o BatchMode=yes $SERVER true && echo OK       # must print OK

If you don't know the server password:
  Hetzner Console → Rescue → Reset root password → web Console → 'passwd roman'
EOF
    exit 1
  fi
fi
echo "✅ non-interactive SSH works (the background job can now run unattended)"

# ── 2. THE SELF-UPDATING SYNC ─────────────────────────────────────────────────
# The sync LOGIC no longer lives here. It lives in the repo (mac-sync-lib.sh), so it's on
# the server. This installs a tiny, STABLE bootstrap that each tick PULLS THE LATEST logic
# from the server and runs it. After this one install, any sync fix propagates on its own
# within 5 minutes — you never re-run this installer for a sync change again.
#
# This is the same principle as project auto-discovery: a setup step that must be manually
# repeated is a step that gets skipped. The old installer froze the logic into
# ~/.cairn/sync.sh, so the --max-size fix sat inert while 400MB re-synced every 5 minutes.
mkdir -p "$HOME/.cairn" "$CAIRN_HOME"

cat > "$HOME/.cairn/run.sh" <<BOOTSTRAP
#!/usr/bin/env bash
# Cairn sync bootstrap — STABLE. Pulls the latest sync logic and runs it.
# Only SERVER/CAIRN_HOME are frozen here (they rarely change); the LOGIC self-updates.
set -uo pipefail
export SERVER="$SERVER"
export CAIRN_HOME="$CAIRN_HOME"
LIB="\$HOME/.cairn/sync.sh"

# Pull the latest logic to a temp file, validate it, and adopt it ONLY if it's good.
# If the server is unreachable OR the pull is corrupt, we keep the last-known-good copy —
# a bad pull can never break the sync.
if rsync -az "\$SERVER:agent/agent-machinery/scripts/mac-sync-lib.sh" "\$HOME/.cairn/sync.new" 2>/dev/null \\
   && bash -n "\$HOME/.cairn/sync.new" 2>/dev/null; then
  mv "\$HOME/.cairn/sync.new" "\$LIB"
else
  rm -f "\$HOME/.cairn/sync.new" 2>/dev/null || true
fi

[ -f "\$LIB" ] && exec bash "\$LIB"
echo "cairn: no sync logic yet (server unreachable on first run?)" >&2
exit 1
BOOTSTRAP
chmod +x "$HOME/.cairn/run.sh"

# Seed the logic immediately so the first run works even before the bootstrap's own pull.
if rsync -az "$SERVER:agent/agent-machinery/scripts/mac-sync-lib.sh" "$HOME/.cairn/sync.sh" 2>/dev/null; then
  echo "✅ pulled the current sync logic from the server"
else
  echo "⚠️  couldn't pull sync logic (is the server reachable?) — the bootstrap will retry each tick"
fi

echo "Running first sync (this may take a moment)..."
"$HOME/.cairn/run.sh" || echo "  (first sync had a hiccup — the 5-min job will retry)"
echo "✅ memory mirrored to $CAIRN_HOME/my-context"

# ── 3. The bit that makes Mac-Claude into Cairn ───────────────────────────────
# ~/.claude/CLAUDE.md loads in EVERY Claude Code session on this Mac — every folder,
# the VS Code extension panel, and the integrated terminal alike. All of them run
# locally on the Mac, so all of them read this file.
mkdir -p "$HOME/.claude"
[[ -f "$HOME/.claude/CLAUDE.md" ]] && \
  cp "$HOME/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md.bak.$(date +%Y%m%d-%H%M%S)" && \
  echo "(backed up your existing ~/.claude/CLAUDE.md)"

cat > "$HOME/.claude/CLAUDE.md" <<'MD'
# You are Cairn.

Roman's personal agent — the same agent that runs on his server. Same identity, same
memory, same contract. You are simply running on his Mac, which means you can see his
actual code, including everything he hasn't committed.

## Read this before you do anything

His memory is at `~/cairn/my-context/`. **Read these at the start of every session:**

- `soul.md` — who you are.
- `me.md` — who he is, and the behavior contract. Follow it literally.
- `insights.md` — **what you have learned by watching him.** The important one.
- `goals.md`, `current.md` (term, schedule, deadlines), `tasks.md` (the single to-do list).

Load on demand: `learning.md` (before ANY teaching), `voice.md` (before ANY email draft),
`reference/` (project briefings), `projects-work.md` / `projects-personal.md`.

**If it isn't in those files, you don't know it.** Say "I don't have that context" rather
than inventing.

## ⚠️ ONE-WRITER RULE — do not break this

`~/cairn/my-context/` is a **READ-ONLY MIRROR.** Never write to it, never edit it, never
commit in it. It is overwritten from the server every 5 minutes, so anything you write is
silently destroyed — and two writers make the memory diverge, which makes it untrustworthy,
which kills the system.

**The server owns memory. This Mac owns code.**

### How to remember things anyway — THE OUTBOX

You cannot write memory. But you can **request** a change, and the server will apply it.

**When Roman says "add a task", "remind me to X", "I finished Y", or tells you something
worth remembering — write a request file:**

```
~/cairn/outbox/<YYYY-MM-DD-HHMMSS>-<short-slug>.md
```

Plain English inside. For example:

```markdown
ADD TASK: Email Danish about the IEL panel before Friday.
Why it matters: he's blocked on the staining schedule.
```
```markdown
DONE: T10 — finished the Seurat QC vignette.
```

**Then TELL HIM you've queued it**, e.g. *"Queued that for your task list — it'll land
within the hour."* The server picks it up, applies it to `tasks.md` with a proper ID, and
pushes you a confirmation.

**One file per request. Never edit or delete an existing one** — they are immutable, and a
ledger on the server tracks what's been applied, so nothing double-applies and nothing gets
lost.

If something is worth remembering but isn't a task — a decision, a lesson, a changed plan —
**also say it explicitly in your final message.** The transcript ships to the server and the
nightly journal reads it into the log. The loop closes; it just closes through the server,
on purpose, so there is exactly one writer.

## The rule that matters most here

**Rust is HIGH STAKES.** Roman is *learning* it. He writes Python and has Claude convert
the logic to Rust — and he is **first-authoring a paper on that Rust engine**, with an IEDB
maintainer actively reviewing his PRs.

Keep the Python-first workflow; it's sound (Python *is* the spec — PEPMatch's own philosophy
makes the Python oracle the arbiter of correctness). **But never hand him Rust as a black
box.** After a conversion, make him read it back: what does this borrow, why `&[u8]` and not
`Vec<u8>`, where does the DFS recurse, what does `seen` actually dedup? Then quiz him. Five
minutes, not a lecture.

Use **his own mechanism** on him — from LabReach: *"what question will the reviewer ask
back, and can you answer it?"* He built that test and never points it at himself.

**The bar is not "wrote it unaided." It is "can defend every line."** Read `learning.md` and
the PEPMatch invariants before touching that code. Same for R/Seurat and major coursework.
GE courses: efficient help is fine.

## The rest of the contract

- **Structure, not open-endedness.** Ordered, checkable steps. Never a blank canvas —
  propose a concrete first step. He runs on small wins.
- **Check his scope.** He over-commits and underestimates time. Say so.
- **Draft, never send.** Email is draft-only, always.
- **Be direct.** Push back with reasoning when a plan conflicts with a goal. Agreeing with
  him when he's wrong is a failure.
- **Never delete something you don't understand — flag it.**
MD

echo "✅ ~/.claude/CLAUDE.md installed — every Claude Code session on this Mac is now Cairn"

# ── 4. launchd: keep it fresh, survive reboots ────────────────────────────────
PLIST="$HOME/Library/LaunchAgents/dev.cairn.sync.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.cairn.sync</string>
  <key>ProgramArguments</key><array><string>$HOME/.cairn/run.sh</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/.cairn/sync.log</string>
  <key>StandardErrorPath</key><string>$HOME/.cairn/sync.log</string>
</dict></plist>
PL
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "✅ launchd installed — syncs every 5 min, starts at login"

cat <<EOF

═══════════════════════════════════════════════════════════════
Done. Open VS Code, run \`claude\` in any project folder, and ask:

    "who am I?"

If it knows about PEPMatch, Salk, and the 2-indel PR — Cairn is home.

  memory mirror : $CAIRN_HOME/my-context   ← READ-ONLY. Never edit.
  backups       : $CAIRN_HOME/backups      ← the 2nd copy. This is what makes it a backup.
  identity      : ~/.claude/CLAUDE.md
  sync log      : tail ~/.cairn/sync.log
  add projects  : NOTHING TO DO. Use Cairn in the folder once; it self-registers.
  uninstall     : launchctl unload $PLIST && rm ~/.claude/CLAUDE.md
═══════════════════════════════════════════════════════════════
EOF
