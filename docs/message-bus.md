# The agent message bus

Built 2026-07-20. Phase 1 (the foundation) and Phase 2 (milestone-gated spawning) are both
live and verified. Further loosening (auto-continuation, workers spawning sub-agents) stays
gated behind its own approval.

## Why it exists

The goal is a small multi-agent org: **owner = CEO, Kairo = CTO/orchestrator, deep-work
agents = managers, sub-agents = workers.** The hard problem is that separate chats and
headless agents **cannot talk to each other** — each is its own context. So without a
shared store, running several at once means the *human* becomes the glue, tab-switching
across N blind windows, holding the whole picture in their head. That is the exact problem
this system exists to remove.

The bus is that shared store. Every agent writes what it's doing to one table (under a
thread id) and reads on every write, so:

- the **orchestrator sees the whole fleet** in one place (`bus.py watch`);
- **steering flows both ways** — the owner or orchestrator writes a correction, the agent
  picks it up on its next read;
- a blocked agent **pulls a human in** (`needs_input` → an ntfy push) instead of guessing
  or stalling silently.

## Storage, and two deliberate departures from the rules

- **One SQLite file at `$CONTEXT_DIR/local-only/agent_bus.db`** (override with `BUS_DB`).
  This location is load-bearing: `local-only/` is gitignored *and* inside the nightly
  backup tarball, so message content never reaches GitHub (even the private repo) yet is
  still backed up. **It must never move out of `local-only/`.** The PII gate uses
  `grep -I` and skips binaries, so the DB's only protection is its *location*, not the gate.

- **Departure 1 — multi-writer** (the exception to architecture Rule 5, "one writer").
  The *memory* layer keeps the one-writer rule. The bus is a **separate coordination
  store**, made safe by WAL + `busy_timeout` + **append-only messages** (every write is an
  INSERT; rows are never mutated, so there is no update race). Per-thread `seq` is assigned
  inside a `BEGIN IMMEDIATE` transaction, so two concurrent writers can never collide.

- **Departure 2 — the trust boundary** (see Security below).

## Schema (`PRAGMA user_version = 1`)

- **`threads`** — one row per unit of work: `id`, `title`, `project`, `created_by`,
  `parent_id` (the 4-level hierarchy: a sub-agent references its manager thread; NULL =
  top-level), `status` (`open|working|blocked|needs_input|done|killed`), `created_at`,
  `updated_at`.
- **`messages`** — the append-only event log: `id`, `thread_id`, `seq` (per-thread
  monotonic, enables `read --since N`), `sender`, `kind`, `body`, `needs_input`,
  `created_at`.
- `kind` ∈ `prompt · milestone · decision · uncertainty · question · completion · override
  · note`. A partial index on `needs_input=1` makes "who's waiting?" a cheap poll.

Timestamps are Pacific (`OWNER_TZ`), matching `render-tasks.py`. `user_version` is the
migration marker for the eventual Postgres+pgvector move (`setup/server-setup.md`
anticipates it; the append-only schema stays portable).

## The CLI — `scripts/bus.py` (stdlib only, path-free)

```
bus.py init                                     # create DB + schema (idempotent)
bus.py spawn --title T --project P --prompt "…" # new thread + initial prompt -> prints id
bus.py read  <id> [--since N] [--json]          # an agent's brief + any new steering
bus.py write <id> --kind K --by WHO [--needs-input] "body"
bus.py watch [--all]                            # dashboard: threads, status, who's waiting
bus.py status <id> --set <state>
bus.py snapshot <path>                          # VACUUM INTO a consistent copy (for backup)
```

