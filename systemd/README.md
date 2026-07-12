# Scheduling with systemd user timers

1. Copy the .service and .timer pairs to `~/.config/systemd/user/`
2. `systemctl --user daemon-reload`
3. `systemctl --user enable --now agent-morning-brief.timer`
4. Check: `systemctl --user list-timers` and
   `journalctl --user -u agent-morning-brief.service`

So user timers run without an active login session:
`sudo loginctl enable-linger $USER`

Clone `agent-nightly-journal.{service,timer}` from the morning-brief
pair (OnCalendar=*-*-* 23:00:00) when ready. Every job notifies the
phone on failure via run-agent.sh — the fail-loud rule.
