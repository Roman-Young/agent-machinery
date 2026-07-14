#!/usr/bin/env bash
# notify.sh — push a notification to Roman's phone via ntfy.
# Usage: notify.sh <title> <message>
#
# Standalone (not just a function inside run-agent.sh) so any script — and Roman
# himself, from the shell — can push, and so the ntfy config is verified in ONE place.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$REPO_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
fi

TITLE="${1:?usage: notify.sh <title> <message>}"
MESSAGE="${2:?usage: notify.sh <title> <message>}"

if [[ -z "${NTFY_URL:-}" || -z "${NTFY_TOPIC:-}" ]]; then
  echo "ERROR: NTFY_URL / NTFY_TOPIC not set in $REPO_DIR/.env — cannot notify." >&2
  exit 1
fi

# --fail so a non-2xx is an error, not a silent success.
if curl -fsS \
      -H "Title: $TITLE" \
      -H "Markdown: yes" \
      -d "$MESSAGE" \
      "$NTFY_URL/$NTFY_TOPIC" >/dev/null; then
  echo "notified: $TITLE"
else
  echo "ERROR: ntfy push FAILED (curl non-zero). Topic or URL wrong?" >&2
  exit 1
fi
