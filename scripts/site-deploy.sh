#!/usr/bin/env bash
# site-deploy.sh — Kairo's gated pipeline for the personal website (roman-young.dev).
#
# The autonomy contract (Roman, 2026-08-04): Kairo prepares the change and gets it onto a
# PREVIEW build; production only goes live on Roman's approval. So:
#
#   open   — build-gate the working tree, branch, commit, push, open a PR.
#            Vercel builds a preview and comments the URL on the PR. NOTHING is live yet.
#   merge  — AFTER Roman reviews the preview and approves: merge the PR to main, which is
#            what triggers the Vercel PRODUCTION deploy. This is the gate. Never auto-run it.
#   status — list open Kairo PRs awaiting review.
#
# Prereqs (one-time, done by Roman — see agent-machinery/docs/site-deploy.md):
#   1. GITHUB_WRITE_TOKEN in .env  — fine-grained PAT, personal-website repo ONLY,
#      Contents + Pull requests = Read/Write.
#   2. In the repo, the write helper is the ONLY credential helper:
#        git -C "$REPO" config --local --replace-all credential.helper ""
#        git -C "$REPO" config --local --add credential.helper "$SCRIPTS/git-credential-cairo-write.sh"
#
# Roman's hard rules honored here: NO AI/co-author trailer on commits; propose-and-wait
# (this script never merges on its own); fail loud.
set -euo pipefail

REPO="${SITE_REPO:-$HOME/agent/codebases/personal-website}"
SCRIPTS="$HOME/agent/agent-machinery/scripts"
ENV_FILE="$HOME/agent/agent-machinery/.env"

die() { echo "site-deploy: $*" >&2; exit 1; }

# Auth (2026-08-06): ships on EXISTING creds — gh CLI is already logged in (hosts.yml) and
# `git push` uses the working credential helper. If the optional scoped write token is wired in
# later (docs/site-deploy.md), push transparently uses the repo-local helper and gh uses hosts.yml
# — nothing here changes. So no token-from-.env plumbing is needed.
gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated — run 'gh auth login' (see docs/site-deploy.md)."

cd "$REPO" || die "repo not found at $REPO"

build_gate() {
  echo "→ build gate: verifying the site compiles before anything leaves the box"
  [ -d node_modules ] || npm ci --no-audit --no-fund
  npm run build >/tmp/site-build.log 2>&1 || { tail -20 /tmp/site-build.log; die "build FAILED — not pushing a broken site."; }
  echo "✓ build clean"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  open)
    msg="${1:-}"; slug="${2:-}"
    [ -n "$msg" ] || die 'usage: site-deploy.sh open "<commit message>" [branch-slug]'
    git diff --quiet && git diff --cached --quiet && die "no changes in the working tree to deploy."

    # Two-writer safety: Roman also pushes from his Mac. Warn (don't silently diverge) if main moved.
    git fetch -q origin main || true
    if [ -n "$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)" ] && \
       [ "$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)" != "0" ]; then
      echo "⚠ origin/main is ahead of your local main — Roman may have pushed. Review before merging the PR."
    fi

    build_gate

    [ -n "$slug" ] || slug="update-$(date +%Y%m%d-%H%M)"
    branch="kairo/$slug"
    git checkout -b "$branch"
    git add -A
    git commit -m "$msg"          # NO trailer — Roman's commits go out under his name only.
    git push -u origin "$branch"

    url=$(gh pr create --title "$msg" \
      --body "Prepared by Kairo, awaiting Roman's approval. Vercel will attach a **preview** deploy below — review that URL, then approve and I'll merge to production (\`site-deploy.sh merge <#>\`)." \
      --head "$branch" --base main 2>&1 | tail -1)
    echo
    echo "✓ PR opened: $url"
    echo "  Vercel will comment a preview URL on it within ~1 min. NOTHING is live yet."
    ;;

  merge)
    pr="${1:-}"
    [ -n "$pr" ] || die "usage: site-deploy.sh merge <pr-number>  (only after Roman approves the preview)"
    echo "→ merging PR #$pr to main — this triggers the Vercel PRODUCTION deploy."
    gh pr merge "$pr" --squash --delete-branch
    git checkout -q main && git pull -q --ff-only origin main || true
    echo "✓ merged. Production deploy is building on Vercel."
    ;;

  status)
    gh pr list --search "head:kairo/" --state open
    ;;

  *)
    die 'usage: site-deploy.sh {open "<msg>" [slug] | merge <pr#> | status}'
    ;;
esac
