#!/usr/bin/env bash
# pii-scan.sh — is this repo safe to publish? Prints offending files; silent if clean.
# Usage: pii-scan.sh <dir>   → exit 0 = clean, 1 = PII found
#
# ══════════════════════════════════════════════════════════════════════════════
# WHY: agent-machinery is a PUBLIC repo. Its own CLAUDE.md says "never hardcode paths or
# personal facts." By 2026-07-14 it had quietly accumulated, across 11 unpushed commits:
#   - the server's public IP and login  (roman@x.x.x.x)  → an invitation to brute-force
#   - all five of the owner's email addresses
#   - FIVE COLLEAGUES' work emails      → not his privacy to spend. Doxxing, effectively.
# Caught with one command to spare. Git history is forever; a force-push after the fact
# does not un-ring that bell.
#
# So a machine now checks, every night, before anything leaves the box.
#
# PRECISION MATTERS MORE THAN RECALL HERE. A scanner that cries wolf gets disabled, and a
# disabled scanner protects nothing. The v1 version flagged `1.1.1.1` (Cloudflare DNS) and
# `git@github.com` (an SSH URL) — so it had to learn what a real identifier looks like.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
TARGET="${1:?usage: pii-scan.sh <dir>}"

# Not personal identifiers, and they legitimately appear in infrastructure code.
#   loopback / private / well-known public DNS, plus the RFC 5737 documentation ranges
#   (192.0.2.x, 198.51.100.x, 203.0.113.x) which exist SPECIFICALLY to be used as examples.
ALLOW_IP='^(0\.0\.0\.0|127\.|1\.1\.1\.1|8\.8\.8\.8|255\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)'
ALLOW_EMAIL='(git@github\.com|noreply@|no-reply@|example\.(com|org)|user@example|you@|your-|someone@)'

HITS=""

while IFS= read -r f; do
  # Public IPv4 that isn't loopback/private/well-known-DNS, and isn't a version string.
  while IFS= read -r ip; do
    [[ "$ip" =~ $ALLOW_IP ]] && continue
    HITS+="$f: possible server IP → $ip"$'\n'
  done < <(grep -oIE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$f" 2>/dev/null | sort -u)

  # Real-looking email addresses.
  while IFS= read -r em; do
    [[ "$em" =~ $ALLOW_EMAIL ]] && continue
    HITS+="$f: possible email → $em"$'\n'
  done < <(grep -oIE '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b' "$f" 2>/dev/null | sort -u)

  # user@host SSH targets (the server IP was hiding in one of these).
  while IFS= read -r sh; do
    [[ "$sh" =~ (git@github|user@|you@|\$\{|\$SERVER) ]] && continue
    HITS+="$f: possible ssh target → $sh"$'\n'
  done < <(grep -oIE 'ssh[a-z-]* [a-z][a-z0-9_-]+@[a-zA-Z0-9.-]+' "$f" 2>/dev/null | sort -u)
done < <(
  find "$TARGET" -type f \
    -not -path '*/.git/*' -not -path '*/deprecated/*' -not -path '*/node_modules/*' \
    -not -name 'example.env' -not -name '*.bak*' -not -name 'pii-scan.sh' 2>/dev/null
)

if [[ -n "$HITS" ]]; then
  printf '%s' "$HITS" | sort -u
  exit 1
fi
exit 0
