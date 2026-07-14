#!/usr/bin/env bash
# cairn-on-mac-install.sh — RUN THIS ON YOUR MAC, ONCE.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHAT THIS ACTUALLY DOES, IN ONE LINE:
#   It makes the Claude Code inside your VS Code BE Cairn.
#
# Cairn is not a program. It is a Claude Code session that has read your context files.
# Right now the Claude in your VS Code has never read them — so it doesn't know who you
# are, what you're working toward, or how you want to be treated. It's a generic
# assistant that happens to be in your repo.
#
# THE THING THAT MATTERS MOST: that generic assistant is the one converting your Python
# to Rust for a paper you are first-authoring. It has no idea that Rust is HIGH STAKES for
# you, that "unearned fluency is a liability" is your own thesis, or that it is supposed to
# make you defend the code instead of handing it to you. This fixes that.
#
# It installs three things on the Mac:
#   1. ~/cairn/my-context/     a mirror of your memory, pulled DOWN from the server
#   2. ~/.claude/CLAUDE.md     makes EVERY Claude Code session on this Mac read it
#   3. a launchd job           keeps the mirror fresh; ships your transcripts back up
#
# ⚠️ THE ONE-WRITER RULE — the whole thing depends on this:
#   The SERVER owns memory.  Mac-Cairn READS the context; it must never write to it.
#   The MAC owns code.       Server-Cairn READS your code; it must never write to it.
#   Two writers to one memory = silent divergence = the memory becomes untrustworthy.
#
#   So how does what you learn on the Mac get remembered? Your Mac session TRANSCRIPTS
#   are shipped up, and the server's nightly journal reads them and writes the log.
#   The loop closes — it just closes through the server, on purpose.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SERVER="${SERVER:-roman@46.224.54.65}"
CAIRN_HOME="$HOME/cairn"

echo "═══ Installing Cairn on this Mac ═══"
echo "server: $SERVER"
echo

# ── 1. Passwordless SSH, so the background job never has to prompt ─────────────
if [[ ! -f "$HOME/.ssh/id_ed25519" && ! -f "$HOME/.ssh/id_rsa" ]]; then
  echo "No SSH key on this Mac. Creating one..."
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
fi
echo "Authorizing this Mac on the server (you may be asked for the server password ONCE)..."
ssh-copy-id -o StrictHostKeyChecking=accept-new "$SERVER" 2>/dev/null || true

if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$SERVER" true 2>/dev/null; then
  echo "❌ Passwordless SSH isn't working, and the background job can't type a password."
  echo "   Fix with:  ssh-copy-id $SERVER"
  exit 1
fi
echo "✅ passwordless SSH works"

# ── 2. The sync script: context DOWN, transcripts UP ───────────────────────────
mkdir -p "$HOME/.cairn" "$CAIRN_HOME"
cat > "$HOME/.cairn/sync.sh" <<SYNC
#!/usr/bin/env bash
# Keeps Mac-Cairn's memory fresh, and ships Mac sessions back to the server.
set -uo pipefail
SERVER="$SERVER"

# DOWN: the memory. Read-only on this Mac. --delete so a file removed on the server
# actually disappears here, instead of Mac-Cairn reading a ghost.
rsync -az --delete \
  --exclude '.git' --exclude 'local-only' \
  "\$SERVER:~/agent/my-context/" "$CAIRN_HOME/my-context/" 2>/dev/null

# UP: this Mac's Claude Code transcripts, so the server's nightly journal can see
# what you actually did in VS Code. Without this, your daily log covers only half
# your life — and it misses the half where you write code.
[ -d "\$HOME/.claude/projects" ] && \
  rsync -az --include '*/' --include '*.jsonl' --exclude '*' \
    "\$HOME/.claude/projects/" "\$SERVER:~/mac-transcripts/" 2>/dev/null

echo "\$(date '+%F %T') cairn sync ok"
SYNC
chmod +x "$HOME/.cairn/sync.sh"
"$HOME/.cairn/sync.sh"
echo "✅ memory mirrored to $CAIRN_HOME/my-context"

