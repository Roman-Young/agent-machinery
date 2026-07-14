#!/usr/bin/env bash
# sync-repos.sh — mirror Roman's GitHub repos to the server so Cairn can READ his code.
#
# PUBLIC repos need NO TOKEN. Public is public — git clone just works. This script
# AUTO-DISCOVERS every public repo he owns (including ones created in the future) from the
# GitHub API and keeps them fresh. Nothing to configure, nothing to rotate, zero risk.
#
# PRIVATE repos need a token, and ONLY those. Set GITHUB_TOKEN + GITHUB_PRIVATE_REPOS.
#
# ⚠️ NEVER use an "All repositories" token. `my-context` is private and holds Roman's
# entire life (GPA, contacts, logs, home address, phone) — and Cairn ALREADY has it on
# disk. An all-repo token grants zero new capability for real disclosure risk, plus every
# future private repo he creates without thinking about it. Use "Only select repositories".
#
# LIMITATION — SAY IT OUT LOUD: this mirrors the PUSHED state. Uncommitted work on the
# Mac is NOT here. For that, see mac-sync-install.sh (rsyncs the live working tree).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

[[ -f "$REPO_DIR/.env" ]] && { set +u; source "$REPO_DIR/.env"; set -u; }

# Derive the GitHub handle from the remote that's already configured, rather than making
# the user maintain it in .env. (I scheduled this hourly BEFORE running it once — it would
# have failed every hour with `GITHUB_USER: set GITHUB_USER in .env`. Schedule nothing you
# have not executed.)
GH_USER="${GITHUB_USER:-$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null \
  | sed -E 's#.*[:/]([^/]+)/[^/]+\.git$#\1#')}"
if [[ -z "$GH_USER" ]]; then
  echo "sync-repos: cannot determine the GitHub user (set GITHUB_USER in .env). Skipping." >&2
  exit 0   # skip cleanly; a scheduled job must not spam failures forever
fi
CODE_DIR="${CODEBASES_DIR:-$HOME/agent/codebases}"
mkdir -p "$CODE_DIR"

clone_or_pull() {  # clone_or_pull <slug> <clone-url> <display-url>
  local slug="$1" url="$2" clean="$3"
  local name="${slug##*/}" dest="$CODE_DIR/${slug##*/}"
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" remote set-url origin "$url"
    git -C "$dest" fetch --all --prune --quiet 2>/dev/null
    git -C "$dest" pull --ff-only --quiet 2>/dev/null || true
    printf '  ↻ %-28s' "$slug"
  else
    git clone --quiet "$url" "$dest" 2>/dev/null && printf '  ⬇ %-28s' "$slug" \
      || { echo "  ✗ $slug (clone failed)"; return; }
  fi
  # Never leave a token sitting in .git/config. The URL is rewritten on every run,
  # so nothing breaks — but a credential at rest is a credential that leaks.
  git -C "$dest" remote set-url origin "$clean"
  echo "$(git -C "$dest" log -1 --format='%h %s' 2>/dev/null | cut -c1-42)"
}

echo "═══ Public repos (auto-discovered, no token, includes anything new) ═══"
PUBLIC=$(curl -sS "https://api.github.com/users/${GH_USER}/repos?per_page=100&type=owner" \
  | python3 -c "import json,sys; [print(r['full_name']) for r in json.load(sys.stdin) if not r['private']]" 2>/dev/null)

if [[ -z "$PUBLIC" ]]; then
  echo "  (GitHub API returned nothing — rate-limited or offline?)"
else
  for SLUG in $PUBLIC; do
    clone_or_pull "$SLUG" "https://github.com/${SLUG}.git" "https://github.com/${SLUG}.git"
  done
fi

# Upstreams Roman doesn't own but must track (his PRs target these).
for SLUG in ${GITHUB_UPSTREAMS:-IEDB/PEPMatch}; do
  clone_or_pull "$SLUG" "https://github.com/${SLUG}.git" "https://github.com/${SLUG}.git"
done

echo
if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_PRIVATE_REPOS:-}" ]]; then
  echo "═══ Private repos (token, read-only, explicitly listed) ═══"
  for SLUG in $GITHUB_PRIVATE_REPOS; do
    clone_or_pull "$SLUG" \
      "https://x-access-token:${GITHUB_TOKEN}@github.com/${SLUG}.git" \
      "https://github.com/${SLUG}.git"
  done
else
  echo "═══ Private repos: none configured ═══"
  echo "  Only needed for LabReach / Rapacon. To enable, add to .env:"
  echo '    GITHUB_TOKEN="github_pat_..."   # fine-grained, READ-ONLY, "Only select repositories"'
  echo '    GITHUB_PRIVATE_REPOS="you/private-repo-one you/private-repo-two"'
fi

echo
echo "Mirrored to $CODE_DIR"
echo "⚠️  PUSHED state only. Uncommitted work on the Mac is NOT here — see mac-sync-install.sh"
