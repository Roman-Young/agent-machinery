#!/usr/bin/env bash
# canvas-login.sh — the ~2-minute re-auth helper. UCSD Duo "remember this device" lasts ~7 days, so
# the Canvas session periodically lapses; canvas-sync detects it and pings Roman to run THIS. It only
# ensures the browser is up and prints the exact tunnel command + login checklist — nothing is
# automated (2FA is the whole point). SERVER_IP comes from .env so this file (public repo) holds no IP.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
[[ -f "$REPO_DIR/.env" ]] && { set +u; source "$REPO_DIR/.env"; set -u; }
PORT="${KAIRO_CDP_PORT:-9333}"
# IP is read at runtime from the gitignored server.md (never hardcoded in this public-repo file, and
# never in .env — the PII gate scans .env). SERVER_IP env overrides if set.
IP="${SERVER_IP:-$(grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' "${CONTEXT_DIR:-$HOME/agent/my-context}/local-only/server.md" 2>/dev/null | head -1)}"
IP="${IP:-<your server IP — see my-context/local-only/server.md>}"

"$SCRIPT_DIR/canvas-chrome.sh" || true

cat <<EOF

═════════════════ Canvas re-login (~2 min) ═════════════════
The headless Chrome that holds your Canvas session is running on the server.
To (re)authenticate:

  1. On your MAC, open a Terminal and run the tunnel (leave the window open):
       ssh -L ${PORT}:127.0.0.1:${PORT} roman@${IP}

  2. In your Mac's Google Chrome address bar:  chrome://inspect
       * Configure... -> add  127.0.0.1:${PORT}  -> Done  (tick "Discover network targets")
       * Under "Remote Target", click  inspect fallback  on the canvas.ucsd.edu page.

  3. Log in -> approve the Duo push on your phone -> tick "remember this device".
       (If it dead-ends on the Two-Step *help* page, the browser UA reset to headless —
        re-run  ${SCRIPT_DIR}/canvas-chrome.sh  (it sets the spoofed UA), then retry.)

  4. When you see your Canvas dashboard, you're done. Confirm from the server:
       ${SCRIPT_DIR}/canvas-sync.sh
═══════════════════════════════════════════════════════════
EOF
