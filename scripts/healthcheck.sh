#!/usr/bin/env bash
# healthcheck.sh — prove the agent still works. Run it after ANY change to the machinery.
#
# WHY THIS EXISTS — the actual root cause of everything that broke
# Every automation bug we hit (2026-07-13/14) had ONE cause: code was WRITTEN and never
# RUN. The scripts were authored on 07-12 and first executed on 07-14. In those two days
# they were, silently and simultaneously:
#   - pointed at a systemd path that did not exist (~/agent-machinery, not ~/agent/...)
#   - scheduled in UTC, so the "morning" brief would fire at 00:30 Pacific
#   - having their tool allowlist clobbered by .env
#   - returning no stdout, so the caller's coverage check tested an empty string
#   - calling `find`, which the permission policy denies in headless runs
# Not one of these was visible from reading the code. ALL of them were obvious within
# sixty seconds of running it.
#
# This is insights.md #7 as executable code: VERIFY THE ACTUAL OPERATION, NOT A PROXY.
# A green healthcheck is evidence. "I read it and it looks right" is not.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "═══ Cairn healthcheck — $(date '+%F %H:%M %Z') ═══"

echo
echo "1. Config"
[[ -f "$REPO_DIR/.env" ]] && ok ".env present" || bad ".env MISSING — every job will die"
for V in CONTEXT_DIR NTFY_URL NTFY_TOPIC; do
  # shellcheck disable=SC1091
  ( set +u; source "$REPO_DIR/.env" 2>/dev/null; [[ -n "${!V:-}" ]] ) \
    && ok "$V set" || bad "$V NOT set in .env"
done
( set +u; source "$REPO_DIR/.env" 2>/dev/null; [[ -n "${GITHUB_TOKEN:-}" ]] ) \
  && ok "GITHUB_TOKEN set (code access live)" \
  || echo "  ⏳ GITHUB_TOKEN not set — Cairn cannot read your code yet (see T17)"

echo
echo "2. The policy is installed WHERE IT APPLIES"
if grep -q '"Bash"' "$HOME/.claude/settings.json" 2>/dev/null; then
  ok "user-level policy has Bash allowed"
else
  bad "user-level policy missing/stale — RUN scripts/install-permissions.sh"
fi
for LOCAL in "$REPO_DIR/.claude/settings.local.json" "$HOME/.claude/settings.local.json"; do
  if [[ -f "$LOCAL" ]] && grep -q '"allow": \[[^]]' "$LOCAL" 2>/dev/null; then
    bad "$(basename "$LOCAL") HAS DRIFTED again — permissions widened by 'always allow' clicks"
  fi
done
[[ $FAIL -eq 0 ]] && ok "no permission drift"

echo
echo "3. Scheduler"
if crontab -l 2>/dev/null | grep -q morning-brief; then ok "cron: morning brief scheduled"; else bad "cron: morning brief NOT scheduled"; fi
if crontab -l 2>/dev/null | grep -q nightly-journal; then ok "cron: nightly journal scheduled"; else bad "cron: nightly journal NOT scheduled"; fi
crontab -l 2>/dev/null | grep -q 'CRON_TZ=America/Los_Angeles' \
  && ok "CRON_TZ is Pacific (server is UTC — without this the brief fires at 00:30)" \
  || bad "CRON_TZ MISSING — jobs will fire at the wrong hour"
crontab -l 2>/dev/null | grep -q 'npm-global/bin' \
  && ok "cron PATH includes claude" \
  || bad "cron PATH missing claude — jobs fail silently, every day"
if systemctl --user is-enabled agent-morning-brief.timer &>/dev/null; then
  bad "systemd timer ALSO enabled — you will get DOUBLE briefs. Pick one scheduler."
else
  ok "systemd timers disabled (cron is the one scheduler)"
fi

echo
echo "4. Every script exists and is executable"
for S in run-agent.sh morning-brief.sh nightly-journal.sh notify.sh sync-repos.sh; do
  [[ -x "$SCRIPT_DIR/$S" ]] && ok "$S" || bad "$S missing or not executable"
done

echo
echo "5. The scripts cron will actually invoke exist at those exact paths"
while read -r P; do
  [[ -x "$P" ]] && ok "cron target exists: $(basename "$P")" || bad "CRON POINTS AT A NONEXISTENT PATH: $P"
done < <(crontab -l 2>/dev/null | grep -oE '/home/[^ ]*\.sh' | sort -u)

echo
echo "6. Live end-to-end: can a HEADLESS run actually reach Gmail?"
GRES=$(cd "$HOME/agent" && timeout 120 claude -p \
  "Search Gmail newer_than:1d. Reply with ONLY the number of threads, or the single word UNREACHABLE." \
  --allowedTools "mcp__claude_ai_Gmail__search_threads" --max-turns 4 2>/dev/null | tail -1)
if [[ "$GRES" =~ [0-9] ]]; then
  ok "headless Gmail OK ($GRES) — the brief can see your mail"
else
  bad "HEADLESS GMAIL UNREACHABLE — the morning brief would be blind. Got: '$GRES'"
fi

echo
echo "7. Notification channel"
if "$SCRIPT_DIR/notify.sh" "🩺 healthcheck" "Cairn healthcheck ran at $(date '+%H:%M %Z')." >/dev/null 2>&1; then
  ok "ntfy push accepted (check the phone — accepted != delivered)"
else
  bad "ntfy push FAILED — the brief has no way to reach you"
fi

echo
echo "═══════════════════════════════════════════"
echo "  PASS: $PASS    FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && echo "  ✅ Cairn is healthy." || echo "  ❌ $FAIL problem(s). Fix before trusting the automation."
echo "═══════════════════════════════════════════"
exit $(( FAIL > 0 ? 1 : 0 ))
