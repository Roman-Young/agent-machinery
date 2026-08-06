# Build your own personal agent — the complete setup

A soup-to-nuts guide to standing up a personal AI agent like Kairo: a always-on Claude Code
instance on a small Linux server that reads a private, plain-markdown memory repo at the
start of every session, runs scheduled automations, pushes to your phone, coordinates a
fleet of sub-agents, and drives a logged-in browser for sites with no API.

Written for someone starting from nothing. Follow it top to bottom.

---

## 0. The one idea everything else serves

**The model is a commodity; the accumulated context about *you* is the durable value.**

Any capable LLM can write an email. What it can't do out of the box is write *your* email,
knowing your deadlines, your voice, your professor's name, and what you did yesterday. So
the whole system is built around a **private memory repository** — plain markdown, versioned
in git — that the agent reloads every session. The code in this repo is just the *machinery*
that points at that memory and runs it on a schedule.

Two repos, cleanly split:

| Repo | Visibility | Holds |
|---|---|---|
| `agent-machinery` | **public** (this one) | scripts, docs, CLAUDE.md instructions — **zero personal facts** |
| `my-context` (or `<you>-context`) | **private** | who you are, goals, logs, tasks, skills — your whole life |

This split is the load-bearing security decision. The template never knows the tenant. A
machine (`pii-scan.sh`) enforces it on every push, because a rule kept only by good
intentions gets broken once, at 1am, forever.

---

## 1. Prerequisites and mental model

```
   phone / laptop
        │  (Paseo app, or plain ssh)
        ▼
   ┌─────────────────────── SERVER (small Linux VPS) ───────────────────────┐
   │  Claude Code  ──reads every session──►  my-context/ (markdown memory)   │
   │       │                                                                  │
   │       ├── MCP servers: Gmail · Calendar · Drive · …  (read-only)         │
   │       ├── message bus (SQLite): coordinate a fleet of sub-agents         │
   │       ├── headless Chrome (CDP, loopback): login-walled sites, no API    │
   │       │                                                                  │
   │  cron ├──► morning-brief.sh   07:30  → ntfy → your phone                 │
   │       ├──► email-triage.sh    hourly → drafts + urgent pings            │
   │       ├──► nightly-journal.sh 01:45  → distils transcripts → logs/       │
   │       ├──► nightly-maintenance 02:00 → reconciles tasks vs the day's log │
   │       ├──► weekly-rollup.sh   Mon    → logs/weekly/ (middle memory tier) │
   │       ├──► backup-context.sh  02:15  → git push + tarball (PII-gated)    │
   │       ├──► canvas-sync.sh     3×/day → deadlines into the task system    │
   │       └──► paseo-watchdog.sh  @reboot + 10m → keeps the phone channel up │
   └──────────────────────────────────────────────────────────────────────────┘
```

You need:

- **A server.** A Hetzner CX33 (4 vCPU / 8 GB / 80 GB) is the reference box. Any Ubuntu LTS
  VPS with ≥8 GB works. **8 GB with no swap is the real constraint** — an overcommit is an
  instant OOM kill, so concurrency is capped low throughout.