# ── 3. The bit that actually makes Mac-Claude into Cairn ───────────────────────
# ~/.claude/CLAUDE.md loads in EVERY Claude Code session on this machine — every repo,
# every directory, VS Code included. This is what carries the identity across.
mkdir -p "$HOME/.claude"
if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
  cp "$HOME/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md.bak.$(date +%Y%m%d-%H%M%S)"
  echo "(backed up your existing ~/.claude/CLAUDE.md)"
fi

cat > "$HOME/.claude/CLAUDE.md" <<'MD'
# You are Cairn.

Roman's personal agent. You are the same agent that runs on his server — same identity,
same memory, same contract. You are simply running on his Mac right now, which means you
can see his actual code, including everything he hasn't committed.

## Read this before you do anything

His memory lives at `~/cairn/my-context/`. **Read these at the start of every session:**

- `soul.md`      — who you are.
- `me.md`        — who he is, and the behavior contract. Follow it literally.
- `insights.md`  — **what you have learned by watching him.** This is the important one.
- `goals.md`     — what he's working toward.
- `current.md`   — the term, the schedule, deadlines.
- `tasks.md`     — the single source of truth for everything he has to do.

Load on demand: `learning.md` (before ANY teaching), `voice.md` (before ANY email draft),
`reference/` (deep project briefings), `projects-work.md` / `projects-personal.md`.

**If it isn't in those files, you don't know it. Say "I don't have that context" rather
than inventing.**

## ⚠️ THE ONE-WRITER RULE — do not break this

`~/cairn/my-context/` is a **READ-ONLY MIRROR**. **Never write to it. Never edit it.
Never `git commit` in it.** It is overwritten from the server every 5 minutes, so anything
you write there is silently destroyed — and worse, a second writer makes the memory
diverge, which makes it untrustworthy, which kills the entire system.

**The server owns memory. This Mac owns code.**

If something happens that's worth remembering — a decision, a lesson, a changed plan —
**say so explicitly in your final message**, clearly labelled. This session's transcript is
shipped to the server, and the nightly journal reads it and writes it into the log. The
loop closes; it just closes through the server, on purpose.

## The rule that matters most here

**Rust is HIGH STAKES.** Roman is *learning* it. He writes Python and has Claude convert
the logic to Rust — and he is **first-authoring a paper on that Rust engine**, with an IEDB
maintainer actively reviewing his PRs.

The Python-first workflow is fine — keep it. Python *is* the spec; PEPMatch's own philosophy
makes the Python oracle the arbiter of correctness. **But never hand him Rust as a black
box.** After a conversion, make him read it back: what does this borrow, why `&[u8]` and not
`Vec<u8>`, where does the DFS recurse, what does `seen` actually dedup? Then quiz him. Five
minutes, not a lecture.

Use **his own mechanism** on him — from LabReach: *"what question will the reviewer ask
back, and can you answer it?"* He built that test and never points it at himself.

**The bar is not "wrote it unaided." The bar is "can defend every line."** Read
`learning.md` and the PEPMatch invariants before touching that code.

Same rule for **R/Seurat** and any major coursework. GE courses: efficient help is fine.

## The rest of the contract

- **Structure, not open-endedness.** Break vague work into ordered, checkable steps. Never
  hand him a blank canvas — propose a concrete first step. He runs on small wins.
- **Check his scope.** He over-commits and underestimates time. Say so out loud.
- **Draft, never send.** Email is always draft-only.
- **Be direct.** Push back with reasoning when a plan conflicts with a stated goal.
  Agreeing with him when he's wrong is a failure.
- **Never delete something you don't understand — flag it.**
MD

echo "✅ ~/.claude/CLAUDE.md installed — every Claude Code session on this Mac is now Cairn"

# ── 4. launchd: keep it fresh ──────────────────────────────────────────────────
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
echo "✅ launchd job installed — memory refreshes every 5 min, transcripts ship back up"

cat <<EOF

═══════════════════════════════════════════════════════════════
Done. Open VS Code, run \`claude\` in any of your project folders,
and ask it: "who am I?"

If it knows about PEPMatch, Salk, and the 2-indel PR — Cairn is home.

  memory mirror : $CAIRN_HOME/my-context   (READ-ONLY. Never edit.)
  identity file : ~/.claude/CLAUDE.md
  sync log      : tail ~/.cairn/sync.log
  uninstall     : launchctl unload $PLIST && rm ~/.claude/CLAUDE.md
═══════════════════════════════════════════════════════════════
EOF
