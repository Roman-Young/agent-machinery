# agent-machinery

Infrastructure for a personal AI agent: an always-on system that reads a
private context repository (plain markdown about its owner) at the start
of every session and runs scheduled automations on a small Linux server.

Design thesis: **the model is a commodity; accumulated personal context
is the durable value.** This repo is only the machinery. The memory lives
in a separate private repo that these scripts point at — clone this,
build your own context repo, fill in `.env`, and you have your own agent.

## Architecture

```
you (chat / phone) ──► agent (Claude Code)
                          │  reads: context repo (markdown memory)
                          │  acts:  MCP servers (phase 2)
systemd timers ──────────►│  scheduled headless runs (claude -p)
                          └─► ntfy ──► phone push (phase 2)
```

Principles (learned from a friend's production setup):
- Start minimal; every component must earn its place by solving real pain.
- Fail loud — every scheduled job pings the phone on failure.
- Draft, never send — the agent prepares actions; a human approves them.
- Secrets and personal identifiers never enter git (see `example.env`).

## Layout

- `CLAUDE.md` — agent instructions (references context *files*, never
  personal facts, so this repo stays publishable).
- `scripts/run-agent.sh` — headless run wrapper: env, scoped tools,
  turn cap, fail-loud notification.
- `scripts/morning-brief.sh`, `scripts/nightly-journal.sh` — automations.
- `scripts/backup-context.sh` — push context to GitHub + snapshot the
  gitignored local-only content.
- `systemd/` — timer units and install notes.
- `setup/server-setup.md` — zero-to-first-automation guide.

## Quick start

1. Create your own private `my-context` repo (me.md, goals.md,
   projects.md, logs/).
2. `cp example.env .env` and fill it in. Never commit `.env`.
3. Run `scripts/morning-brief.sh` manually; then schedule via `systemd/`.

## Credits

Architecture heavily informed by a friend's personal-agent setup and his
agent Makoto's writeup. Mistakes are mine.
