#!/usr/bin/env bash
# run-agent.sh — wrapper for headless agent runs.
# Usage: run-agent.sh <job-name> <prompt> [extra claude flags...]
#
# Pattern: source secrets -> run `claude -p` with scoped tools and a
# turn cap -> notify on completion or failure (fail-loud rule).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Secrets and personal config live in a gitignored .env (see example.env)
if [[ -f "$REPO_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
else
  echo "ERROR: $REPO_DIR/.env not found. Copy example.env to .env and fill it in." >&2
  exit 1
fi

JOB_NAME="${1:?usage: run-agent.sh <job-name> <prompt> [flags...]}"
PROMPT="${2:?usage: run-agent.sh <job-name> <prompt> [flags...]}"
shift 2

LOG_DIR="${AGENT_LOG_DIR:-$HOME/.agent-logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%F)-$JOB_NAME.log"

notify() { # notify <title> <message> — no-op if ntfy isn't configured yet
  if [[ -n "${NTFY_URL:-}" && -n "${NTFY_TOPIC:-}" ]]; then
    curl -fsS -H "Title: $1" -d "$2" "$NTFY_URL/$NTFY_TOPIC" >/dev/null || true
  fi
}

cd "$CONTEXT_DIR"  # run from the context repo so CLAUDE.md + files resolve

echo "[$(date -Is)] job=$JOB_NAME starting" >> "$LOG_FILE"

if OUTPUT=$(claude -p "$PROMPT" \
    --allowedTools "${AGENT_ALLOWED_TOOLS:-Read,Glob,Grep}" \
    --max-turns "${AGENT_MAX_TURNS:-25}" \
    "$@" 2>>"$LOG_FILE"); then
  echo "$OUTPUT" >> "$LOG_FILE"
  echo "[$(date -Is)] job=$JOB_NAME ok" >> "$LOG_FILE"
  # Jobs that want their output pushed (e.g. morning brief) pass it along:
  if [[ "${PUSH_OUTPUT:-0}" == "1" ]]; then
    notify "$JOB_NAME" "$OUTPUT"
  fi
else
  echo "[$(date -Is)] job=$JOB_NAME FAILED" >> "$LOG_FILE"
  notify "⚠️ $JOB_NAME failed" "Check $LOG_FILE on the server."
  exit 1
fi