`write --needs-input` shells out to `notify.sh alert` (reuse, don't reimplement ntfy) and
flips the thread to `needs_input`. `write --kind completion` flips it to `done`; `override`
flips it back to `working`. The bus resolves `BUS_DB` from the env or the `CONTEXT_DIR`
default, so it works whether or not `.env` is sourced (an agent may call it directly).

## The five properties (architecture.md compliance)

1. **Liveness** — the healthcheck round-trips a real `spawn→write→read` against a *scratch*
   DB (never polluting the live bus), plus an integrity check on the live DB.
2. **Durability** — WAL survives a crash mid-write. **No daemon in Phase 1**, so there is
   nothing to die on reboot; `init` is idempotent.
3. **Recoverability** — `backup-context.sh` runs `bus.py snapshot` into `local-only/` before
   the nightly tar, so the tarball holds a *consistent* copy (a live SQLite file tarred
   mid-write would be torn). The healthcheck asserts the snapshot is fresh.
4. **Boundedness** — Phase 1 has no self-calling/timer, so the bus can't run away; the
   healthcheck caps row-count and file size so a buggy writer is caught early. The real
   boundedness work is Phase 2.
5. **Publishability** — the healthcheck asserts the DB is gitignored **and** untracked.

## Security — the bus is a new trust boundary

An agent that read email or a web page can write that **untrusted-origin** content to the
bus; a *Bash-enabled* reader of the bus is then a prompt-injection surface. This is the
same threat the permissions model is built around ("**never add Bash to a job that ingests
untrusted content**").

- **Phase 1 risk is low:** writers and readers are humans + the interactive orchestrator,
  with the owner watching.
- **Phase 2 mitigations (designed):** an agent that ingests untrusted input gets **no Bash**
  (existing rule); messages will carry a `trust` tag so a shell-enabled reader treats
  flagged content as *data, not instructions*; the orchestrator mediates rather than piping
  raw untrusted text between agents.

## Phase 2 — milestone-gated spawning (BUILT + verified 2026-07-20)

`spawn-agent.sh <thread-id> [--tools …] [--label …] [--dir …]` runs ONE milestone of a
deep-work agent for a thread, then stops. Two calls shaped it: **manual continuation**
(nothing continues without approval) and **orchestrator-only** (only Kairo spawns; a worker
can't spawn workers).

**The loop:**
1. `spawn-agent.sh <id>` reads the thread from the bus, injects its brief + full history +
   any steering into a focused worker prompt, and launches it through `run-agent.sh`.
2. The worker does ONE coherent chunk and ends its output with a status line —
   `<<BUS milestone>>`, `<<BUS needs_input>>`, `<<BUS blocked>>`, or `<<BUS done>>`.
3. The **wrapper** (not the worker) parses that line, writes the matching message to the
   bus, flips the thread status, and fires the right ntfy tier (fyi for milestone/done,
   alert for needs_input/blocked). Then it exits.
4. On a milestone the thread goes to `needs_input` (**paused**). To continue, Kairo writes
   an `override` (your approval) and re-runs `spawn-agent.sh <id>`; the worker reads the
   updated thread (prior work + the override) and does the next chunk.

**Bounded three ways** — nothing can bypass a guard:
- every milestone is a fresh `run-agent.sh` run → inherits flock (per-thread), timeout,
  circuit-breaker, `--max-turns`, fail-loud;
- a **global concurrency semaphore** (flock slots in `~/.agent-logs/state/`, cap
  `AGENT_MAX_CONCURRENT`, default 2) caps the TOTAL running — the existing flock is
  per-job-name only;
- state lives in the bus, so nothing sits blocked holding RAM.

**Trust boundary — workers have no shell.** `spawn-agent.sh` refuses any `--tools`
containing Bash or a send/draft tool. Workers Read/Edit/Write (code, absolute paths) or use
read-only connectors, and cannot push/commit/send. The trusted wrapper is the *only* thing
that writes to the bus — so content an agent ingested never reaches a shell, and never
becomes a bus write except through us.

**Verified 2026-07-20:** a worker did real file work and reported through the wrapper with
no shell; a multi-step task PAUSED after one milestone (`needs_input`), and after an
`override` approval, continued — reading its prior work + the steering, adding the next
piece without redoing the first.

**How Kairo uses it** (on your word):
```bash
python3 scripts/bus.py spawn --title "…" --project X --by cairo --prompt "the brief"
scripts/spawn-agent.sh <id> --tools "Read,Glob,Grep,Edit,Write" --label worker-1 --dir /abs/project
# you review the milestone; on approval:
python3 scripts/bus.py write <id> --kind override --by roman "continue" && scripts/spawn-agent.sh <id> --tools … --label worker-1
```

**Still deliberately NOT built** (each its own approval): auto-continuation (a cron sweep),
workers spawning sub-agents (the 4th level), and a `trust` tag on messages.

## Expansion roadmap

- **Dashboard:** `bus.py render` → a deterministic `bus.md` view (like `tasks.md`), or a
  terminal viewer.
- **Cross-machine:** VS Code Remote-SSH chats hit the bus directly (same box); a Mac-local
  chat bridges via the existing outbox pattern.
- **Task-system tie-in:** a `done` thread closes/creates a `tasks.yaml` task; spawn a thread
  *from* a task.
- **Cost/token accounting per thread** → a real spend budget (boundedness beyond run-counts).
- **Learning loop:** the append-only log is a full record of agent work → mineable into
  `insights.md`.
- **Inter-agent bridge:** the bus as the protocol for connecting to another owner's agent.
- **Phone round-trip steering:** `needs_input` push → owner replies → reply written back as
  an `override`.

## Quick reference for a chat/agent using the bus

```bash
# start a unit of work
TID=$(python3 scripts/bus.py spawn --title "email triage pass" --project email --by cairo \
        --prompt "Triage today's inbox; propose labels + drafts; do not send.")
# report progress / ask
python3 scripts/bus.py write "$TID" --kind milestone --by fable-1 "Classified 40 threads."
python3 scripts/bus.py write "$TID" --kind question  --by fable-1 --needs-input "Archive the 12 newsletters?"
# the orchestrator watches + steers
python3 scripts/bus.py watch
python3 scripts/bus.py write "$TID" --kind override --by roman "Yes, archive them."
```
