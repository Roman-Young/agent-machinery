#!/usr/bin/env bash
# backup-context.sh — the offsite copy. RUN NIGHTLY.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHY THIS WAS REWRITTEN (2026-07-14)
#
# The old version had never run. Not once. There was no ~/backups directory, no cron
# entry, no timer. Meanwhile 25 commits — the entire memory layer, the insights, the task
# system, every script — sat on ONE Hetzner box with a 2-day-stale copy on GitHub.
#
# The system built so that nothing gets lost was itself unbacked. If that server had died,
# all of it was gone.
#
# It also would have FAILED if anyone had run it: `git push` is permission-gated ("ask"),
# and in a headless run "ask" means DENIED. It would have exited non-zero on the first push
# with `set -e` and never reached the tarball.
#
# THREE THINGS ARE BACKED UP, and they need three different mechanisms:
#   1. my-context  -> git push (private repo = the offsite copy)
#   2. agent-machinery -> git push, BUT it is PUBLIC. See the PII gate below.
#   3. local-only/ -> gitignored ON PURPOSE, so git can never save it.
#                     It needs a tarball, or it exists in exactly one place on earth.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$REPO_DIR/.env"

# Both notify() calls in this script are failures (PII gate tripped / push failed) —
# always alert-tier, never fyi. If a routine success push is ever added here, call
# notify.sh directly with "fyi" instead of adding a tier param to this helper.
notify() { "$SCRIPT_DIR/notify.sh" alert "$1" "$2" >/dev/null 2>&1 || true; }
FAILED=0

# ── 1. THE PII GATE — this runs BEFORE any push to the public repo ────────────
# agent-machinery is PUBLIC. Its own CLAUDE.md says: never hardcode paths or personal
# facts. But on 2026-07-14 an audit found 11 unpushed commits containing the server's
# public IP, all five of the owner's email addresses, and FIVE COLLEAGUES' work emails.
# Publishing a colleague's address is not your privacy to spend, and git history is
# forever. It was caught with one command to spare.
#
# So: a machine checks, every night, before anything leaves this box.
PII_HITS=$("$SCRIPT_DIR/pii-scan.sh" "$REPO_DIR" 2>/dev/null || true)

if [[ -n "$PII_HITS" ]]; then
  echo "🔴 REFUSING TO PUSH agent-machinery — possible PII detected in a PUBLIC repo:"
  echo "$PII_HITS" | sed 's|^|    |'
  notify "🔴 BACKUP BLOCKED — PII in public repo" \
"backup-context.sh refused to push agent-machinery: it found what look like email addresses
or IPs in a PUBLIC repo.

$(echo "$PII_HITS" | head -5)

Scrub them, or add a legitimate exception. NOTHING was pushed to the public repo.
(my-context, which is private, was still backed up.)"
  MACHINERY_BLOCKED=1
else
  MACHINERY_BLOCKED=0
fi

# ── 2. my-context (PRIVATE) — commit + push. This is the memory. ──────────────
cd "$CONTEXT_DIR"
git add -A
if ! git diff --cached --quiet; then
  git commit -q -m "auto: context snapshot $(date -Is)"
  echo "committed context changes"
fi
if git push -q origin "$(git rev-parse --abbrev-ref HEAD)" 2>/dev/null; then
  echo "✅ my-context pushed"
else
  echo "🔴 my-context push FAILED"
  notify "🔴 BACKUP FAILED — my-context" \
    "Could not push the context repo. Your memory has NO current offsite copy. Check the deploy key."
  FAILED=1
fi

# ── 3. agent-machinery (PUBLIC) — only if the PII gate passed ─────────────────
if [[ $MACHINERY_BLOCKED -eq 0 ]]; then
  cd "$REPO_DIR"
  git add -A
  git diff --cached --quiet || git commit -q -m "auto: machinery snapshot $(date -Is)"
  if git push -q origin "$(git rev-parse --abbrev-ref HEAD)" 2>/dev/null; then
    echo "✅ agent-machinery pushed"
  else
    echo "⚠️  agent-machinery push failed"
    FAILED=1
  fi
fi

# ── 4. local-only/ — git CANNOT save this. A tarball is its only copy. ────────
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
mkdir -p "$BACKUP_DIR"
if [[ -d "$CONTEXT_DIR/local-only" ]]; then
  tar czf "$BACKUP_DIR/local-only-$(date +%F).tar.gz" -C "$CONTEXT_DIR" local-only 2>/dev/null \
    && echo "✅ local-only snapshot -> $BACKUP_DIR" \
    || { echo "🔴 local-only tarball FAILED"; FAILED=1; }
  # keep 14
  ls -1t "$BACKUP_DIR"/local-only-*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm --
fi

# ⚠️ 3-2-1 IS NOT SATISFIED YET, AND SAYING SO IS THE POINT.
# These tarballs sit on the SAME SERVER as the thing they back up. If the box dies, they
# die with it. That is one copy, not a backup. Until they are pulled to a second machine
# (or a bucket), local-only/ has exactly ONE home on earth. Tracked in tasks.md.

[[ $FAILED -eq 0 ]] && echo "backup ok" || exit 1
