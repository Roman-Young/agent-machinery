#!/usr/bin/env bash
# git-credential-cairo: supply the GitHub PAT from .env over HTTPS. Token lives only in .env.
[ "$1" = "get" ] || exit 0
TOKEN=$(grep '^GITHUB_TOKEN=' "$HOME/agent/agent-machinery/.env" 2>/dev/null | cut -d= -f2-)
[ -n "$TOKEN" ] || exit 0
echo "username=x-access-token"
echo "password=$TOKEN"
