#!/usr/bin/env bash
# install-timers.sh — systemd timers. ⚠️ ALMOST CERTAINLY NOT WHAT YOU WANT.
#
# THE LIVE SCHEDULER IS CRON. See `crontab -l`.
#
# systemd USER timers only run while the user has an active login session, unless
# `loginctl enable-linger` is set — which needs sudo. Cron needs neither. That is why
# cron won.
#
# This script exists only for the case where sudo is recovered AND someone wants
# systemd's one real advantage (Persistent=true catches up a run missed while the server
# was powered OFF — which, for an always-on box, is worth approximately nothing).
#
# 🔴 IT NOW REFUSES TO RUN IF CRON IS ALREADY SCHEDULED. Two schedulers means every job
#    fires TWICE a day — double the API spend, duplicate log entries, and a nightly
#    journal racing itself to write the same file. This guard exists because the old
#    version had no such check and systemd/README.md actively told you to run it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if crontab -l 2>/dev/null | grep -qE 'morning-brief|nightly-journal'; then
  cat >&2 <<'MSG'
🔴 REFUSING TO INSTALL — cron is already running these jobs.

Running both schedulers means EVERY JOB FIRES TWICE A DAY. If you genuinely want to
switch from cron to systemd, remove the cron jobs FIRST:

    crontab -e        # delete the morning-brief and nightly-journal lines
    ./scripts/install-timers.sh

There is exactly one scheduler. Ever.
MSG
  exit 1
fi

mkdir -p "$HOME/.config/systemd/user"
cp "$REPO_DIR"/systemd/*.service "$REPO_DIR"/systemd/*.timer "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
for t in agent-morning-brief agent-nightly-journal; do
  systemctl --user enable --now "$t.timer"
done

if ! loginctl show-user "$USER" -p Linger --value 2>/dev/null | grep -q yes; then
  echo
  echo "⚠️  LINGER IS NOT ENABLED. These timers will ONLY run while you are logged in —"
  echo "    i.e. they will silently never fire. Run:  sudo loginctl enable-linger $USER"
fi
systemctl --user list-timers
