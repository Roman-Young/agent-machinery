#!/usr/bin/env bash
# healthcheck.sh — prove the agent still works. Run after ANY change; cron runs it weekly.
#
# ══════════════════════════════════════════════════════════════════════════════
# THE FIVE PROPERTIES. This is the framework that came out of the 2026-07-14 audit.
#
# Every failure this system has had came from confusing one of these for another. They are
# NOT the same question, and passing one tells you nothing about the others:
#
#   1. LIVENESS         Does it work RIGHT NOW?
#                       (The v1 healthcheck tested only this. 20/20 green — while Paseo
#                        was one reboot from death and the backup had never run.)
#
#   2. DURABILITY       Will it STILL be working after a reboot / a crash?
#                       Paseo: NO. Hand-started, no supervisor. A reboot would have killed
#                       the phone channel permanently. "It's running" != "it will run."
#
#   3. RECOVERABILITY   Does it survive the SERVER DYING?
#                       25 commits and the whole memory layer sat on one box with a
#                       2-day-stale GitHub copy, and backup-context.sh had NEVER RUN.
#                       The system built so nothing gets lost was itself unbacked.
#
#   4. BOUNDEDNESS      Can it RUN AWAY? (Dan's warning — he was right.)
#                       Zero timeouts, zero locks, zero rate caps. An agent that calls
#                       itself, on a timer, with a card attached, is a machine for burning
#                       money while you sleep.
#
#   5. PUBLISHABILITY   Is it SAFE TO PUSH?
#                       agent-machinery is PUBLIC and had accumulated the server's IP,
#                       five personal emails, and FIVE COLLEAGUES' work addresses.
#                       Caught with one command to spare. Git history is forever.
#
# A green healthcheck is evidence. "I read the code and it looks right" is not — every
# single bug in this system was invisible on read and obvious within 60 seconds of running.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
[[ -f "$REPO_DIR/.env" ]] && { set +u; source "$REPO_DIR/.env"; set -u; }
CTX="${CONTEXT_DIR:-$HOME/agent/my-context}"

PASS=0; FAIL=0; WARN=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN+1)); }
hdr()  { echo; echo "─── $1"; }

echo "═══ Cairn healthcheck — $(date '+%F %H:%M %Z') ═══"

# Hoisted: used by BOTH recoverability (is the 2nd backup copy real?) and durability
# (is the laptop still talking to us?).
# Read the HEARTBEAT, not file mtimes. rsync -a preserves source mtimes, so a file's
# timestamp says when it was last EDITED, not when the Mac last synced — which would make
# this check cry "stale!" whenever Roman simply hadn't touched a file for a few days.
# mac-sync-lib.sh stamps ~/.agent-logs/last-mac-sync with the real sync time each run.
MACLAST=$(cat "$HOME/.agent-logs/last-mac-sync" 2>/dev/null || echo "")

# ── 1. LIVENESS ───────────────────────────────────────────────────────────────
hdr "1. LIVENESS — does it work right now?"

[[ -f "$REPO_DIR/.env" ]] && ok ".env present" || bad ".env MISSING — every job dies"
for V in CONTEXT_DIR NTFY_URL NTFY_TOPIC; do
  [[ -n "${!V:-}" ]] && ok "$V set" || bad "$V not set in .env"
done

crontab -l 2>/dev/null | grep -q morning-brief   && ok "cron: morning brief"   || bad "cron: morning brief NOT scheduled"
crontab -l 2>/dev/null | grep -q nightly-journal && ok "cron: nightly journal" || bad "cron: nightly journal NOT scheduled"
crontab -l 2>/dev/null | grep -q backup-context  && ok "cron: backup"          || bad "cron: BACKUP NOT SCHEDULED"
# ⚠️ DO NOT "CHECK THE TIMEZONE" BY READING THE CRONTAB. That check passed ✅ for a
# full day while the morning brief fired at 00:30 Pacific, because Debian cron SILENTLY
# IGNORES CRON_TZ. Config that looks right is not config that is right.
# VERIFY THE BEHAVIOUR: did the job actually run, and at the right LOCAL time?
crontab -l 2>/dev/null | grep -qE '^[[:space:]]*CRON_TZ[[:space:]]*=' \
  && bad "🔴 CRON_TZ is SET in the crontab — Debian cron IGNORES it. Jobs will fire in UTC." \
  || ok "no CRON_TZ (correct — Debian ignores it; run-local.sh guards local time instead)"
