#!/usr/bin/env bash
# run-agent.sh — wrapper for headless agent runs.
# Usage: run-agent.sh <job-name> <prompt> [extra claude flags...]
#
# Pattern: source secrets -> run `claude -p` with scoped tools and a
# turn cap -> notify on completion or failure (fail-loud rule).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# The CALLER's job config must win over .env.
#
# BUG FIXED 2026-07-14: .env is sourced below, and if it also defines
# AGENT_ALLOWED_TOOLS / AGENT_MAX_TURNS it silently CLOBBERS what the calling
# script exported. That is how the morning brief ended up running without its
# Gmail tools — it asked for them, .env quietly took them away, every MCP call
# was denied, and the model dutifully reported "0 threads found."
#
# Each job knows its own least-privilege tool set. .env holds secrets, not policy.
_CALLER_TOOLS="${AGENT_ALLOWED_TOOLS:-}"
_CALLER_TURNS="${AGENT_MAX_TURNS:-}"

# Secrets and personal config live in a gitignored .env (see example.env)
if [[ -f "$REPO_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
else
  echo "ERROR: $REPO_DIR/.env not found. Copy example.env to .env and fill it in." >&2
  exit 1
fi

# Restore the caller's intent.
[[ -n "$_CALLER_TOOLS" ]] && AGENT_ALLOWED_TOOLS="$_CALLER_TOOLS"
[[ -n "$_CALLER_TURNS" ]] && AGENT_MAX_TURNS="$_CALLER_TURNS"

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
  # BUG FIXED 2026-07-14: the agent's output went ONLY to the log file, so a
  # caller doing OUT=$(run-agent.sh ...) captured an empty string. The morning
  # brief's coverage check then found no "gmail=ok" in "" and cried DEGRADED on
  # a brief that was actually perfect. Emit on stdout so callers can inspect it.
  echo "$OUTPUT"
  # Jobs that want their output pushed directly (not inspected first):
  if [[ "${PUSH_OUTPUT:-0}" == "1" ]]; then
    notify "$JOB_NAME" "$OUTPUT"
  fi
else
  echo "[$(date -Is)] job=$JOB_NAME FAILED" >> "$LOG_FILE"
  notify "⚠️ $JOB_NAME failed" "Check $LOG_FILE on the server."
  exit 1
fi
