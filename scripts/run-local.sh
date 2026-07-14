#!/usr/bin/env bash
# run-local.sh — run a job only if it is the intended LOCAL time. DST-proof. No sudo.
# Usage:  run-local.sh HH:MM /path/to/job.sh [args...]
#
# ══════════════════════════════════════════════════════════════════════════════
# WHY THIS EXISTS — the bug it fixes was live in production for a full day.
#
# The server runs UTC. The owner lives in Pacific. So the crontab said:
#
#     CRON_TZ=America/Los_Angeles
#     30 7 * * *   morning-brief.sh
#
# **Debian/Ubuntu cron DOES NOT HONOUR CRON_TZ.** It silently ignores it. So "30 7"
# meant 07:30 **UTC** — and the "morning" brief fired at **00:30 Pacific**, half past
# midnight. Exactly the failure the CRON_TZ line was written to prevent.
#
# It was "verified" by READING the crontab, not by checking WHEN THE JOB ACTUALLY RAN.
# The proof was sitting in the log the whole time:
#     [2026-07-14T07:30:01+00:00] job=morning-brief starting
# Rule 1 of docs/architecture.md — "run it, don't reason about it" — broken by the
# person who wrote it. Config that LOOKS right is not config that IS right.
#
# ── THE FIX ───────────────────────────────────────────────────────────────────
# Cron fires at BOTH UTC times that could correspond to the target local hour (one for
# DST, one for standard time). This wrapper then checks the ACTUAL local clock and lets
# exactly one of them through. The other exits instantly, costing nothing.
#
#     30 14,15 * * *   run-local.sh 07:30 morning-brief.sh
#
#   PDT (summer):  14:30 UTC = 07:30 local ✅ runs  |  15:30 UTC = 08:30 local ✗ skips
#   PST (winter):  14:30 UTC = 06:30 local ✗ skips  |  15:30 UTC = 07:30 local ✅ runs
#
# Correct on both sides of every DST transition, forever, with no sudo and no
# timezone support from cron at all. It is also the pattern Debian's own crontab(5)
# man page recommends.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

WANT="${1:?usage: run-local.sh HH:MM <command> [args...]}"; shift
LOCAL_TZ="${LOCAL_TZ:-America/Los_Angeles}"

NOW="$(TZ="$LOCAL_TZ" date +%H:%M)"

if [[ "$NOW" != "$WANT" ]]; then
  exit 0   # wrong local hour — this is the DST twin. Silent, free, correct.
fi

exec "$@"
