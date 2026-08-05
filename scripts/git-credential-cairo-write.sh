#!/usr/bin/env bash
# git-credential-cairo-write: supply the WRITE-scoped GitHub PAT from .env over HTTPS.
#
# Kept SEPARATE from git-credential-cairo.sh on purpose. The default helper hands out
# GITHUB_TOKEN (read-only, broad). This one hands out GITHUB_WRITE_TOKEN, which must be a
# fine-grained PAT scoped to the personal-website repo ONLY (Contents + Pull requests: RW).
# It is wired in as a LOCAL credential helper in that repo alone, so no other repo — and no
# prompt-injection path in Kairo's shell — can push anywhere but that one public site.
[ "$1" = "get" ] || exit 0
TOKEN=$(grep '^GITHUB_WRITE_TOKEN=' "$HOME/agent/agent-machinery/.env" 2>/dev/null | cut -d= -f2-)
[ -n "$TOKEN" ] || exit 0
echo "username=x-access-token"
echo "password=$TOKEN"