- **A Claude subscription or API key** for headless (`claude -p`) runs.
- **A phone** with the [ntfy](https://ntfy.sh) app (free) — this is the notification channel.
- **A GitHub account** with two repos: one public (fork/clone this), one private (your memory).
- Optional but recommended: the **Paseo** app/CLI so you can talk to the agent from your
  phone without raw SSH.

---

## 2. Phase 0 — build the memory FIRST, on your laptop, before any server

The single most common way to get this wrong is to provision a server first. Don't. The
memory layer is the foundation and needs no server. Spend a few days here.

Create the **private** context repo with roughly this structure (see the "durable / live /
detail" split — it's what keeps session-startup cheap):

```
my-context/
  soul.md            # who the agent is — its identity and standing orders
  me.md              # who YOU are + the behavior contract (durable: no dates ever)
  goals.md           # long-horizon goals (durable)
  insights.md        # what the agent has LEARNED about you, with dated evidence
  current.md         # THE LIVE LAYER: this term/month, deadlines, open decisions
  projects-personal.md
  projects-work.md
  academics.md
  tasks.yaml         # SINGLE SOURCE OF TRUTH for to-dos + deadlines (structured)
  tasks.md           # GENERATED view of tasks.yaml — never hand-edit
  open-questions.md  # what the agent must ASK, never invent
  tools.md
  voice.md           # your writing voice — loaded before drafting any email
  skills/            # procedural memory: one file per reusable "how I do X"
    skills-index.md  # GENERATED routing table (name + ≤60-char description)
  reference/         # deep per-project briefings, loaded on demand
  courses/<term>/<course>/   # coursework, ephemeral, swept to archive/ when it ends
  logs/
    daily/YYYY-MM-DD.md      # raw episodic record — appended every day
    weekly/YYYY-Www.md       # distilled middle tier — one per week
  archive/           # ended things, distilled before deletion
  local-only/        # gitignored: health, finances, the bus DB — NEVER pushed
```

**The three memory tiers (this is the core design, copy it exactly):**

1. **Durable** (`soul.md`, `me.md`, `goals.md`, `insights.md`) — true for years. **Never
   write a date, deadline, or "right now" here.** `me.md` is your self-report; `insights.md`
   is the agent's evidence-based learning, and **every insight cites the dates it was
   observed**. One occurrence is a log entry; only a *recurrence* earns a promotion to
   `insights.md`.
2. **Live** (`current.md`) — true for weeks. The term, the schedule, hard deadlines. When it
   conflicts with a durable file on anything time-bound, **live wins**.
3. **Detail + on-demand** — `projects-*.md`, `reference/`, `courses/` — loaded only when a
   task touches them (progressive disclosure keeps startup cheap).

**The learning loop that makes it compound:**

```
observed in a session
  → logs/daily/YYYY-MM-DD.md      (always — the raw record)
  → logs/weekly/YYYY-Www.md       (Mondays, distilled — recurrence gets noticed here)
  → if it RECURS → insights.md     (durable, read every session — with your sign-off)
  → if reusable artifact → reference/ or skills/
  → when the source ENDS → archive/, promoting what's durable
```

Daily logs are read only ~3 deep, weeklies ~2 deep. Anything left further back is
functionally forgotten — so a lesson **has to be promoted to survive**. That promotion
ladder is the entire point of the system.

**The behavior contract in `me.md`** is where your personality preferences live — how blunt
to be, when to teach vs. just answer, "propose and wait, never act unilaterally," etc. This
is what makes the agent *yours* rather than generic.

Now write `CLAUDE.md` (the agent's standing instructions) and symlink it into the context
repo so any session started there picks it up. Have a few real conversations. Only when the
memory feels load-bearing do you provision hardware.

---

## 3. Phase 1 — provision the server

```bash
# On the VPS, first login as root:
adduser <you> && usermod -aG sudo <you>
# /etc/ssh/sshd_config:  PermitRootLogin no   PasswordAuthentication no
sudo apt update && sudo apt upgrade -y
sudo ufw allow OpenSSH && sudo ufw enable
```

Add your SSH **public** key at machine-creation time; disable root login and password auth
immediately. The firewall allows only SSH — nothing else needs a public port (the browser's
debug port is loopback-only, see §9).

Install the runtime:

```bash
# Claude Code — follow current official instructions:
#   https://docs.claude.com/en/docs/claude-code/overview
claude setup-token        # subscription auth for headless runs
#   ...or put ANTHROPIC_API_KEY in .env for API billing
```

Optionally install the **Paseo** CLI and pair it with your phone, so you can reach the agent
without raw SSH. This becomes your primary interface — you text the agent like a person.

---

## 4. Phase 2 — clone the repos and configure

```bash
mkdir -p ~/agent && cd ~/agent
git clone git@github.com:YOU/my-context.git        # -> ~/agent/my-context   (private)
git clone git@github.com:YOU/agent-machinery.git   # -> ~/agent/agent-machinery (public)
```

> ⚠️ **Both repos must live inside one workspace dir (`~/agent`).** If the context repo is
> outside the workspace, writes to it hit permission friction on every run.

Point sessions at the instructions by symlinking `CLAUDE.md` into the context repo (and
gitignore the symlink so it isn't tracked):

```bash
ln -s ~/agent/agent-machinery/CLAUDE.md ~/agent/my-context/CLAUDE.md
echo 'CLAUDE.md' >> ~/agent/my-context/.gitignore
```

Fill in secrets and paths:

```bash
cd ~/agent/agent-machinery
cp example.env .env && $EDITOR .env     # gitignored — NEVER commit the real one
```

`.env` holds **secrets and paths only — never policy or tool allowlists.** (History lesson:
`.env` once defined a tool allowlist and silently stripped Gmail from the morning brief,
which then cheerfully reported "0 threads found." Each job script exports its own
least-privilege tools; `run-agent.sh` makes the caller win over `.env`.) Key vars:

- `CONTEXT_DIR` — the context **repo itself** (not its parent).
- `WORKSPACE_DIR` — the dir containing both repos.
- `NTFY_URL` / `NTFY_TOPIC` — **required.** Without a phone channel a failing job fails
  *silently*, the single most dangerous state. The topic is a de-facto secret (anyone who
  knows it can read your briefs) — make it long and random. Optional `NTFY_TOPIC_URGENT` /
  `NTFY_TOPIC_FYI` give you three priority tiers so "backup failed" and "task added" don't
  buzz identically.
- The **guardrail** vars (see §7): `AGENT_MAX_TURNS`, `AGENT_TIMEOUT_SEC`,
  `AGENT_MAX_RUNS_PER_DAY`, `AGENT_MAX_CONCURRENT`.
- `GITHUB_USER` (public repos need no token). A token is needed **only for private repos**,
  and if you use one it must be **read-only** and **"only select repositories"** — never an
  all-repo token. The agent reads untrusted email/web while holding a shell; every token it
  carries is blast radius.

Install and prove:

```bash
./scripts/install-permissions.sh     # render the policy into the layer that ACTUALLY applies
crontab systemd/crontab.txt          # the schedule (source of truth)
./scripts/healthcheck.sh             # PROVE it — do not skip this
```

---

## 5. Phase 3 — the phone channel (ntfy / "the Notify app")

1. Install the **ntfy** app on your phone (iOS/Android, free).
2. Pick a long random topic string; put it in `.env` as `NTFY_TOPIC`. Subscribe the app to
   it. (Optionally a second `..._FYI` topic set to silent, and a `..._URGENT` topic set to
   max priority.)
3. You can self-host ntfy in Docker later if you don't want to use the public `ntfy.sh`, but
   the public server is fine to start — the topic is your only secret.

Everything notifies through **one helper**, `scripts/notify.sh <urgent|alert|fyi> <title>
<msg>`, so ntfy config is verified in exactly one place and any script (or you, from the
shell) can push. **A sent notification is not a received one** — test the real push, not a
proxy for it.

---

## 6. Phase 4 — the scheduled automations (cron, not systemd)

**Use cron.** systemd *user* timers only run while you have an active login unless you set up
lingering (needs sudo); cron needs neither. The schedule lives in `systemd/crontab.txt` —
install with `crontab systemd/crontab.txt`. Two things silently kill cron jobs and both are
handled in that file:

- **`CRON_TZ`** — the server is almost certainly UTC; without it a "07:30" brief fires at
  00:30 local.
- **`PATH`** — cron starts nearly empty; without it `claude` is simply *not found* and the
  job fails silently every day.

> **Never run cron and systemd timers for the same jobs — every job fires twice.**

The jobs, and what each does:

| Job | When | Does |
|---|---|---|
| `morning-brief.sh` | 07:30 | Email triage + tasks + deadlines → phone. **Asserts its own coverage.** |
| `email-triage.sh` | hourly (7–23) | Summarize inbox, draft replies (**never sends**), ping on anything urgent. |
| `nightly-journal.sh` | 01:45 | Distils the day's session transcripts into `logs/daily/`. |
| `nightly-maintenance.sh` | 02:00 | Reconciles the day's log against the task list; auto-closes only on unambiguous evidence, flags the rest. |
| `weekly-rollup.sh` | Mon 03:30 | Distils a finished week's dailies into `logs/weekly/`. |
| `backup-context.sh` | 02:15 | `git push` + tarball the gitignored content. **PII-gated.** |
| `daily-rollover.sh` | 03:00 | Archives + purges old raw transcripts (their content is already distilled). |
| `canvas-sync.sh` | 3×/day | Pulls deadlines from a login-walled site into the task system (§9). |
| `paseo-watchdog.sh` | @reboot + /10m | Keeps the phone/chat channel alive across reboots. |
| `healthcheck.sh` | weekly | Tests all five properties (§7). |

---

## 7. The five properties — the discipline that keeps it from rotting

This is the hardest-won part of the whole system. It came from an audit that found a setup
reporting **20/20 healthy** was simultaneously one reboot from losing its phone channel, had
*never once* run its backup, had zero protection against a runaway loop, and was one
`git push` from publishing colleagues' emails. **None of it was visible from reading the
code; all of it was obvious within a minute of running it.**

`scripts/healthcheck.sh` tests all five. **Passing one tells you nothing about the others:**

1. **Liveness** — does it work *right now*? (The easy one, the only one people remember.)
2. **Durability** — will it survive a *reboot*? "It's running" is not "it will still be
   running." Anything hand-started with no supervisor is one power-cycle from gone.
3. **Recoverability** — does it survive the *server dying*? A backup that has never run is
   not a backup, it's a comment. If the box died right now, what is gone forever?
4. **Boundedness** — can it *run away*? An agent that calls itself, on a timer, with a card
   attached, is a machine for burning money while you sleep. Must be bounded in **time,
   concurrency, and frequency** — any one unbounded is an unbounded bill.
5. **Publishability** — is it *safe to push*? Git history is forever; a force-push after the
   fact does not un-ring the bell.

**Three rules underneath them:**

- **Run it, don't reason about it.** Every bug this system had was invisible on read and
  obvious on run — including a bug in the healthcheck, which the healthcheck caught.
- **Cross-reference; config lies in the gaps between files.** The nastiest bugs lived in the
  *disagreement* between two internally-consistent files (a unit pointing at the wrong path;
  a committed policy vs. the *loaded* policy). A file being correct means nothing; two files
  agreeing means something.
- **Assert coverage, never infer it.** A job that can't reach Gmail says "0 threads found,"
  indistinguishable from an empty inbox and far more dangerous. So the job must **declare**
  what it reached (`SOURCES: gmail=ok`) and **the script — not the model — checks the
  declaration.**

`scripts/run-agent.sh` is the **single choke point** every headless run passes through, so no
job can forget a guard: `flock` (one instance per job), a hard **timeout** (`claude -p` can
hang), a **circuit breaker** (max runs/day — the one that catches a real runaway loop), a
**turn cap**, and **fail-loud** (every failure pushes to your phone).

The change procedure, every time:

```bash
$EDITOR agent-machinery/.claude/settings.json   # 1. edit the VERSIONED policy
./scripts/install-permissions.sh                # 2. render it where it APPLIES
./scripts/healthcheck.sh                        # 3. PROVE it — step 3 is NOT optional
```

---

## 8. The security model (read before adding any capability)

- **Broad Bash interactively; ZERO Bash on any job that reads untrusted input.** The agent
  ingests email and web pages — *untrusted input + shell access* is the entire prompt-
  injection threat model. The morning brief gets `Read`/`Grep`/Gmail(read)/Calendar(read)
  and **no shell**, so "malicious email → shell command" simply does not exist. **Never add
  Bash to a job that reads email or fetches web content.**
- **Every credential is read-only by construction.** Worst case is disclosure, never
  destruction.
- **Draft, never send** — enforced by *withholding the send tool*, not by a policy string.
  Every irreversible/outward/spending action pauses and surfaces the exact artifact for your
  approval. Approve a concrete thing, never an intention.
- **`settings.local.json` is reset to empty on every install.** It silently auto-appends a
  rule each time you click "always allow," and nobody re-reads it — it had twice quietly
  widened permissions, once to the SSH keys. The versioned `settings.json` is the real
  policy.
- **`pii-scan.sh` gates the nightly push.** The public repo refuses to publish if an email
  address or server IP appears. And note the honest caveat: **redacting a file does not
  redact git history** — anything already pushed is still in the history.

**Data minimisation** (a deliberate choice, not laziness): store what you need to *act on*,
not what you happen to find interesting. Every sensitive fact is written in three places
(server, private GitHub, laptop mirror), so the test before recording anything is not "is
this true?" but **"what would I do differently if I knew this? If nothing — don't store it."**
Home address, phone number: no. Health/finances/relationships: `local-only/`, gitignored,
never pushed.

---

## 9. The browser agent — acting on login-walled sites with no API

Some sites (a university LMS, etc.) bar API tokens and give only a dates-only calendar feed.
The route: a **persistent, logged-in headless Chrome** on the server holds the real SSO
session; you then call the *site's own JSON API from inside that session* (the session cookie
authenticates it) — structured JSON, immune to page-layout changes, no HTML scraping.

**The hard part is AUTH, not reading.** Setup:

1. One-time human login: open an SSH tunnel to the loopback CDP port, drive the remote Chrome
   from your laptop's `chrome://inspect`, log in, approve 2FA, tick "remember this device."
2. The session lives in a persistent Chrome profile; a script pulls data over CDP.
3. Expect a ~2-minute re-auth roughly weekly (2FA "remember" windows expire); the sync
   detects the lapse and pushes you the re-login command.

Worked example in this repo (Canvas): `canvas-chrome.sh` (keeps Chrome up, boot + every
10 min), `canvas-login.sh` (prints the re-auth checklist), `canvas-fetch.py` (the *only*
web-toucher, read-only, over CDP), `canvas-sync.py` (deterministic LLM-free merge into
`tasks.yaml`), `canvas-sync.sh` (orchestrator, asserts `SOURCES: canvas=ok`).

**Non-negotiable rules:**

- **The CDP debug port binds `127.0.0.1` only**, reached solely over the SSH tunnel. An open
  CDP port is unauthenticated RCE. **Never** `--remote-debugging-address=0.0.0.0`.
- **Trust boundary:** the browser ingests untrusted web content, so it never shares a
  privilege context with a shell or an edit-capable LLM. The reader only reads; the writer is
  deterministic Python that never touches the network.
- **Irreversible/outward/spending actions are never autonomous** — read and prepare freely,
  but any purchase/booking/submit/send pauses and surfaces the exact action for approval.
- **Gotcha:** a `--headless` Chrome's UA contains `HeadlessChrome`, which some 2FA providers
  block; the launcher spoofs a normal `Chrome/…` UA. Don't remove it.

Per-site playbooks accumulate as `skills/browser/<host>/` files, so the capability compounds.

---

## 10. The multi-agent message bus — running a fleet without becoming the glue

When a job is big enough to want several agents at once (a research sweep, a batch migration,
parallel audits), don't open N chats and hold the whole picture in your head. The problem:
separate chats and headless agents **cannot talk to each other** — each is its own context.
The bus is a shared **SQLite** store every agent writes to (under a thread id) and reads on
every write, so one seat sees and steers the whole fleet.

The org model: **owner = CEO, orchestrator chat = CTO, spawned workers = headless, read-only,
one-milestone-then-stop.** The loop (`scripts/bus.py` + `scripts/spawn-agent.sh`):

1. `bus.py spawn --title … --prompt "the brief"` → opens a thread, prints its id.
2. `spawn-agent.sh <id> --tools "Read,Glob,Grep,WebSearch" --label …` → staffs **one**
   milestone, then the worker STOPS and the thread pauses for approval.
3. Review (`bus.py read <id>`), approve (`bus.py write <id> --kind override --by you "…"`),
   re-run to continue.
4. `bus.py render` regenerates a glanceable board; `bus.py watch --all` is the live terminal
   view. A blocked worker pulls you in via a `needs_input` → ntfy push instead of guessing.

**Hard constraints:**

- **Trust boundary:** workers get **no Bash and no send/draft tool** (`spawn-agent.sh`
  refuses them). The wrapper is the only thing that writes to the bus, so untrusted text
  never becomes a bus write except through it.
- **Orchestrator-only spawning:** a worker can't spawn workers (keep it gated).
- **Concurrency:** on an 8 GB box with no swap, hold **3–4 workers max**; run bigger sweeps in
  waves and watch `free -m` at peak. An overcommit is an instant OOM kill.
- **Model tiering:** workers default to the cheap tier; escalate to the deep tier only for
  hard synthesis/design/review milestones.
- **Guards inherited:** every milestone is a fresh `run-agent.sh` run — flock, timeout,
  circuit breaker, all of it.
- The bus DB lives in `local-only/` (gitignored but inside the backup tarball) — message
  content is personal/untrusted-origin and never reaches GitHub. Its protection is its
  *location*, so it must never move out of `local-only/`.

---

## 11. Two-machine setup (optional): the agent in your editor too

You can run a second instance of the agent **inside your laptop's editor** (VS Code /
JetBrains), so it can touch your code natively. The division is clean — **the two share files
but never talk**, and there is exactly **one writer**:

- **The server owns memory.** The laptop's copy is read-only, overwritten every few minutes
  by rsync (down).
- **The laptop owns code.** Code never leaves the laptop; the server doesn't try to read it.
  (If the server ever needs *published* code, it does a small internal git pull — see
  `sync-repos.sh`.)
- **The server learns your work from your transcripts** → nightly journal → log. That's the
  single channel by which "what you did in the editor" becomes something the server knows.
- The editor instance never writes memory directly; it *requests* changes via an outbox the
  server processes.

Two writers to one store means silent divergence, so memory has exactly one writer (the
server). `cairo-on-mac-install.sh` is the reference installer for the editor side.

---

## 12. Repo map — where everything is

| Path | What |
|---|---|
| `CLAUDE.md` | Agent instructions. References context *files*, never personal facts. |
| `example.env` | Every configurable var, heavily commented. Copy to `.env`. |
| `scripts/run-agent.sh` | The choke point: env, least-privilege tools, all five guards. |
| `scripts/notify.sh` | The one ntfy push helper (3 tiers). |
| `scripts/morning-brief.sh` | Email triage + tasks + deadlines → phone. Asserts coverage. |
| `scripts/email-triage.sh` | Hourly inbox summarize + draft (never send). |
| `scripts/nightly-journal.sh` | Distils transcripts → `logs/`. |
| `scripts/nightly-maintenance.sh` | Reconciles the day's log against the task list. |
| `scripts/weekly-rollup.sh` | Distils a week's dailies → `logs/weekly/`. |
| `scripts/backup-context.sh` | git push + tarball, PII-gated. |
| `scripts/healthcheck.sh` | Tests all five properties. Run after any change. |
| `scripts/paseo-watchdog.sh` | Keeps the phone channel alive across reboots. |
| `scripts/render-tasks.py` | `tasks.yaml` → `tasks.md` (sorted, overdue computed mechanically). |
| `scripts/render-skills.py` | `skills/*.md` → `skills-index.md` routing table. |
| `scripts/pii-scan.sh` | Gates the nightly push against leaking PII/IP. |
| `scripts/bus.py`, `scripts/spawn-agent.sh` | The multi-agent message bus + worker wrapper. |
| `scripts/canvas-*` | The browser-agent worked example. |
| `scripts/sync-repos.sh` | Mirrors your public repos so the agent can read code. |
| `scripts/cairo-on-mac-install.sh` | Puts the agent in the laptop editor. |
| `systemd/crontab.txt` | **The schedule. Source of truth.** `crontab systemd/crontab.txt` |
| `docs/architecture.md` | The five properties + the discipline, in full. |
| `docs/message-bus.md` | Full bus design. |
| `docs/canvas-access.md` | Full browser-agent design. |
| `docs/permissions.md` | The permission model. |

---

## 13. Build order — the checklist

1. **Memory first, on your laptop.** Write `me.md`, `soul.md`, `goals.md`, `current.md`,
   seed `tasks.yaml`. Have real sessions. Don't touch a server yet.
2. **Provision** the VPS: non-root user, SSH keys only, firewall, upgrade.
3. **Install** Claude Code + auth for headless; optionally Paseo.
4. **Clone both repos** into one `~/agent` workspace; symlink `CLAUDE.md`; fill `.env`.
5. **Phone channel:** ntfy app + a long random topic. Test a real push.
6. `install-permissions.sh` → `crontab systemd/crontab.txt` → **`healthcheck.sh`** (prove it).
7. Smoke-test `morning-brief.sh` by hand; confirm from the *log* it actually used your context.
8. Add capabilities **only when the pain arrives** — task tracking → syllabus/deadline sync →
   email triage → the bus → the browser agent. Each earns its place only when the prior layer
   is solid and proven green.

**The one rule to tattoo on the wall:** *a green healthcheck is evidence; "I read the code
and it looks right" is not.* Run it, don't reason about it.
