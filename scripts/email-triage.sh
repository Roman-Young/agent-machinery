#!/usr/bin/env bash
# email-triage.sh — hourly inbox triage. Classifies NEW personal-Gmail mail into five
# buckets, labels each in Gmail, buzzes the phone for URGENT, and files reply/action
# items so the morning brief can surface them. (Built 2026-07-20, Roman's spec.)
#
# ══════════════════════════════════════════════════════════════════════════════
# THE FIVE BUCKETS (Roman's rules, 2026-07-20)
#
#   URGENT  — buzzes the phone NOW. Deliberately kept small. Only:
#             · a deadline due TODAY or TOMORROW (~48h), OR
#             · a late / past-due / overdue notice (esp. housing & money), OR
#             · a work email from a key person carrying SUBSTANTIVE info or a concrete
#               task/decision/data (Dan's "fix it + PR", not Eduard's "when are you free"),
#             · a job/recruiter/interview reply THAT asks for a same/next-day response.
#   reply   — needs a reply, but no clock on it. (Eduard scheduling; a networking reply.)
#   action  — YOU must DO something (not reply): upload, pay, register, sign a form.
#             No same/next-day deadline — if it had one, it'd be URGENT.
#   other   — notifications/updates worth keeping but not pushing.
#   junk    — receipts, automated security notices, promos, newsletters, noise.
#
# THE POINT OF URGENT IS THAT IT STAYS TRUSTWORTHY. The moment it cries wolf, Roman
# mutes it and the whole system is worthless. When unsure between URGENT and reply/
# action, it is NOT urgent. Under-firing is recoverable (the brief catches it in the
# morning); over-firing burns the channel.
#
# ══════════════════════════════════════════════════════════════════════════════
# IDEMPOTENCY — why this can run hourly without spamming
#
# Every processed thread gets a Gmail label `triaged`. The search EXCLUDES `-label:triaged`,
# so each email is classified exactly ONCE, ever. That single label is also what stops a
# URGENT email from re-buzzing every hour and a task from being added twice.
#
# ══════════════════════════════════════════════════════════════════════════════
# THE FAIL-LOUD RULE (same as morning-brief.sh — do not remove)
#
# A triage run that silently can't see Gmail is WORSE than none: Roman would assume a
# quiet phone means a quiet inbox. Verified 2026-07-14: a denied MCP tool returns no
# error to the model, which will happily report "0 new". So the agent must declare
# coverage on line 1, and THIS SCRIPT checks it. No gmail=ok → no trust → alert.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Read Gmail, label Gmail, read/append tasks.yaml. NO send, NO delete, NO archive, NO Bash.
# create_draft is deliberately ABSENT — triage classifies, it does not write replies.
# The renderer is run by THIS script afterward, so the agent never needs Bash.
export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,Edit,\
mcp__claude_ai_Gmail__search_threads,\
mcp__claude_ai_Gmail__get_thread,\
mcp__claude_ai_Gmail__list_labels,\
mcp__claude_ai_Gmail__create_label,\
mcp__claude_ai_Gmail__label_thread"
export AGENT_MAX_TURNS=40
export AGENT_TIMEOUT_SEC=420
export PUSH_OUTPUT=0   # we inspect output and push per-URGENT below, after the coverage check

