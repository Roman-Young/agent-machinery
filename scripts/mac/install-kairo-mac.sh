#!/usr/bin/env bash
# install-kairo-mac.sh — install the `kairo` command on a Mac (run ON THE MAC, once).
#
#   bash install-kairo-mac.sh user@host
#
# Installs:  ~/.local/bin/kairo  and  ~/.local/bin/kairo-compose   (from this folder)
#            tmux via Homebrew if missing (mosh too, if missing — optional but recommended)
#            ~/.config/kairo/server  = user@host
#            a PATH line for ~/.local/bin in ~/.zprofile (zsh, macOS default) if needed
# Re-running it is safe (it just refreshes the two commands).
set -euo pipefail

SERVER="${1:-}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
CONF="$HOME/.config/kairo"

[[ "$(uname -s)" == "Darwin" ]] || { echo "This installer is for macOS."; exit 1; }
[[ -n "$SERVER" && "$SERVER" != -* ]] || { echo "usage: bash install-kairo-mac.sh user@host   (or an ssh alias)"; exit 1; }
command -v python3 >/dev/null || { echo "python3 missing — run: xcode-select --install"; exit 1; }

if ! command -v brew >/dev/null; then
  echo "Homebrew not found. Install it from https://brew.sh, then re-run this."; exit 1
fi
command -v tmux >/dev/null || { echo "Installing tmux…"; brew install tmux; }
command -v mosh >/dev/null || { echo "Installing mosh…"; brew install mosh; }

mkdir -p "$BIN" "$CONF"
install -m 755 "$SRC/kairo" "$BIN/kairo"
install -m 755 "$SRC/kairo-compose" "$BIN/kairo-compose"
printf '%s\n' "$SERVER" > "$CONF/server"

if ! echo ":$PATH:" | grep -q ":$BIN:"; then
  if ! grep -qs '\.local/bin' "$HOME/.zprofile"; then
    printf '\n# kairo\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.zprofile"
  fi
  echo "Added ~/.local/bin to your PATH (new Terminal windows). For this window: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo "Checking the connection to $SERVER…"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$SERVER" 'test -x agent/agent-machinery/scripts/kairo-send.sh' 2>/dev/null; then
  echo "✓ server reachable and the seat tools are there."
else
  echo "⚠ couldn't confirm the server (key login or path). 'kairo' may still work — try it."
fi
echo
echo "Done. Open a new Terminal window and type:  kairo"
