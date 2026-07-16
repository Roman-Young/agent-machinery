#!/usr/bin/env bash
# authorize-phone-key.sh — RUN THIS ONCE, on the server, to let your phone send voice
# prompts over SSH — and NOTHING else.
#
# Usage:  ./authorize-phone-key.sh 'ssh-ed25519 AAAA...the-public-key... phone'
#
# Roman runs this (not Cairo) because Cairo is deliberately denied access to ~/.ssh.
# It locks the phone's key to a FORCED COMMAND: that key can only ever run voice-prompt.sh.
# It cannot get a shell, run other commands, forward ports, or open a terminal — so exposing
# it on the phone is safe. If the phone is lost, delete the line and the access is gone.
set -euo pipefail

KEY="${1:?Paste the PUBLIC key your iOS shortcut generated, in single quotes.}"
VOICE="/home/roman/agent/agent-machinery/scripts/voice-prompt.sh"
AUTH="$HOME/.ssh/authorized_keys"

[[ -x "$VOICE" ]] || { echo "voice-prompt.sh not found/executable at $VOICE"; exit 1; }

# Accept only a real public key line; ignore anything else pasted around it.
KEYBODY=$(printf '%s' "$KEY" | grep -oE '(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+) [A-Za-z0-9+/=]+([[:space:]][^[:space:]]+)?' | head -1)
[[ -n "$KEYBODY" ]] || { echo "❌ That doesn't look like an SSH public key (should start with ssh-ed25519 or ssh-rsa)."; exit 1; }

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$AUTH"; chmod 600 "$AUTH"

if grep -qF "$KEYBODY" "$AUTH" 2>/dev/null; then
  echo "✅ That key is already authorized — nothing to do."
  exit 0
fi

# The forced command + restrictions. THIS is the security boundary.
printf 'command="%s",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty %s\n' \
  "$VOICE" "$KEYBODY" >> "$AUTH"

echo "✅ Phone key authorized for VOICE PROMPTS ONLY (forced command, no shell)."
echo "   To revoke later: edit ~/.ssh/authorized_keys and delete the line ending in the key's comment."
