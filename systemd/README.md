# Scheduling — we use CRON, not systemd timers

**The systemd units in this directory are kept but DISABLED.** The live scheduler is
`crontab -l`.

## Why

systemd **user** timers only run while the user has an active login session — unless
`loginctl enable-linger` is set. That requires **sudo**, which requires a password Roman
set when he created the account (2026-07-12) and no longer has.

**Cron has no such requirement.** It runs regardless of login, needs no sudo, and it is
already installed and active. So cron won it on the only axis that mattered: it works today.

## The two things that will silently break a cron job

Both were real, and both are handled in the installed crontab:

1. **`CRON_TZ=America/Los_Angeles`.** The server is `Etc/UTC`. Without this, `30 7` means
   07:30 **UTC** = **00:30 Pacific** — the "morning" brief arrives at half past midnight.
   `CRON_TZ` also tracks DST, so it won't drift an hour twice a year.
2. **`PATH`.** Cron starts with a near-empty PATH. Without an explicit one, `claude` is
   simply *not found*, and the job fails silently every single day.

## Current schedule

| Job | When (Pacific) | What |
|---|---|---|
| `morning-brief.sh` | **07:30** daily | Email triage + today's tasks + deadlines → ntfy push |
| `nightly-journal.sh` | **01:45** daily | Distills the day's session transcripts → `logs/` |

Journal runs at 01:45 on purpose: Roman's deep-work block is ~10pm–1am, so a journal at
11pm would systematically miss his three most productive hours.

## If sudo is ever recovered

systemd timers are marginally better — `Persistent=true` catches up a run missed while the
server was down; cron just skips it. If Roman regains sudo:

```bash
sudo loginctl enable-linger roman
crontab -r                                    # exactly ONE scheduler, or jobs double-fire
./scripts/install-timers.sh
```

**Never run both.** Two schedulers = two briefs every morning.

## Verifying (do not trust, check)

```bash
crontab -l                                    # is it scheduled?
tail ~/.agent-logs/cron.log                   # did it run?
tail ~/.agent-logs/$(date +%F)-morning-brief.log   # what did it say?
./scripts/notify.sh "test" "does this reach the phone?"
```

Cron was verified end-to-end on 2026-07-14 with a one-shot job that pushed to ntfy and
arrived — not by reading the crontab and assuming.
