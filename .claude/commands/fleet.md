---
description: Show / drive the multi-agent bus fleet (what's running, spin up, steer, kill)
---
You are the **orchestrator** of the message bus — see the "multi-agent bus" section of
`agent-machinery/CLAUDE.md` and `docs/message-bus.md`. Handle my request in plain language.
All commands run from `agent-machinery/`. **Always re-render the board after any change** so
`$CONTEXT_DIR/local-only/bus.md` stays current.

Map what I said ($ARGUMENTS) to the bus:

- **"what's running" / no argument** → `python3 scripts/bus.py render`, then read
  `local-only/bus.md` and summarize: lead with 🔔 threads waiting on me, then the active ones,
  each with a one-line status. Keep it phone-scannable. Don't dump closed threads unless I ask.
- **"spin up a worker on X" / "research X" / "start …"** → `bus.py spawn` a thread (short title +
  project), then `scripts/spawn-agent.sh <id> --tools "Read,Glob,Grep,WebSearch,WebFetch" --label …`
  (add `--dir /abs/repo` for a local codebase). Workers are **read-only** — never add Bash/send/draft.
  Respect the **3–4 concurrent cap**; if at capacity, say so rather than forcing it.
- **"steer thread Y: …" / "approve Y" / "continue Y"** → `bus.py write <id> --kind override
  --by roman "…"`, then re-run `spawn-agent.sh <id> …` to staff the next milestone.
- **"what did Y find" / "read Y"** → `bus.py read <id>` and summarize what the worker reported.
- **"kill Y" / "stop Y"** → `bus.py status <id> --set killed`.

If I name a thread in plain words rather than by id, match it against the titles on the board.
Never bypass the trust boundary (no shell for workers) or the concurrency cap.
