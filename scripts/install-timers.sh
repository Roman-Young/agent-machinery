#!/usr/bin/env bash
# install-timers.sh — copy, reload, and enable the user-level timers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO_DIR"/systemd/*.service "$REPO_DIR"/systemd/*.timer "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
for t in agent-morning-brief agent-nightly-journal; do
  systemctl --user enable --now "$t.timer"
done
# Timers must run without an active login session:
sudo loginctl enable-linger "$USER"
systemctl --user list-timers
