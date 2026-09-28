#!/usr/bin/env bash
# sent-mail-reconcile.sh — nightly: auto-close outreach/reply TASKS once Roman has
# actually SENT the email. Closes the gap Roman hit 2026-09-28: email-triage.sh only
# APPENDS tasks (never closes), and nightly-maintenance.sh reconciles from the day's LOG,
# not from Gmail — so a thank-you/reply he sent without logging it stayed open forever.
#
# ══════════════════════════════════════════════════════════════════════════════
# DESIGN — the same trust boundary as email-triage.sh + sheet_status_update.py:
#   1. TRUSTED PRE-PASS (sent_mail_candidates.py): deterministically pick OPEN tasks that
#      are resolved by SENDING an email to a person, and extract the recipient address(es).
#      Bounds the agent + encodes "reply task" vs "pay-a-bill-whose-notice-came-by-email".
#   2. AGENT (read-only): given ONLY that vetted list, search Roman's SENT mail for each
#      address and JUDGE whether a sent message fulfills the task. It has Gmail READ tools
#      only — NO send/draft/label, NO Bash, NO Edit/Write. It can only EMIT proposals.
#   3. TRUSTED POST-PASS (this script): parse the proposals; CLOSE via taskctl.py (which
#      MOVES to done:, never deletes, and re-renders); FLAG ambiguous ones into today's log.
#      Every change is one reversible git commit.
#
# Auto-apply is gated to UNAMBIGUOUS matches the agent is confident about (Roman's autonomy
# contract). Everything else is flagged, never guessed. LinkedIn InMails are a KNOWN blind
# spot — they never appear in Gmail, so they simply never match here (correct, not a bug).
#
# Guards (lock/timeout/circuit-breaker/turn-cap/fail-loud) are inherited from run-agent.sh.
# Runs BEFORE nightly-maintenance in the nightly window so its closes are already reflected.
#
# Usage:
#   sent-mail-reconcile.sh            # DRY RUN — prints proposals, changes nothing
#   sent-mail-reconcile.sh --apply    # applies closes + flags (what cron uses)
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TODAY="$(date +%F)"
APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

if [[ -f "$REPO_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
fi
: "${CONTEXT_DIR:?CONTEXT_DIR must be set (in .env)}"
LOG_DIR="${AGENT_LOG_DIR:-$HOME/.agent-logs}"; mkdir -p "$LOG_DIR"
notify() { "$SCRIPT_DIR/notify.sh" "${1:-fyi}" "$2" "$3" >/dev/null 2>&1 || true; }

# ── Step 1: TRUSTED candidate list ────────────────────────────────────────────
CANDS="$(python3 "$SCRIPT_DIR/sent_mail_candidates.py" "$CONTEXT_DIR/tasks.yaml" 2>/dev/null || true)"
if [[ -z "$CANDS" ]]; then
  echo "[$(date -Is)] sent-mail-reconcile: no outreach/reply candidates — nothing to check." \
    >> "$LOG_DIR/$TODAY-sent-mail-reconcile.log"
  exit 0
fi
N_CAND=$(printf '%s\n' "$CANDS" | grep -c .)

# ── Step 2: AGENT (Gmail READ only, proposes; never writes) ───────────────────
export AGENT_ALLOWED_TOOLS="Read,mcp__claude_ai_Gmail__search_threads,mcp__claude_ai_Gmail__get_thread"
export AGENT_MAX_TURNS=40
export AGENT_TIMEOUT_SEC=420
export PUSH_OUTPUT=0

PROMPT="You are Kairo, checking whether Roman has already SENT the emails that would resolve
some open tasks. Now: $(date +'%A %B %d, %Y %H:%M').

FAIL-LOUD: your FIRST line must be exactly 'gmail=ok' if search_threads works, or 'gmail=FAIL'
if you cannot read Gmail. A run that silently can't see Gmail is worse than none.

Below are OPEN tasks, each already vetted as 'resolved by Roman sending an email to a person',
with the recipient address(es). TAB-separated: id | title | addresses | why.
--- CANDIDATES ---
$CANDS
------------------

For EACH task:
  1. search_threads with:  in:sent to:<address> newer_than:45d   (try each address).
  2. If a hit looks relevant, get_thread to confirm it is a message ROMAN SENT that actually
     FULFILLS THIS task's intent (e.g. the reply it asked for, the thank-you, the request).
  3. Decide, and emit EXACTLY ONE line per task, nothing else, in one of these formats:
       CLOSE <id> | <YYYY-MM-DD you saw it sent> | <short evidence: subject / who-to>
       FLAG  <id> | <why it's ambiguous — a maybe, wrong-looking match, or partial>
       NONE  <id>
     (No prose, no markdown, no extra commentary. One line per task id above.)

BE CONSERVATIVE. CLOSE only when a sent message clearly fulfills the task — not merely any
email to that address, and not a message Roman RECEIVED. Anything short of clear -> FLAG.
When unsure between CLOSE and FLAG, choose FLAG. Only these task ids exist; do not invent ids."

OUT="$("$SCRIPT_DIR/run-agent.sh" sent-mail-reconcile "$PROMPT" 2>>"$LOG_DIR/$TODAY-sent-mail-reconcile.log")"
RC=$?
if [[ $RC -ne 0 ]]; then
  # run-agent.sh already fired its own fail-loud alert; just stop.
  exit "$RC"
fi

# ── Fail-loud coverage check (same rule as email-triage.sh) ───────────────────
if ! printf '%s\n' "$OUT" | head -1 | grep -qi '^gmail=ok'; then
  notify alert "⚠️ sent-mail-reconcile: no Gmail coverage" \
    "Agent did not confirm gmail=ok — NOT closing any tasks this run. Check $LOG_DIR/$TODAY-sent-mail-reconcile.log"
  exit 1
fi

# ── Step 3: TRUSTED apply ─────────────────────────────────────────────────────
CLOSED=(); FLAGGED=(); SKIPPED=()
while IFS= read -r line; do
  case "$line" in
    CLOSE\ *)
      id="$(sed -E 's/^CLOSE[[:space:]]+([A-Za-z0-9]+).*/\1/' <<<"$line")"
      ev="$(sed -E 's/^CLOSE[[:space:]]+[A-Za-z0-9]+[[:space:]]*\|?[[:space:]]*//' <<<"$line" | tr -d '\n' | cut -c1-200)"
      if [[ $APPLY -eq 1 ]]; then
        if python3 "$SCRIPT_DIR/taskctl.py" done "$id" \
             --notes "auto-closed by sent-mail-reconcile $TODAY: sent email found — $ev" \
             >/dev/null 2>>"$LOG_DIR/$TODAY-sent-mail-reconcile.log"; then
          CLOSED+=("$id: $ev")
        else
          SKIPPED+=("$id (taskctl refused — not open? already done?)")
        fi
      else
        CLOSED+=("[dry-run] $id: $ev")
      fi
      ;;
    FLAG\ *)
      fid="$(sed -E 's/^FLAG[[:space:]]+([A-Za-z0-9]+).*/\1/' <<<"$line")"
      freason="$(sed -E 's/^FLAG[[:space:]]+[A-Za-z0-9]+[[:space:]]*\|?[[:space:]]*//' <<<"$line" | cut -c1-200)"
      FLAGGED+=("$fid: $freason")
      ;;
  esac
