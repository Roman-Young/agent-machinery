# agent-machinery

Infrastructure for a personal AI agent: an always-on system that reads a private context
repository (plain markdown about its owner) at the start of every session, and runs
scheduled automations on a small Linux server.

**Design thesis: the model is a commodity; accumulated personal context is the durable
value.** This repo is only the machinery. The memory lives in a separate **private** repo
that these scripts point at. Clone this, build your own context repo, fill in `.env`, and
you have your own agent.

## Architecture

```
   phone / laptop
        │  (Paseo, or ssh)
        ▼
   ┌─────────────────── SERVER ───────────────────┐
   │  Claude Code  ──reads──►  context repo (memory) │
   │       │                                        │
   │       ├── MCP: Gmail · Calendar · Drive · …    │
   │       │                                        │
   │  cron ├──► morning-brief.sh   07:30 → ntfy → phone
   │       ├──► nightly-journal.sh 01:45 → logs/
   │       ├──► backup-context.sh  02:15 → git + tarball
   │       ├──► healthcheck.sh     weekly
   │       └──► paseo-watchdog.sh  @reboot + every 10m
   └────────────────────────────────────────────────┘
```

## The five properties (read this before changing anything)

Every failure this system has had came from confusing one of these for another. **Passing
one tells you nothing about the others.** `scripts/healthcheck.sh` tests all five.

| | Question | How it bit us |
|---|---|---|
| **1. Liveness** | Does it work *right now*? | The first healthcheck tested only this. 20/20 green — while the phone channel was one reboot from death and the backup had never run. |
| **2. Durability** | Will it still work *after a reboot*? | The daemon was hand-started with no supervisor. **"It's running" is not "it will still be running."** |
| **3. Recoverability** | Does it survive *the server dying*? | 25 commits and the entire memory layer sat on one box, with a 2-day-stale copy on GitHub and a backup script that had **never executed**. |
| **4. Boundedness** | Can it *run away*? | Zero timeouts, zero locks, zero rate caps. An agent that calls itself, on a timer, with a card attached, is a machine for burning money while you sleep. |
| **5. Publishability** | Is it *safe to push*? | This repo is public and had accumulated a server IP and five colleagues' work emails. Git history is forever. |

**And the rule underneath all of them:** *a green healthcheck is evidence; "I read the code
and it looks right" is not.* **Every bug in this system was invisible on read and obvious
within sixty seconds of running.** So: **run it, don't reason about it.**

## Guardrails

`scripts/run-agent.sh` is the single choke point every headless run passes through, so no
job can forget a guard:

- **Lock** (`flock`) — one instance per job. A hung run cannot stack.
- **Timeout** — hard wall-clock kill. `claude -p` *can* hang; cron will wait forever.
- **Circuit breaker** — max runs per job per day. Trips, refuses, and pages you. This is
  the one that catches a genuine runaway loop.
- **Turn cap** (`--max-turns`) — bounds tool-call depth.
- **Fail loud** — every failure pushes to the phone. A silent failure is worse than a
  crash, because you keep trusting the output.

## Security model

- **Broad Bash is allowed interactively; the jobs that read untrusted input have no Bash at
  all.** The agent ingests email and web pages — untrusted input plus shell access is the
  entire prompt-injection threat model. The morning brief gets `Read`/`Grep`/Gmail(read)/
  Calendar(read) and **no shell**, so *malicious email → shell command* does not exist.
  **⚠️ Never add Bash to a job that reads email or fetches web content.**
- **Every credential is read-only by construction.** Worst case is disclosure, never
  destruction.
- **Draft, never send** — enforced by *withholding the send tool*, not by a policy string.
- **`settings.local.json` is reset to empty on every install.** It auto-appends a rule each
  time you click "always allow," and nobody re-reads it. It had twice silently widened
  permissions, once to the private SSH keys.
- **`pii-scan.sh` gates the nightly push.** This repo is public; the backup refuses to
  publish it if an email address or server IP appears.

## Layout

| Path | What |
|---|---|
| `CLAUDE.md` | Agent instructions. References context *files*, never personal facts. |
| `scripts/run-agent.sh` | The choke point: env, least-privilege tools, all five guards. |
| `scripts/morning-brief.sh` | Email triage + tasks + deadlines → phone. Asserts its own coverage. |
| `scripts/nightly-journal.sh` | Distils the day's session transcripts → `logs/`. |
| `scripts/backup-context.sh` | git push + tarball the gitignored content. PII-gated. |
| `scripts/healthcheck.sh` | Tests all five properties. Run after any change. |
| `scripts/paseo-watchdog.sh` | Keeps the phone channel alive across reboots and crashes. |
| `scripts/install-permissions.sh` | Renders the policy into the layer that actually applies. |
| `scripts/sync-repos.sh` | Mirrors the owner's public repos so the agent can read code. |
| `scripts/cairn-on-mac-install.sh` | Puts the agent **on the laptop**, in the editor. |
| `systemd/crontab.txt` | **The schedule. Source of truth.** `crontab systemd/crontab.txt` |
| `docs/` | Permissions, integrations, architecture. |

## Quick start

```bash
cp example.env .env && $EDITOR .env       # secrets and paths. Never commit it.
./scripts/install-permissions.sh          # policy → the layer that applies at every cwd
crontab systemd/crontab.txt               # the schedule
./scripts/healthcheck.sh                  # PROVE it. Do not skip this.
```

## Credits

Architecture informed by a friend's personal-agent setup, and sharpened considerably by his
warning to put hard checks on persistent usage and runaway agent loops. He was right.
