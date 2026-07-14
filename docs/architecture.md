# Architecture — and the discipline that keeps it from rotting

Written after the 2026-07-14 audit, which found that a system reporting **20/20 healthy**
was one reboot from losing its phone channel, had never once run its own backup, had no
protection against a runaway loop, and was one `git push` away from publishing five
colleagues' email addresses.

None of that was visible from reading the code. All of it was obvious within a minute of
running it. **That is the lesson this document exists to encode.**

---

## Part 1 — The five properties

Every failure in this system came from confusing one of these questions for another.
**Passing one tells you nothing about the others.** `scripts/healthcheck.sh` tests all five.

### 1. LIVENESS — *does it work right now?*
The easy one, and the only one anyone remembers to test.

### 2. DURABILITY — *will it still work after a reboot or a crash?*
> **"It's running" is not "it will still be running."**

Paseo — the phone channel, the entire reason the agent is reachable — was started **by
hand**. No systemd unit, no cron entry, an orphaned supervisor with its argv rewritten. A
reboot would have killed it permanently, leaving SSH as the only way back to the agent:
*precisely the thing the system exists to avoid.* It was healthy, and it was one power-cycle
from gone.

**Test:** would this survive `reboot`? If you can't answer yes, it isn't installed — it's
just *running*.

### 3. RECOVERABILITY — *does it survive the server dying?*
> **A backup that has never run is not a backup. It's a comment.**

25 commits — the entire memory layer, every insight, the whole task system — existed on one
Hetzner box, with a 2-day-stale copy on GitHub. `backup-context.sh` had **never executed**:
no cron entry, no `~/backups` directory. It would also have *failed* if run, because it
called `git push`, which is permission-gated, which in a headless run means denied.

The system built so that nothing gets lost was itself unbacked.

**Test:** if this box died right now, what is gone forever?

### 4. BOUNDEDNESS — *can it run away?*
> **An agent that calls itself, on a timer, with a card attached, is a machine for burning
> money while you sleep.**

Dan warned about exactly this — *persistent usage, infinite cycles with agent calls* — and
he was right: there were **zero** guards. No timeout (a hung `claude -p` waits forever). No
lock (tomorrow's run stacks on today's hang, and on an 8GB box a few of those *is* the box).
No rate cap (a bad loop bills you until someone notices).

**A scheduled agent must be bounded in TIME, in CONCURRENCY, and in FREQUENCY.**
Any one left unbounded is an unbounded bill. All three now live in `run-agent.sh` — the
single choke point every headless run passes through, so no job can forget one.

### 5. PUBLISHABILITY — *is it safe to push?*
> **Git history is forever. A force-push after the fact does not un-ring that bell.**

`agent-machinery` is a **public** repo whose own CLAUDE.md says *"never hardcode paths or
personal facts."* It had nonetheless accumulated the server's public IP and login, all five
of the owner's email addresses, and **five colleagues' work emails** — which is not his
privacy to spend.

Caught with one command to spare. `pii-scan.sh` now gates the nightly push automatically,
because a rule enforced only by good intentions is a rule that will be broken at 1am.

---

## Part 2 — The discipline

### Rule 1: Run it. Don't reason about it.

**Every bug found in this system was invisible on read and obvious on run.** Not most. All:

| Bug | Looked fine on read? | Caught by |
|---|---|---|
| systemd `ExecStart` pointed at a directory that didn't exist | ✅ yes | firing the unit |
| Timers in UTC → the "morning" brief would fire at 00:30 | ✅ yes | reading the *next-fire time* |
| `.env` silently clobbered the job's tool allowlist | ✅ yes | the brief reporting "0 threads" |
| `run-agent.sh` never wrote stdout → coverage check tested `""` | ✅ yes | a false DEGRADED alert |
| Journal shelled out to `find`, which the policy denies | ✅ yes | test-firing it |
| A 123-line permission policy that governed **nothing** | ✅ yes | asking *which* file is in force |
| The healthcheck's own arithmetic bug | ✅ yes | the healthcheck running |

That last row is the whole point: **the healthcheck caught a bug in the healthcheck.**
Executable checks find what careful reading cannot — because reading tests what you *believe*
the system does, and running tests what it *actually* does.

### Rule 2: Cross-reference. Config lies in the gaps between files.

The nastiest bugs were never *inside* a file. They lived in the **disagreement between two
files that never met**:

