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

# WHICH FILES: exactly what a push could publish. In a git work tree that's the tracked files
# plus untracked files that aren't gitignored (= what `git add -A` picks up). A gitignored file
# (.env, local-only/) can never leave the box, so it isn't checked: flagging .env's own
# addresses made this gate cry wolf every night from 2026-09-21 to 2026-10-11, the exact
# failure mode described above. If .env ever stops being ignored, it lands in this list and
# gets flagged. Outside a git repo, every file is checked.
publishable() {
  if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$TARGET" ls-files --cached --others --exclude-standard -z \
      | while IFS= read -r -d '' rel; do printf '%s\n' "$TARGET/$rel"; done
  else
    find "$TARGET" -type f -not -path '*/.git/*' 2>/dev/null
  fi | grep -vE '/(deprecated|node_modules)/|/example\.env$|\.bak[^/]*$|/pii-scan\.sh$'
}

while IFS= read -r f; do
  [[ -f "$f" ]] || continue   # tracked but deleted in the work tree

  # Secrets: a credentials-looking FILE, or a token in a known high-precision format. The
  # identifier checks below don't catch keys; an untracked ".env.save" (2026-10-11) showed a
  # copy of the secrets file could otherwise slip through. Only a token's first 12 characters
  # are printed, because these hits go into the backup log and a phone notification.
  case "${f##*/}" in
    .env|.env.*|*.pem|*.key|*.p12|*.pfx|id_rsa*|id_ed25519*|id_ecdsa*)
      HITS+="$f: secrets-like file would be published"$'\n' ;;
  esac
  while IFS= read -r tok; do
    HITS+="$f: possible secret token → ${tok:0:12}…"$'\n'
  done < <(grep -oIE 'ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{40,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----' "$f" 2>/dev/null | sort -u)

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
done < <(publishable)

if [[ -n "$HITS" ]]; then
  printf '%s' "$HITS" | sort -u
  exit 1
fi
exit 0
