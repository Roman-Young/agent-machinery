#!/usr/bin/env bash
# backup-context.sh — commits & pushes the context repo (offsite copy on
# GitHub) and snapshots local-only/ (which git ignores) to a tarball.
# Part of the 3-2-1 discipline: pull these tarballs to a home machine too.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/.env"

cd "$CONTEXT_DIR"
git add -A
git diff --cached --quiet || git commit -m "auto: context snapshot $(date -Is)"
git push origin main

BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
mkdir -p "$BACKUP_DIR"
tar czf "$BACKUP_DIR/local-only-$(date +%F).tar.gz" -C "$CONTEXT_DIR" local-only
# Keep the last 14 snapshots
ls -1t "$BACKUP_DIR"/local-only-*.tar.gz | tail -n +15 | xargs -r rm --
