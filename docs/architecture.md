# Where Cairn runs — two bodies, one memory

## The problem

Roman's code is on his Mac. Cairn's memory is on the server. Neither machine had both, so
neither was actually the agent he wanted:

- **Mac-Claude** saw all his code and knew nothing about him.
- **Server-Cairn** knew everything about him and couldn't see a line of his code.

The single most damaging consequence: **the Claude converting his Python to Rust — for a
paper he is first-authoring — had no idea Rust was high-stakes for him**, or that his own
thesis is that unearned fluency is a liability. It just wrote the Rust and handed it over.

## The fix: Cairn runs in BOTH places, and each owns one thing

```
        MAC (VS Code)                          SERVER (Hetzner)
   ┌────────────────────┐                 ┌────────────────────┐
   │  Cairn             │                 │  Cairn             │
   │  ~/.claude/CLAUDE.md│                │  agent-machinery/  │
   │                    │                 │                    │
   │  OWNS: code ✍      │                 │  OWNS: memory ✍    │
   │  reads: memory 👁   │                 │  reads: code 👁     │
   │                    │                 │                    │
   │  live/uncommitted  │                 │  email, calendar,  │
   │  files, VS Code    │                 │  cron, brief,      │
   │                    │                 │  journal, phone    │
   └─────────┬──────────┘                 └─────────┬──────────┘
             │                                      │
             │  memory mirror  ◀────── rsync ───────┤  (server → Mac, every 5 min)
             │  transcripts    ──────► rsync ───────▶  (Mac → server, every 5 min)
             │                                      │
             └──────────────────────────────────────┘
```

## The one-writer rule (everything depends on this)

> **The server owns memory. The Mac owns code.**

- `~/cairn/my-context/` on the Mac is a **read-only mirror**, overwritten every 5 minutes.
  Anything Mac-Cairn writes there is silently destroyed — and worse, two writers make the
  memory **diverge**, which makes it untrustworthy, which kills the whole system.
- `~/agent/mac-mirror/` on the server (optional, via `mac-sync-install.sh`) is likewise a
  read-only mirror of his working trees. Server-Cairn reads it and proposes **diffs**; it
  never writes into it.

## So how does what he learns on the Mac get remembered?

**Through the transcripts.** Mac sessions are rsynced up; the server's nightly journal
reads them and writes the log. The loop closes — it just closes **through the server**, on
purpose, so there is exactly one writer.

This is why Mac-Cairn's `CLAUDE.md` instructs it to **state anything memorable explicitly
in its final message**: that's the handoff. If it just thinks it, the journal may miss it.

## Install

| Where | Script | What it gives you |
|---|---|---|
| **Mac** | `cairn-on-mac-install.sh` | **Cairn in VS Code.** Memory mirror + `~/.claude/CLAUDE.md` + sync. **This is the important one.** |
| Mac (optional) | `mac-sync-install.sh` | Also pushes working trees up, so you can ask Cairn about uncommitted code **from your phone**. |
| Server | already done | brief, journal, email, cron |
