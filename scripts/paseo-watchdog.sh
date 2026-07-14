#!/usr/bin/env bash
# paseo-watchdog.sh — keep the phone channel alive. THIS IS THE ANSWER TO
# "a reboot would lose Paseo — how am I supposed to fix things like that?"
#
# ══════════════════════════════════════════════════════════════════════════════
# THE PROBLEM
# Paseo's daemon was started BY HAND. It has no systemd unit and no cron entry, and its
# supervisor is orphaned (PPID 1) with its argv rewritten — so the original command that
# launched it is unrecoverable. A reboot kills it and it never comes back. Roman would
# lose his phone channel to Cairn, and the only way back in would be SSH — the exact thing
# this system exists to avoid.
#
# THE DESIGN PRINCIPLE (this is the part that generalizes)
# I do not know Paseo's canonical start command with certainty. So instead of guessing and
# hoping, this script is built to be CORRECT EVEN WHEN ITS GUESS IS WRONG:
#
#   1. IT NEVER TOUCHES A LIVE DAEMON. If the daemon is already up, it exits immediately.
#      That makes it impossible for the watchdog to cause the outage it exists to prevent.
#      (It is also why this was safe to write and test while Roman was mid-session.)
#   2. IF THE DAEMON IS DOWN, it tries to start it.
#   3. EITHER WAY IT TELLS HIM. Success -> a push. Failure -> a LOUD push with the exact
#      command to run. He is never silently stranded, wondering why his phone went quiet.
#
# A system you cannot fully verify should still FAIL LOUDLY AND RECOVERABLY.
# That is worth more than a confident guess.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

daemon_up() { pgrep -f 'Paseo Daemon' >/dev/null 2>&1; }

# ── 1. Already healthy? Do absolutely nothing. ────────────────────────────────
if daemon_up; then
  [[ "${1:-}" == "--verbose" ]] && echo "paseo: up (pid $(pgrep -f 'Paseo Daemon' | head -1))"
  exit 0
fi

# ── 2. It's down. At boot, give the network a moment first. ───────────────────
echo "$(date -Is) paseo: DOWN — attempting restart"
if [[ "${1:-}" == "--boot" ]]; then
  for _ in $(seq 1 15); do ping -c1 -W1 1.1.1.1 &>/dev/null && break; sleep 2; done
fi

# ── 3. Try to bring it back. Any paseo invocation should spawn the daemon; `status`
#       is the most conservative one that does. Timeout so a hang can't wedge cron.
export PATH="$PATH:$HOME/.npm-global/bin"
timeout 60 paseo status >/dev/null 2>&1 || true
sleep 6

# ── 4. Report honestly. This is the part that makes the whole thing safe. ─────
if daemon_up; then
  echo "$(date -Is) paseo: restarted OK"
  "$SCRIPT_DIR/notify.sh" "✅ Paseo is back" \
    "The server rebooted or Paseo crashed, and the watchdog restarted it. Your phone channel to Cairn is live again." \
    >/dev/null 2>&1 || true
else
  echo "$(date -Is) paseo: RESTART FAILED"
  "$SCRIPT_DIR/notify.sh" "🔴 PASEO IS DOWN — action needed" \
"The watchdog could not restart Paseo, so your phone channel to Cairn is dead.

SSH in to the server and run:
  paseo

Then tell Cairn the command that worked, so the watchdog can be corrected. Everything
else (morning brief, nightly journal, email) is unaffected — those run on cron." \
    >/dev/null 2>&1 || true
  exit 1
fi
