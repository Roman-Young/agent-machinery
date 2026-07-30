#!/usr/bin/env bash
# canvas-sync.sh — pull Canvas deadlines into tasks.yaml. Modeled on email-triage.sh, but the core
# is deterministic Python (canvas-fetch.py -> canvas-sync.py), NOT a claude -p job — so it carries
# its OWN guards (flock + timeout + fail-loud) instead of going through run-agent.sh.
#
# Flow:  ensure Chrome up -> canvas-fetch.py (read-only, the only web-toucher) -> canvas-sync.py
#        (deterministic merge into tasks.yaml) -> render-tasks.py. Asserts the coverage line
#        `SOURCES: canvas=ok`; on FAIL/logged_out it pages Roman (a silent fetch failure must never
#        look like "no deadlines"). Untrusted assignment text never reaches an LLM or a shell here.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
[[ -f "$REPO_DIR/.env" ]] && { set +u; source "$REPO_DIR/.env"; set -u; }

LOG_DIR="${AGENT_LOG_DIR:-$HOME/.agent-logs}"; mkdir -p "$LOG_DIR" "$LOG_DIR/state"
LOG="$LOG_DIR/canvas-sync.log"
CTX="${CONTEXT_DIR:-$REPO_DIR/../my-context}"
UV="${UV_BIN:-$HOME/.local/bin/uv}"
FETCH_OUT="$LOG_DIR/state/canvas-fetch.json"   # last raw fetch (kept for debugging; not committed)
notify() { "$SCRIPT_DIR/notify.sh" alert "$1" "$2" >/dev/null 2>&1 || true; }

# GUARD 1: one instance only
exec 9>"$LOG_DIR/state/canvas-sync.lock"
if ! flock -n 9; then echo "canvas-sync: a previous run is still going — skipping"; exit 75; fi

echo "[$(date -Is)] canvas-sync starting" >> "$LOG"

# make sure the browser holding the session is up (the watchdog usually keeps it; belt-and-braces)
"$SCRIPT_DIR/canvas-chrome.sh" >> "$LOG" 2>&1 || true

# GUARD 2: timeouts around each stage. canvas-fetch reads the web via CDP; canvas-sync writes YAML.
if ! timeout 150 "$UV" run --with websockets python3 "$SCRIPT_DIR/canvas-fetch.py" > "$FETCH_OUT" 2>> "$LOG"; then
  echo "SOURCES: canvas=FAIL (fetch_timeout_or_error)"
  notify "⚠️ Canvas sync failed" "canvas-fetch timed out or errored. Check $LOG"
  exit 1
fi

OUT="$(timeout 90 "$UV" run --with 'ruamel.yaml' python3 "$SCRIPT_DIR/canvas-sync.py" "$FETCH_OUT" 2>> "$LOG")"
echo "$OUT" | tee -a "$LOG"

# GUARD 3: assert the coverage line; a fetch that broke must page, never look like "no deadlines".
if ! printf '%s\n' "$OUT" | grep -q '^SOURCES: canvas=ok'; then
  if printf '%s\n' "$OUT" | grep -q 'logged_out'; then
    notify "🔐 Canvas session expired" "Re-auth (~2 min): run  agent-machinery/scripts/canvas-login.sh  and complete the Duo login. Deadline sync is paused until then."
  else
    REASON="$(printf '%s\n' "$OUT" | grep -oE 'canvas=FAIL \([^)]*\)' | head -1)"
    notify "⚠️ Canvas sync failed" "${REASON:-unknown}. Check $LOG"
  fi
  exit 1
fi

# re-render the generated view (same call + failure alert as email-triage.sh)
if ! python3 "$SCRIPT_DIR/render-tasks.py" "$CTX/tasks.yaml" >> "$LOG" 2>&1; then
  notify "⚠️ tasks render failed after canvas-sync" "tasks.yaml changed but render-tasks.py failed. Check $LOG"
  exit 1
fi
echo "[$(date -Is)] canvas-sync ok" >> "$LOG"