crontab -l 2>/dev/null | grep -q 'run-local.sh' \
  && ok "jobs are local-time guarded (DST-proof, fires at both UTC twins)" \
  || bad "no run-local.sh guard — jobs will fire at the wrong local hour"
crontab -l 2>/dev/null | grep -q 'npm-global/bin' \
  && ok "cron PATH has claude" || bad "cron PATH missing claude — silent daily failure"

# THE REAL TEST: when did the brief LAST ACTUALLY RUN, in local time?
BLOG=$(ls -t "$HOME"/.agent-logs/*-morning-brief.log 2>/dev/null | head -1)
if [[ -n "$BLOG" ]]; then
  # ⚠️ KEEP THE TIMEZONE OFFSET (+00:00). The previous regex stopped at the seconds and
  # dropped it, so `date -d` read a UTC stamp as if it were already local — and this check
  # reported "07:30 local ✅" for a job that actually ran at 00:30 local. THE CHECK BUILT
  # TO CATCH THE TIMEZONE BUG REPRODUCED THE TIMEZONE BUG. Twice-burned; hence the comment.
  LASTRUN=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+\+[0-9:]+' "$BLOG" 2>/dev/null | tail -1)
  if [[ -n "$LASTRUN" ]]; then
    LOCALH=$(TZ="${LOCAL_TZ:-America/Los_Angeles}" date -d "$LASTRUN" +%H:%M 2>/dev/null)
    if [[ "$LOCALH" == "07:3"* ]]; then
      ok "brief last ran at $LOCALH local — the RIGHT hour (verified from the log, not the config)"
    # Distinguish "BROKEN NOW" from "WAS broken, fixed, awaiting proof". A run that
    # predates the fix is EXPECTED to be wrong — flagging it red forever would train
    # Roman to ignore a red healthcheck, and an ignored check protects nothing. (Same
    # principle as pii-scan: a scanner that cries wolf gets disabled.)
    elif [[ $(date -d "$LASTRUN" +%s) -lt $(stat -c %Y "$SCRIPT_DIR/run-local.sh" 2>/dev/null || echo 0) ]]; then
      warn "brief last ran at $LOCALH local (WRONG) — but that run PREDATES the timezone fix. The schedule is corrected; tomorrow's 07:30 run is the real proof."
    else
      bad "🔴 brief last ran at $LOCALH LOCAL — WRONG HOUR, and this run is AFTER the fix. The schedule is still broken."
    fi
  fi
else
  warn "the morning brief has no log yet — it has never run"
fi

# Every path cron points at must actually exist. This is how the systemd units were
# broken for two days: they pointed at ~/agent-machinery, which does not exist.
while read -r P; do
  [[ -x "$P" ]] && ok "cron target exists: $(basename "$P")" \
                || bad "CRON POINTS AT A NONEXISTENT PATH: $P"
done < <(crontab -l 2>/dev/null | grep -oE '/home/[^ ]*\.sh' | sort -u)

grep -q '"Bash"' "$HOME/.claude/settings.json" 2>/dev/null \
  && ok "permission policy installed at the user level (the only layer that applies)" \
  || bad "policy stale — run scripts/install-permissions.sh"

DRIFT=0
for L in "$REPO_DIR/.claude/settings.local.json" "$HOME/.claude/settings.local.json"; do
  [[ -f "$L" ]] && grep -q '"allow": \[[^]]' "$L" 2>/dev/null && { bad "$(basename "$L") HAS DRIFTED — 'always allow' widened your permissions"; DRIFT=1; }
done
[[ $DRIFT -eq 0 ]] && ok "no permission drift"

echo "  … testing a real headless Gmail call (this is the one that matters)"
G=$(cd "${WORKSPACE_DIR:-$HOME/agent}" && timeout 120 claude -p \
  "Search Gmail newer_than:1d. Reply with ONLY the number of threads, or UNREACHABLE." \
  --allowedTools "mcp__claude_ai_Gmail__search_threads" --max-turns 4 2>/dev/null | tail -1)
[[ "$G" =~ [0-9] ]] && ok "headless Gmail OK ($G threads) — the brief can see your mail" \
                    || bad "HEADLESS GMAIL UNREACHABLE — the brief would be BLIND. Got: '$G'"

"$SCRIPT_DIR/notify.sh" "🩺 healthcheck" "Ran $(date '+%H:%M %Z')." >/dev/null 2>&1 \
  && ok "ntfy accepted the push" || bad "ntfy FAILED — the agent cannot reach you"

# ── 2. DURABILITY ─────────────────────────────────────────────────────────────
hdr "2. DURABILITY — will it still be working after a reboot?"

pgrep -f 'Paseo Daemon' >/dev/null && ok "Paseo daemon alive" || bad "Paseo daemon DOWN"
crontab -l 2>/dev/null | grep -q '@reboot.*paseo-watchdog' \
  && ok "Paseo restarts on boot (@reboot watchdog)" \
  || bad "🔴 PASEO WILL NOT SURVIVE A REBOOT — you'd lose the phone channel, SSH only"
crontab -l 2>/dev/null | grep -q 'paseo-watchdog' \
  && ok "Paseo watchdog polls (survives a crash, not just a reboot)" \
  || warn "no watchdog poll — a crash between reboots goes unnoticed"

systemctl is-enabled cron &>/dev/null && ok "cron daemon enabled at boot" \
                                      || bad "cron NOT enabled at boot — nothing would run"

if systemctl --user is-enabled agent-morning-brief.timer &>/dev/null; then
  bad "🔴 systemd timer ALSO enabled — DOUBLE BRIEFS. One scheduler only."
else
  ok "systemd timers disabled (cron is the sole scheduler)"
fi

# ── 3. RECOVERABILITY ─────────────────────────────────────────────────────────
hdr "3. RECOVERABILITY — does it survive the server dying?"

for R in "$CTX" "$REPO_DIR"; do
  N="$(basename "$R")"
  B=$(git -C "$R" rev-parse --abbrev-ref HEAD 2>/dev/null)
  U=$(git -C "$R" log --oneline "origin/$B..HEAD" 2>/dev/null | wc -l)
  if [[ "$U" -eq 0 ]]; then ok "$N: fully pushed (offsite copy is current)"
  elif [[ "$U" -lt 5 ]]; then warn "$N: $U unpushed commit(s)"
  else bad "$N: $U UNPUSHED COMMITS — that work exists on ONE machine"
  fi
done

LO="$CTX/local-only"
if [[ -d "$LO" ]]; then
  NEWEST=$(ls -1t "${BACKUP_DIR:-$HOME/backups}"/local-only-*.tar.gz 2>/dev/null | head -1)
  if [[ -z "$NEWEST" ]]; then
    bad "local-only/ has NO backup — git ignores it, so this is its ONLY copy on earth"
  else
    AGE=$(( ( $(date +%s) - $(stat -c %Y "$NEWEST") ) / 86400 ))
    [[ $AGE -le 2 ]] && ok "local-only/ snapshot is ${AGE}d old" \
                     || warn "local-only/ snapshot is ${AGE}d old — backup may be failing"
  fi
  # 3-2-1 is satisfied ONLY if a second machine is pulling the tarballs. The Mac sync
  # does that — but only while the Mac is actually syncing. Tie it to the real signal.
  if [[ -n "${MACLAST:-}" && $(( ( $(date +%s) - ${MACLAST%.*} ) / 86400 )) -le 3 ]]; then
    ok "3-2-1 met: the Mac is pulling backups to a 2nd machine (synced recently)"
  else
    warn "3-2-1 AT RISK: snapshots sit on the box they back up, and the Mac isn't syncing"
  fi
fi

# Is the LAPTOP still talking to us? If it stops (lid shut for days, key expired,
# network), the nightly journal stops seeing his VS Code conversations, so the log and
# brief silently fall behind what he's actually working on. Everything LOOKS fine — which
# is what makes it dangerous.
if [[ -n "$MACLAST" ]]; then
  MACAGE=$(( ( $(date +%s) - ${MACLAST%.*} ) / 3600 ))
  if   [[ $MACAGE -le 24 ]]; then ok "Mac synced ${MACAGE}h ago — your VS Code work is reaching the server"
  elif [[ $MACAGE -le 72 ]]; then warn "Mac hasn't synced in ${MACAGE}h — your recent VS Code work may not be logged yet"
  else bad "🔴 Mac hasn't synced in ${MACAGE}h — the server is NOT seeing your VS Code work; the brief is falling behind"
  fi
else
  warn "no Mac-sync heartbeat yet — the Mac hasn't run the updated sync lib once; can't confirm it's syncing until it does"
fi

# ── 4. BOUNDEDNESS ────────────────────────────────────────────────────────────
hdr "4. BOUNDEDNESS — can it run away? (an unbounded agent is an unbounded bill)"

grep -q 'flock' "$SCRIPT_DIR/run-agent.sh"   && ok "LOCK: one instance per job (a hang can't stack)"    || bad "no lock — a hung run means jobs PILE UP"
grep -q 'timeout' "$SCRIPT_DIR/run-agent.sh" && ok "TIMEOUT: hard wall-clock kill on claude -p"         || bad "no timeout — a hang runs FOREVER"
grep -q 'CIRCUIT BREAKER' "$SCRIPT_DIR/run-agent.sh" \
  && ok "CIRCUIT BREAKER: max ${AGENT_MAX_RUNS_PER_DAY:-12} runs/job/day, then it refuses and pages you" \
  || bad "no circuit breaker — a loop bills you until someone notices"
grep -q 'max-turns' "$SCRIPT_DIR/run-agent.sh" && ok "TURN CAP: bounds tool-call depth per run" || bad "no --max-turns"

RUNAWAY=$(find "$HOME/.agent-logs/state" -name '*.count' -newermt today 2>/dev/null \
          | xargs -r cat 2>/dev/null | sort -rn | head -1)
[[ -z "${RUNAWAY:-}" || "${RUNAWAY:-0}" -le 6 ]] && ok "run counts normal today (max ${RUNAWAY:-0})" \
  || warn "a job ran ${RUNAWAY}x today — investigate before the breaker trips"

# NOTE: `pgrep -fc ... || echo 0` emitted "0\n0" when pgrep found nothing AND exited
# non-zero, producing a multiline value and an arithmetic error. The healthcheck caught
# this bug in itself on its first run — which is precisely the argument for having one.
STUCK=$(pgrep -fc 'claude -p' 2>/dev/null); STUCK=${STUCK:-0}
[[ "$STUCK" -le 2 ]] && ok "no piled-up claude processes ($STUCK running)" \
                     || bad "$STUCK concurrent 'claude -p' — something is stuck"

D=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[[ "$D" -lt 85 ]] && ok "disk ${D}% used" || bad "disk ${D}% — logs or backups are eating the box"

# ── 5. PUBLISHABILITY ─────────────────────────────────────────────────────────
hdr "5. PUBLISHABILITY — is the PUBLIC repo safe to push?"

HITS=$("$SCRIPT_DIR/pii-scan.sh" "$REPO_DIR" 2>/dev/null || true)
if [[ -n "$HITS" ]]; then
  bad "🔴 PII IN THE PUBLIC REPO — do NOT push:"
  echo "$HITS" | sed 's|^|        |'
else
  ok "no emails or IPs in the public repo"
fi
grep -q 'PII' "$SCRIPT_DIR/backup-context.sh" \
  && ok "backup refuses to push the public repo if PII appears" \
  || bad "backup has no PII gate — it could publish your data automatically"

echo
echo "═════════════════════════════════════════════"
printf "  PASS %d   WARN %d   FAIL %d\n" "$PASS" "$WARN" "$FAIL"
if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then echo "  ✅ Cairn is healthy on all five properties."
elif [[ $FAIL -eq 0 ]]; then                echo "  🟡 Working, with $WARN warning(s). Nothing is broken."
else                                        echo "  ❌ $FAIL FAILURE(S). Do not trust the automation until fixed."
fi
echo "═════════════════════════════════════════════"

[[ $FAIL -gt 0 ]] && "$SCRIPT_DIR/notify.sh" "❌ Cairn healthcheck: $FAIL failure(s)" \
  "The weekly self-audit found $FAIL problem(s). Run scripts/healthcheck.sh on the server." >/dev/null 2>&1
exit $(( FAIL > 0 ? 1 : 0 ))
