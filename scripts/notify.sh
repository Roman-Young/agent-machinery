#!/usr/bin/env bash
# notify.sh — push a notification to Roman's phone via ntfy. TWO TIERS (2026-07-17).
#
# Usage: notify.sh <alert|fyi> <title> <message>
#        notify.sh <title> <message>            (old 2-arg form — defaults to "alert")
#
# ══════════════════════════════════════════════════════════════════════════════
# WHY TWO TOPICS, NOT ONE
#
# Every script in this system used to push through one topic at equal weight — "your
# backup failed" and "task added, here's a confirmation" buzzed the phone identically.
# Roman asked for this to stay lean, so:
#
#   alert (NTFY_TOPIC)      — needs attention: something broken, overdue, or a real
#                             decision. Set this to buzz/alert on the phone.
#   fyi   (NTFY_TOPIC_FYI)  — routine: the daily brief, a task-added confirmation, a
#                             passing weekly healthcheck. Set this to silent/badge-only.
#
# NTFY_TOPIC_FYI is OPTIONAL. If it isn't set, fyi-tier pushes fall back to the alert
# topic — so nothing is ever silently dropped just because the second topic hasn't been
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
if [[ "${1:-}" == "alert" || "${1:-}" == "fyi" ]]; then
  TIER="$1"; TITLE="${2:?usage: notify.sh [alert|fyi] <title> <message>}"; MESSAGE="${3:?usage: notify.sh [alert|fyi] <title> <message>}"
else
  TIER="alert"   # safe default: an un-migrated call site stays visible, never silently demoted
  TITLE="${1:?usage: notify.sh [alert|fyi] <title> <message>}"; MESSAGE="${2:?usage: notify.sh [alert|fyi] <title> <message>}"
fi

if [[ -z "${NTFY_URL:-}" || -z "${NTFY_TOPIC:-}" ]]; then
  echo "ERROR: NTFY_URL / NTFY_TOPIC not set in $REPO_DIR/.env — cannot notify." >&2
  exit 1
fi

TOPIC="$NTFY_TOPIC"
[[ "$TIER" == "fyi" && -n "${NTFY_TOPIC_FYI:-}" ]] && TOPIC="$NTFY_TOPIC_FYI"

# --fail so a non-2xx is an error, not a silent success.
if curl -fsS \
      -H "Title: $TITLE" \
      -H "Markdown: yes" \
      -d "$MESSAGE" \
      "$NTFY_URL/$TOPIC" >/dev/null; then
  echo "notified ($TIER): $TITLE"
else
  echo "ERROR: ntfy push FAILED (curl non-zero). Topic or URL wrong?" >&2
  exit 1
fi
