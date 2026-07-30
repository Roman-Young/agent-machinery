#!/usr/bin/env bash
# canvas-chrome.sh — ensure the persistent, logged-in headless Chrome that holds the Canvas session
# is running. Idempotent: if the debug port already answers, it exits 0 untouched.
#
# ══════════════════════════════════════════════════════════════════════════════
# TWO THINGS HERE ARE LOAD-BEARING (both learned the hard way in the 2026-07-30 spike):
#   1. SPOOFED USER-AGENT. A `--headless` Chrome's default UA contains "HeadlessChrome", which
#      UCSD Duo BLOCKS — the login dead-ends on the two-step help page instead of the push prompt.
#      A normal `Chrome/…` UA is what let Duo render. Do not remove --user-agent.
#   2. LOOPBACK-ONLY DEBUG PORT. --remote-debugging-port binds 127.0.0.1 by default; NEVER pass
#      --remote-debugging-address=0.0.0.0 — an open CDP port is unauthenticated RCE. Reach it only
#      over the SSH tunnel (see canvas-login.sh).
# The one-time SSO+Duo login is a human step (canvas-login.sh); this script only keeps the browser
# alive so the session in the profile can be reused headlessly.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
[[ -f "$REPO_DIR/.env" ]] && { set +u; source "$REPO_DIR/.env"; set -u; }

PROFILE="${KAIRO_CANVAS_PROFILE:-$HOME/.kairo/canvas-profile}"
PORT="${KAIRO_CDP_PORT:-9333}"
BASE="${CANVAS_BASE_URL:-https://canvas.ucsd.edu}"
LOG_DIR="${AGENT_LOG_DIR:-$HOME/.agent-logs}"; mkdir -p "$LOG_DIR"
CHROME="${BH_CHROME_PATH:-google-chrome-stable}"
# A normal (NON-headless) Chrome UA — the real build version; "HeadlessChrome" here is what Duo blocks.
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.7922.71 Safari/537.36"

if curl -sf "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1; then
  echo "canvas-chrome: already up on 127.0.0.1:$PORT"; exit 0
fi

mkdir -p "$PROFILE"
nohup "$CHROME" --headless=new --remote-debugging-port="$PORT" \
  --user-data-dir="$PROFILE" --disable-dev-shm-usage --disable-gpu --no-first-run \
  --no-default-browser-check --disable-blink-features=AutomationControlled \
  --user-agent="$UA" "$BASE/" >>"$LOG_DIR/canvas-chrome.log" 2>&1 &
disown

# poll for readiness (no foreground sleep dependency: retry the port a few times)
for _ in $(seq 1 20); do
  curl -sf "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1 && { echo "canvas-chrome: launched on 127.0.0.1:$PORT"; exit 0; }
  curl -s --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true
done
echo "canvas-chrome: FAILED to come up on 127.0.0.1:$PORT (see $LOG_DIR/canvas-chrome.log)"; exit 1
