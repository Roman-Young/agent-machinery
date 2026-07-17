---
description: Mark a task complete (e.g. /done T12, or /done the ntfy thing)
---
Mark this task complete in `$CONTEXT_DIR/tasks.yaml`: **$ARGUMENTS**

- Match by ID (`T12`) or by plain description ("the Lockdown Browser one").
- Move the entry from `tasks:` to `done:`, set `done_date:` to today.
- **Trim `notes:` to a short summary** — the full story belongs in today's log
  (`logs/YYYY-MM-DD.md`), not duplicated here. One or two sentences is right.
- **Never delete it.** Done is a record.
- If the match is ambiguous, ask which one — do not guess.
- Then run: `python3 $AGENT_MACHINERY_DIR/scripts/render-tasks.py` to regenerate `tasks.md`.
- Confirm briefly, and tell me what's now the most urgent open item.
