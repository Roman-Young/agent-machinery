#!/usr/bin/env bash
# seat-notify.sh — the phone ping for the TERMINAL SEAT ("Kairo finished" / "Kairo needs
# you"), i.e. the one push feature a phone app gives you that a terminal doesn't.
#
# Wired as a Claude Code hook on two events (see docs/terminal-seat.md for the exact
# settings.json snippet):
#   Stop          → the turn finished            → fyi tier
#   Notification  → waiting on a permission/input → alert tier
# Hook input arrives as JSON on stdin. This script ALWAYS exits 0 fast: a hook that errors
# or blocks would degrade the session it's meant to serve.
#
# WHEN IT FIRES — only when all three hold:
#   1. KAIRO_SEAT=1 — set by kairo-term.sh for processes inside the seat. Headless
#      `claude -p` jobs and phone-app sessions never have it, so they can't trigger this
#      even though the hook is configured globally.
#   2. You're AWAY: no client has touched the seat for KAIRO_AWAY_SECS (default 90).
#      "Attached" is not enough — a phone on mosh stays attached in your pocket.
#   3. Not a duplicate: at most one push per window per KAIRO_NOTIFY_DEBOUNCE secs.
#
# DATA MINIMISATION: the push carries the event kind and the window name ONLY — never the
# model's text or the permission prompt's contents. ntfy is a third-party relay; what the
# agent was doing stays on the server.
set -uo pipefail

[[ "${KAIRO_SEAT:-}" == 1 ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${KAIRO_NOTIFY_CMD:-$(dirname "$SCRIPT_DIR")/notify.sh}"   # override = test seam
SOCK="${KAIRO_TMUX_SOCKET:-kairo}"
SESSION="${KAIRO_SEAT_SESSION:-kairo}"
AWAY_SECS="${KAIRO_AWAY_SECS:-90}"
DEBOUNCE="${KAIRO_NOTIFY_DEBOUNCE:-45}"

INPUT="$(timeout 2 cat 2>/dev/null || true)"
EVENT="$(python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read() or "{}").get("hook_event_name",""))
except Exception: print("")' <<<"$INPUT" 2>/dev/null)"
[[ -n "$EVENT" ]] || EVENT="${1:-Stop}"

# ── Away? Newest client activity across everything attached to the seat. ──────────
now="$(date +%s)"
last="$(tmux -L "$SOCK" list-clients -t "$SESSION" -F '#{client_activity}' 2>/dev/null | sort -n | tail -1)"
if [[ -n "$last" ]] && (( now - last < AWAY_SECS )); then
  exit 0   # you're looking at it
fi

# ── Which chat? (TMUX_PANE is inherited from the pane the harness runs in.) ────────
window="$(tmux -L "$SOCK" display-message -p -t "${TMUX_PANE:-}" '#W' 2>/dev/null || true)"
window="${window:-seat}"

# ── Debounce per window ────────────────────────────────────────────────────────────
stamp="${XDG_RUNTIME_DIR:-/tmp}/kairo-seat-notify.$(id -u).${window//[^A-Za-z0-9_-]/_}"
if [[ -f "$stamp" ]] && (( now - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) < DEBOUNCE )); then
  exit 0
fi
touch "$stamp" 2>/dev/null || true

case "$EVENT" in
  Notification) tier=alert; title="Kairo needs you"; body="[$window] is waiting on a permission or your input." ;;
  Stop)         tier=fyi;   title="Kairo finished";  body="[$window] finished its turn." ;;
  *)            exit 0 ;;
esac

# Detached + time-boxed: the hook returns immediately whatever ntfy does.
( timeout 20 "$NOTIFY" "$tier" "$title" "$body" >/dev/null 2>&1 & ) 2>/dev/null
exit 0
