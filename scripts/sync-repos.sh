#!/usr/bin/env bash
# sync-repos.sh — clone/refresh Roman's GitHub repos so Cairn can READ his actual code.
#
# WHY THIS EXISTS
# Cairn runs on the Hetzner server. Roman's code lives on his Mac. Cairn therefore cannot
# see a single line of the work it is supposed to help with — the "split brain." He does
# NOT want to SSH into the server to code, so the fix is to bring the code to Cairn over
# the internet, never touching the Mac.
#
# SECURITY POSTURE (this is deliberate, do not loosen it)
# The token MUST be a fine-grained, READ-ONLY PAT scoped to selected repos.
# Cairn reads untrusted input (email, web pages) while holding shell access on this box.
# Every credential it holds is a prompt-injection blast radius. Read-only means the worst
# case is disclosure of code Roman already owns — not a force-push to IEDB.
# Same reasoning as the per-repo deploy keys (2026-07-12) and the read-only Hetzner token.
#
# Cairn never sees the token: it lives in .env, this script sources it, and .env is denied
# to Cairn's Read tool.
#
# LIMITATION — SAY THIS OUT LOUD, DO NOT LET IT BE FORGOTTEN
# This gives Cairn the PUSHED state of each repo. It does NOT give it Roman's dirty working
# tree on the Mac. Uncommitted work is invisible here. If he wants review of something he
# hasn't pushed, he must push it (a WIP branch on his own fork is fine).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$REPO_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
else
  echo "ERROR: $REPO_DIR/.env not found." >&2; exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  cat >&2 <<'EOF'
ERROR: GITHUB_TOKEN is not set in .env.

Create a FINE-GRAINED, READ-ONLY token:
  https://github.com/settings/personal-access-tokens/new
  - Repository access : "Only select repositories" -> pick them explicitly
  - Permissions       : Contents=Read-only, Metadata=Read-only,
                        Issues=Read-only, Pull requests=Read-only
  - NOTHING with write access. Ever.

Then add to agent-machinery/.env:
  GITHUB_TOKEN="github_pat_..."
  GITHUB_REPOS="Roman-Young/PEPMatch2.0 IEDB/PEPMatch Roman-Young/LabReach"
EOF
  exit 1
fi

CODE_DIR="${CODEBASES_DIR:-$HOME/agent/codebases}"
mkdir -p "$CODE_DIR"

# Default set; override with GITHUB_REPOS in .env.
REPOS="${GITHUB_REPOS:-Roman-Young/PEPMatch2.0 IEDB/PEPMatch}"

echo "Syncing into $CODE_DIR"
for SLUG in $REPOS; do
  NAME="${SLUG##*/}"
  DEST="$CODE_DIR/$NAME"
  URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${SLUG}.git"

  if [[ -d "$DEST/.git" ]]; then
    echo "  ↻ $SLUG"
    # Refresh the remote each run so a rotated token doesn't leave a stale one on disk.
    git -C "$DEST" remote set-url origin "$URL"
    git -C "$DEST" fetch --all --prune --quiet
    git -C "$DEST" pull --ff-only --quiet 2>/dev/null || echo "    (not fast-forwardable; fetched only)"
  else
    echo "  ⬇ $SLUG"
    git clone --quiet "$URL" "$DEST"
  fi

  # Scrub the token out of .git/config on disk. The URL is rewritten on every run above,
  # so nothing breaks — but a token sitting in a config file is a credential at rest,
  # readable by anything that can read the repo.
  git -C "$DEST" remote set-url origin "https://github.com/${SLUG}.git"

  BRANCH=$(git -C "$DEST" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
  LAST=$(git -C "$DEST" log -1 --format='%h %s' 2>/dev/null | cut -c1-60 || echo '?')
  echo "    $BRANCH — $LAST"
done

echo
echo "Done. Cairn can now READ these repos at $CODE_DIR."
echo "NOTE: this is the PUSHED state only. Uncommitted work on the Mac is NOT here."