done <<<"$OUT"

# Write FLAGs into today's log so they surface (only when applying for real).
if [[ $APPLY -eq 1 && ${#FLAGGED[@]} -gt 0 ]]; then
  LOGMD="$CONTEXT_DIR/logs/daily/$TODAY.md"
  {
    echo ""
    echo "## Needs Roman (sent-mail reconcile)"
    for f in "${FLAGGED[@]}"; do echo "- $f"; done
  } >> "$LOGMD"
fi

# Commit any changes (taskctl already re-rendered tasks.md on each close).
SUMMARY="sent-mail-reconcile: closed ${#CLOSED[@]}, flagged ${#FLAGGED[@]}, skipped ${#SKIPPED[@]} (of $N_CAND candidates)"
if [[ $APPLY -eq 1 ]]; then
  cd "$CONTEXT_DIR"
  if ! git diff --quiet -- tasks.yaml tasks.md "logs/daily/$TODAY.md" 2>/dev/null; then
    git add tasks.yaml tasks.md "logs/daily/$TODAY.md" 2>/dev/null
    git commit -m "maint: $SUMMARY" >/dev/null 2>&1 || true
  fi
fi

# Report.
{
  echo "[$(date -Is)] $SUMMARY (apply=$APPLY)"
  printf '  CLOSED: %s\n' "${CLOSED[@]:-none}"
  printf '  FLAGGED: %s\n' "${FLAGGED[@]:-none}"
  printf '  SKIPPED: %s\n' "${SKIPPED[@]:-none}"
} >> "$LOG_DIR/$TODAY-sent-mail-reconcile.log"

echo "$SUMMARY"
printf 'CLOSED: %s\n' "${CLOSED[@]:-none}"
printf 'FLAGGED: %s\n' "${FLAGGED[@]:-none}"
[[ ${#SKIPPED[@]} -gt 0 ]] && printf 'SKIPPED: %s\n' "${SKIPPED[@]}"

# Notify only when something actually changed (fyi tier — routine).
if [[ $APPLY -eq 1 && ( ${#CLOSED[@]} -gt 0 || ${#FLAGGED[@]} -gt 0 ) ]]; then
  notify fyi "🗂️ sent-mail-reconcile" "$SUMMARY"
fi
exit 0