OUT=$("$SCRIPT_DIR/run-agent.sh" email-triage \
"You are Cairo, triaging Roman's PERSONAL Gmail inbox. Now: $(date +'%A %B %d, %Y %H:%M').

READ FIRST, from the context repo:
- me.md  -> the table of PEOPLE / EMAIL SENDERS that matter (Dan Marrama, Danish Umar,
           Deepshika/Shika Ramanan, Eduard Ansaldo Gine, Ivy Tam, Bjoern Peters), the
           FAMILY table (Mom karenrapacon@, Dad darrony@, Brother masonyoung248@ — NEVER
           below 'reply'), and the note on which inboxes you can see. Use it; don't guess.
- tasks.yaml -> so you can APPEND tasks (below). Read meta.next_id.

STEP 1 — LABELS. Call list_labels. Ensure these labels exist; create_label any that don't:
  triaged, triage/urgent, triage/reply, triage/action, triage/other, triage/junk

STEP 2 — FIND NEW MAIL. search_threads with query:
  in:inbox newer_than:2d -label:triaged
Process AT MOST the 20 most recent. If there are none, that is a normal result — say so.

STEP 3 — CLASSIFY EACH into exactly one bucket. Read the thread (get_thread) enough to
judge. IMPORTANT: some mail is FORWARDED from Roman's work accounts — judge by the ORIGINAL
sender/subject in the body, not the forwarding envelope. GitHub notifications: an issue/PR
where Roman is @mentioned or assigned with a real ask (e.g. Dan asking for a fix + PR) is
work-substantive; an automated security/receipt/token notice is junk.

BUCKET RUBRIC (Roman's rules — URGENT MUST STAY SMALL):
  URGENT — ONLY if ONE of:
    (a) a deadline due TODAY or TOMORROW (within ~48h), OR
    (b) a late / past-due / overdue / final notice — especially housing or money, OR
    (c) a work email from a key person (list above) carrying SUBSTANTIVE content: a
        concrete task, decision, data, or important information (NOT mere scheduling), OR
    (d) a job / recruiter / interview / offer reply that asks for a same/next-day response.
    When torn between URGENT and reply/action, it is NOT urgent.
  reply  — needs a reply, no clock. (Scheduling, networking, 'let's connect'.)
  action — Roman must DO something (upload/pay/register/sign), no same/next-day deadline.
  other  — keep-but-don't-push notifications/updates.
  junk   — receipts, automated security notices, promos, newsletters, noise.

STEP 4 — LABEL. For each thread, label_thread with BOTH its bucket label
(triage/<bucket>) AND the triaged label. Every processed thread MUST get triaged, even junk
— that is what stops it being re-processed next hour.

STEP 5 — TASKS. For each email in URGENT or action that requires Roman to DO something
(reply-only emails do NOT count), APPEND one task to tasks.yaml:
  - Use the next free id from meta.next_id, then INCREMENT meta.next_id by 1 for the next.
  - domain: best guess (work/school/personal/other). project: null unless obvious.
  - urgency: red for URGENT-bucket items, yellow for action-bucket items.
  - due: the ISO date if the email states/implies one, else null.
  - status: open. notes: one line — what it is and why it matters, + 'from email: <sender>'.
  - ONLY APPEND. Never edit, reorder, or delete an existing task. Do NOT run any renderer.
If nothing needs a task, change nothing in tasks.yaml.

STEP 6 — OUTPUT. Line 1 MUST be exactly:
SOURCES: gmail=ok
Use gmail=FAIL if any Gmail call was denied/blocked/errored — never write ok to be
agreeable; a false ok is the worst outcome.
Then, ONE line per NEWLY-TRIAGED email, in this EXACT pipe format (this is parsed by a script):
BUCKET|sender|subject|one-line reason + what Roman should do
where BUCKET is one of URGENT REPLY ACTION OTHER JUNK (uppercase). Put URGENT lines first.
If nothing new: output the coverage line then a single line: NONE|-|-|no new mail.
Do not modify any files other than tasks.yaml. Be terse.")

# ── Coverage check: a triage we can't trust is not trusted. ──────────────────
if ! grep -qi 'gmail=ok' <<<"$OUT"; then
  "$SCRIPT_DIR/notify.sh" alert "⚠️ TRIAGE DEGRADED — Gmail unreachable" \
"Hourly email triage could NOT read your inbox, so URGENT mail may be sitting unseen.
Check your inbox yourself.

$OUT"
  exit 1   # fail loud: cron/log records it
fi

# ── Re-render tasks.md if the agent appended anything (agent has no Bash of its own). ──
if python3 "$SCRIPT_DIR/render-tasks.py" >/dev/null 2>&1; then
  :
else
  "$SCRIPT_DIR/notify.sh" alert "⚠️ Triage: render-tasks failed" \
    "Triage ran but render-tasks.py errored — tasks.md may be stale vs tasks.yaml. Check the server."
fi

# ── Buzz the phone once per URGENT email. ────────────────────────────────────
# One push each (not a digest) so each urgent item is individually actionable/dismissable.
URGENT_COUNT=0
while IFS='|' read -r bucket sender subject reason; do
  [[ "$bucket" == "URGENT" ]] || continue
  URGENT_COUNT=$((URGENT_COUNT+1))
  "$SCRIPT_DIR/notify.sh" urgent "🔴 ${sender:-inbox}" \
"${subject:-（no subject）}

${reason:-needs your attention}" || true
done < <(grep -E '^URGENT\|' <<<"$OUT" || true)

echo "[triage] $(grep -cE '^[A-Z]+\|' <<<"$OUT" || echo 0) triaged, $URGENT_COUNT urgent pushed"
