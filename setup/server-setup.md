# Server Setup — from zero to first automation

Order of operations for a fresh Hetzner CX33 (or any Ubuntu box).
Do the laptop phase first: fill in the context repo locally and have a
few sessions with the agent *before* provisioning — the memory layer is
the foundation and needs no server.

## 1. Provision

- Hetzner Cloud → CX33 (4 vCPU / 8 GB / 80 GB), Ubuntu LTS, add your
  SSH public key at creation time.
- First login: create a non-root user, add to sudo, disable root SSH
  login and password auth (`/etc/ssh/sshd_config`: PermitRootLogin no,
  PasswordAuthentication no), `sudo apt update && sudo apt upgrade`.
- Enable the firewall: `sudo ufw allow OpenSSH && sudo ufw enable`.

## 2. Install the agent runtime

- Install Claude Code per current official instructions:
  https://docs.claude.com/en/docs/claude-code/overview
- Authenticate for headless use (`claude setup-token` for subscription
  auth, or set ANTHROPIC_API_KEY in .env for API billing).
- Optional, per Dan's flow: install Paseo CLI and pair with phone/laptop
  so you can reach the agent without raw SSH.

## 3. Clone the two repos

```
git clone git@github.com:YOURUSER/my-context.git ~/my-context
git clone git@github.com:YOURUSER/agent-machinery.git ~/agent-machinery
cd ~/agent-machinery && cp example.env .env && $EDITOR .env
```

Symlink or copy CLAUDE.md into the context repo so sessions started
there pick it up: `ln -s ~/agent-machinery/CLAUDE.md ~/my-context/CLAUDE.md`
(add `CLAUDE.md` to my-context/.gitignore so the symlink isn't tracked).

## 4. Smoke-test headless

```
~/agent-machinery/scripts/morning-brief.sh
```

Without ntfy configured it just logs to ~/.agent-logs/ — read the log
and confirm the brief actually used your context files.

## 5. Schedule it

Follow systemd/README.md. Enable lingering so timers run while you're
logged out.

## 6. Phase 2 (only when the pain arrives)

- ntfy (Docker) for phone push → set NTFY_URL/NTFY_TOPIC in .env.
- Nightly journal timer.
- SQLite → Postgres+pgvector when markdown stops cutting it for records.
- nginx + certbot reverse proxy when there's a dashboard worth reaching.

## Roadmap — agent capabilities (in Roman's priority order)

Ordered by stated value. Each earns its place only when the prior layer is solid.

1. **Task & deadline tracking** — one trusted place the agent maintains; surfaces
   what's slipping. Starts as markdown, graduates to SQLite when it outgrows a file.
2. **Study plans from syllabi** — connect Canvas + Google Calendar; ingest each
   class's syllabus and test dates; auto-build structured study plans (the antidote
   to open-ended courses like PHIL 27). Immediate manual version: PHIL 27 midterm plan.
3. **Resume tailoring** — read base resume; per job description, produce tailored,
   truthful bullets in Roman's voice; track applications/deadlines.
4. **Email triage** — read + summarize + draft (NEVER send); flag important/urgent
   and things with deadlines. Requires the Gmail MCP server.
5. **Work protocol knowledge / weekly summaries** — capture common lab procedures
   (flow panels, staining checklists, ELISA/IgA steps) as reusable checklists;
   produce weekly work summaries. Detailed/unpublished specifics → local-only/.
6. **Later (on real pain):** gym scheduling, broad meal/macro tracking.

MCP servers implied by the above, roughly in order: filesystem (built in),
Google Calendar, Gmail, Canvas (custom/community MCP), then a task DB.