- The unit file said `~/agent-machinery`. The repo was at `~/agent/agent-machinery`. Each
  was internally consistent. Together they were broken.
- The policy file allowed `Bash(find:*)`. The *loaded* policy — a different file — said
  nothing at all. Both were valid JSON.
- `example.env` documented `GITHUB_REPOS`. The script read `GITHUB_PRIVATE_REPOS`. The
  documented variable did nothing.

**So the healthcheck cross-references rather than inspects:** every path cron invokes must
exist *and* be executable. The policy that is *loaded* must contain the rule — not the one
that is merely *committed*. The scheduler that is *enabled* must be the only one.

> **A file being correct means nothing. Two files agreeing means something.**

### Rule 3: Assert coverage; never infer it.

A headless job that cannot reach Gmail does not say *"I was blocked."* It says
**"0 threads found."** Indistinguishable from an empty inbox — and far more dangerous,
because the owner trusts it and *stops checking*.

So the brief must **declare** what it reached (`SOURCES: gmail=ok`), and **the script — not
the model — verifies the declaration.** No `gmail=ok`, no brief: an alert instead.

> **The model asserting success is not evidence. The script checking the assertion is.**

Generalised: *a sent notification is not a received one.* *A deploy key that passes `ssh -T`
is not a key that can push.* **Test the real operation, never a proxy for it.**

### Rule 4: Fail loud, and fail recoverable.

`paseo-watchdog.sh` is the pattern for anything you cannot fully verify. Nobody knows Paseo's
canonical start command — its supervisor is orphaned and self-renamed. So the watchdog is
built to be **correct even when its guess is wrong**:

1. **It never touches a live daemon.** If Paseo is up, it exits immediately — so the watchdog
   can never cause the outage it exists to prevent. (This is also why it was safe to write
   and test mid-session.)
2. If Paseo is down, it tries to start it.
3. **Either way it reports.** Success → a push. Failure → a loud push with the exact command
   to run. You are never silently stranded.

> **A system you cannot fully verify should still fail loudly and recoverably. That is worth
> more than a confident guess.**

### Rule 5: One writer. Always.

Two Cairns exist — one on the server, one in the laptop's editor. They **share files**; they
do not talk.

```
        MAC (VS Code)                          SERVER (Hetzner)
   ┌─────────────────────┐              ┌─────────────────────┐
   │  Cairn              │              │  Cairn              │
   │  ~/.claude/CLAUDE.md│              │  agent-machinery/   │
   │                     │              │                     │
   │  OWNS: code    ✍    │              │  OWNS: memory  ✍    │
   │  reads: memory 👁    │              │  reads: code   👁    │
   │                     │              │                     │
   │  live/uncommitted   │              │  email, calendar,   │
   │  files, the editor  │              │  cron, brief,       │
   │                     │              │  journal, phone     │
   └──────────┬──────────┘              └──────────┬──────────┘
              │   memory  ◀──── rsync ─────────────┤  (server → Mac, 5 min)
              │   transcripts ──── rsync ─────────▶│  (Mac → server, 5 min)
              │   code        ──── rsync ─────────▶│  (Mac → server, 5 min)
              └────────────────────────────────────┘
```

- **The server owns memory.** The laptop's mirror is read-only, overwritten every 5 minutes.
- **The laptop owns code.** The server's mirror is read-only; it proposes *diffs*.

Two writers to one store means silent divergence, and a memory you cannot trust is worse than
no memory at all. Learning from the laptop flows back through **transcripts → nightly journal
→ log**: the loop still closes, it just closes through the single writer, on purpose.

### Rule 6: The template must not know the tenant.

`agent-machinery` is public; `my-context` is private. **Personal facts belong in the private
repo, or in `.env`, and nowhere else.** The public script says *"read the context for who
matters"*; the private context holds *who matters*.

Enforced by a machine (`pii-scan.sh`, nightly, before any push) — because a convention held
only by discipline is a convention that will lose, once, at 1am, forever.

---

## Part 3 — What to do when you change something

```bash
$EDITOR agent-machinery/.claude/settings.json   # 1. edit the VERSIONED policy
./scripts/install-permissions.sh                # 2. render it where it APPLIES
./scripts/healthcheck.sh                        # 3. PROVE it — all five properties
```

**Step 3 is not optional.** Every bug in this system came from skipping it.
