#!/usr/bin/env bash
# sync-repos.sh — keep Roman's WORKSPACE repos in codebases/ current with GitHub, hourly.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHAT THIS IS (REVERSED 2026-07-20 — this used to be the exact opposite; read on).
#
# codebases/ is now Roman's PRIMARY WORKSPACE: he edits these repos in place over VS Code
# Remote SSH, and Cairo edits them in deep-work sessions. This keeps them current with
# GitHub. It pulls with --ff-only, which NEVER clobbers local edits or commits — a repo
# with uncommitted work or a diverged branch is simply skipped. Auth is the global
# credential helper (git-credential-cairo.sh reads the token from .env), so private repos
# pull too; the GITHUB_PRIVATE_REPOS token-in-URL path below is now redundant/dormant.
#
# Until 2026-07-20 this was a READ-ONLY "reference mirror" of a deliberate few repos'
# PUSHED state — because the server had no editor and Roman coded on the Mac. Remote-SSH-
# into-the-server reversed that: the repos ARE the working tree now. (docs/architecture.md
# Rule 5 note; logs/2026-07-19.md.)
#
# TODO — the one un-done piece of the transition: make this SAFE-BUT-LOUD. A genuine
# divergence (local commits + a remote that moved) is currently swallowed silently; it
# should notify. Left silent for now because --ff-only cannot lose data — only staleness,
# never safety.
#
# Still true: never clone the server's OWN repos (agent-machinery, my-context) — a second
# copy is pure drift.
# Auto-discovering all of them (the old behaviour) re-cloned repos the Mac mirror already
# provides, cloned agent-machinery onto its own server, and created "which copy am I
# reading?" confusion. An audit on 2026-07-14 found 4 of 5 auto-discovered clones were
# pure overlap; only the upstream earned its place.
#
# WHAT IT CLONES (in priority order):
#   1. GITHUB_UPSTREAMS      — repos you do NOT own but track (your PRs target them).
#                              Genuinely unavailable anywhere else.
#   2. GITHUB_MIRROR_REPOS   — repos you own where the PUSHED state matters (active PRs).
#   3. GITHUB_PRIVATE_REPOS  — private repos, via a read-only token.
#   4. FALLBACK (nothing configured): just refresh whatever is ALREADY in codebases/.
#      Keeps existing clones current without re-introducing the auto-discovery sprawl,
#      and without hardcoding any repo name into this public template.
#
# NEVER cloned: the server's own repos (agent-machinery, my-context) — they live on this
# box already; a second copy is pure waste and a source of drift.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
[[ -f "$REPO_DIR/.env" ]] && { set +u; source "$REPO_DIR/.env"; set -u; }

CODE_DIR="${CODEBASES_DIR:-$HOME/agent/codebases}"
mkdir -p "$CODE_DIR"

# Repos that live on THIS server already. Never clone a second copy.
SERVER_OWNED="agent-machinery my-context"

is_server_owned() {
  local name="${1##*/}"
  for s in $SERVER_OWNED; do [[ "$name" == "$s" ]] && return 0; done
  return 1
}

clone_or_pull() {  # <slug> <clone-url> <clean-url>
  local slug="$1" url="$2" clean="$3" dest="$CODE_DIR/${1##*/}"
  if is_server_owned "$slug"; then
    echo "  ⊘ ${slug} (lives on this server already — not cloned)"; return
  fi
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" remote set-url origin "$url"
    git -C "$dest" fetch --all --prune --quiet 2>/dev/null
    git -C "$dest" pull --ff-only --quiet 2>/dev/null || true
    printf '  ↻ %-28s' "$slug"
  else
    git clone --quiet "$url" "$dest" 2>/dev/null && printf '  ⬇ %-28s' "$slug" \
      || { echo "  ✗ $slug (clone failed)"; return; }
  fi
  # Never leave a token at rest in .git/config; the URL is rewritten each run anyway.
  git -C "$dest" remote set-url origin "$clean"
  echo "$(git -C "$dest" log -1 --format='%h %s' 2>/dev/null | cut -c1-42)"
}

CONFIGURED=0

# 1 + 2: explicit upstreams and owned-repos-worth-the-pushed-state.
for SLUG in ${GITHUB_UPSTREAMS:-} ${GITHUB_MIRROR_REPOS:-}; do
  CONFIGURED=1
  clone_or_pull "$SLUG" "https://github.com/${SLUG}.git" "https://github.com/${SLUG}.git"
done

# 3: private repos (token, read-only, explicit).
if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_PRIVATE_REPOS:-}" ]]; then
  for SLUG in $GITHUB_PRIVATE_REPOS; do
    CONFIGURED=1
    clone_or_pull "$SLUG" \
      "https://x-access-token:${GITHUB_TOKEN}@github.com/${SLUG}.git" \
      "https://github.com/${SLUG}.git"
  done
fi

# 4: FALLBACK — nothing configured. Refresh what's already here; add nothing new.
if [[ $CONFIGURED -eq 0 ]]; then
  echo "  (no GITHUB_UPSTREAMS / GITHUB_MIRROR_REPOS set — refreshing existing clones only)"
  for dir in "$CODE_DIR"/*/; do
    [[ -d "$dir/.git" ]] || continue
    name=$(basename "$dir")
    is_server_owned "$name" && continue
    git -C "$dir" pull --ff-only --quiet 2>/dev/null || true
    echo "  ↻ $name ($(git -C "$dir" log -1 --format='%h' 2>/dev/null))"
  done
fi

echo "Mirrored to $CODE_DIR  —  PUSHED state only (server-internal, for PR/paper reference)."
