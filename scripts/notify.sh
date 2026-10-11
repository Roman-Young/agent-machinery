#!/usr/bin/env bash
# notify.sh — push a notification to Roman's phone via ntfy. THREE TIERS (2026-07-20).
#
# Usage: notify.sh <urgent|alert|fyi> <title> <message>
#        notify.sh <title> <message>            (old 2-arg form — defaults to "alert")
#        NOTIFY_ATTACH=/path/preview.png notify.sh fyi <title> <message>   (attach a file; an
#                                                image shows inline on the phone)
#
# ══════════════════════════════════════════════════════════════════════════════
# WHY TWO TOPICS, NOT ONE
#
# Every script in this system used to push through one topic at equal weight — "your
# backup failed" and "task added, here's a confirmation" buzzed the phone identically.
# Roman asked for this to stay lean, so:
#
#   urgent (NTFY_TOPIC_URGENT) — a live email that needs Roman NOW: a job/recruiter reply,
#                             a money/housing deadline, a person waiting on a time-bound
#                             answer. Set this to MAX priority (sound + pop-up) on the phone.
#   alert (NTFY_TOPIC)      — needs attention: something broken, overdue, or a real
#                             decision. Set this to buzz/alert on the phone.
#   fyi   (NTFY_TOPIC_FYI)  — routine: the daily brief, a task-added confirmation, a
#                             passing weekly healthcheck. Set this to silent/badge-only.
#
# NTFY_TOPIC_FYI and NTFY_TOPIC_URGENT are OPTIONAL. If unset, that tier's pushes fall back
# to the alert topic — so nothing is ever silently dropped just because a topic hasn't been
# created yet. Standalone (not just a function inside run-agent.sh) so any script, and
# Roman himself from the shell, can push, and the ntfy config is verified in ONE place.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$REPO_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
fi

# Detect old 2-arg form (title, message) vs new 3-arg form (tier, title, message).
if [[ "${1:-}" == "urgent" || "${1:-}" == "alert" || "${1:-}" == "fyi" ]]; then
  TIER="$1"; TITLE="${2:?usage: notify.sh [urgent|alert|fyi] <title> <message>}"; MESSAGE="${3:?usage: notify.sh [urgent|alert|fyi] <title> <message>}"
else
  TIER="alert"   # safe default: an un-migrated call site stays visible, never silently demoted
  TITLE="${1:?usage: notify.sh [urgent|alert|fyi] <title> <message>}"; MESSAGE="${2:?usage: notify.sh [urgent|alert|fyi] <title> <message>}"
fi

if [[ -z "${NTFY_URL:-}" || -z "${NTFY_TOPIC:-}" ]]; then
  echo "ERROR: NTFY_URL / NTFY_TOPIC not set in $REPO_DIR/.env — cannot notify." >&2
  exit 1
fi

TOPIC="$NTFY_TOPIC"
[[ "$TIER" == "fyi"    && -n "${NTFY_TOPIC_FYI:-}"    ]] && TOPIC="$NTFY_TOPIC_FYI"
[[ "$TIER" == "urgent" && -n "${NTFY_TOPIC_URGENT:-}" ]] && TOPIC="$NTFY_TOPIC_URGENT"

# Optional scheduled delivery: NOTIFY_DELAY="8am" (or "30s", "2h", epoch) uses ntfy's
# Delay header so a 3am cron job can speak at a human hour. Unset = deliver now.
DELAY_ARGS=()
[[ -n "${NOTIFY_DELAY:-}" ]] && DELAY_ARGS=(-H "Delay: $NOTIFY_DELAY")

# Optional attachment: NOTIFY_ATTACH=/path/file (e.g. a rendered preview, so Roman can see visual
# work from his phone when he's away from the desk). The file becomes the request body, so the
# text moves into headers, which can't carry newlines. ntfy.sh keeps attachments 3 h, 15 MB max.
if [[ -n "${NOTIFY_ATTACH:-}" ]]; then
  if [[ ! -f "$NOTIFY_ATTACH" ]]; then
    echo "ERROR: NOTIFY_ATTACH file not found: $NOTIFY_ATTACH" >&2
    exit 1
  fi
  if curl -fsS -T "$NOTIFY_ATTACH" \
        -H "Title: $TITLE" \
        -H "Message: $(printf '%s' "$MESSAGE" | tr '\n' ' ')" \
        -H "Filename: $(basename "$NOTIFY_ATTACH")" \
        "${DELAY_ARGS[@]}" \
        "$NTFY_URL/$TOPIC" >/dev/null; then
    echo "notified ($TIER, with $(basename "$NOTIFY_ATTACH")): $TITLE"
    exit 0
  else
    echo "ERROR: ntfy push with attachment FAILED (curl non-zero). File too big, or topic/URL wrong?" >&2
    exit 1
  fi
fi

# --fail so a non-2xx is an error, not a silent success.
if curl -fsS \
      -H "Title: $TITLE" \
      -H "Markdown: yes" \
      "${DELAY_ARGS[@]}" \
      -d "$MESSAGE" \
      "$NTFY_URL/$TOPIC" >/dev/null; then
  echo "notified ($TIER): $TITLE"
else
  echo "ERROR: ntfy push FAILED (curl non-zero). Topic or URL wrong?" >&2
  exit 1
fi
