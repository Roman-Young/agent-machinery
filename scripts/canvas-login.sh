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

# Auto-discover the live SSO target tab (canvas.ucsd.edu today; mediaspace.ucsd.edu once Kaltura
# lands — same profile/session, so this works unchanged) and build the exact "inspect fallback"
# DevTools URL chrome://inspect would otherwise make you click through Configure + a target list
# to find. Same loopback port both sides of the tunnel, so the URL is identical pre- or post-tunnel.
TARGET_URL="$(python3 - "$PORT" <<'PYEOF' 2>/dev/null
import json, sys, urllib.request
port = sys.argv[1]
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=3) as r:
        targets = json.load(r)
except Exception:
    sys.exit(0)
for t in targets:
    url = t.get("url", "")
    if "ucsd.edu" in url and t.get("type") == "page":
        print(f"http://127.0.0.1:{port}/devtools/inspector.html?ws=127.0.0.1:{port}/devtools/page/{t['id']}")
        break
PYEOF
)"

cat <<EOF

═════════════════ Canvas re-login (~2 min) ═════════════════
The headless Chrome that holds your Canvas session is running on the server.
To (re)authenticate:

  1. On your MAC, open a Terminal and run the tunnel (leave the window open):
       ssh -L ${PORT}:127.0.0.1:${PORT} roman@${IP}

  2. In your Mac's Google Chrome, open this URL directly (no chrome://inspect, no Configure,
     no hunting for the right target — this IS the target, pre-selected):
EOF

if [[ -n "$TARGET_URL" ]]; then
  echo "       ${TARGET_URL}"
else
  cat <<EOF
       (auto-discovery failed — fall back to manual: chrome://inspect -> Configure ->
        add 127.0.0.1:${PORT} -> Done -> click "inspect fallback" on the ucsd.edu target)
EOF
fi

cat <<EOF

  3. Log in -> approve the Duo push on your phone -> tick "remember this device".
       (If it dead-ends on the Two-Step *help* page, the browser UA reset to headless —
        re-run  ${SCRIPT_DIR}/canvas-chrome.sh  (it sets the spoofed UA), then retry.)

  4. When you see your Canvas dashboard, you're done. Confirm from the server:
       ${SCRIPT_DIR}/canvas-sync.sh
═══════════════════════════════════════════════════════════
EOF
