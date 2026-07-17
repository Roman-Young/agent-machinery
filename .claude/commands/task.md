---
description: Add a task (e.g. /task email Danish about the panel by Friday)
---
Add this to `$CONTEXT_DIR/tasks.yaml`: **$ARGUMENTS**

- Append under `tasks:` with the **next free ID** from `meta.next_id`, then increment
  that counter.
- Classify `domain` (work / school / personal / other) and `urgency` (red / yellow /
  green) as best you can from context — it's a field now, not a paragraph, so a wrong
  guess is cheap to fix later.
- If it has a date, set `due:` (ISO format).
- Write a short `notes:` explaining why it matters if the stake isn't obvious — a bare
  imperative is a task Roman skips.
- Then run: `python3 $AGENT_MACHINERY_DIR/scripts/render-tasks.py` (or the equivalent
  path) to regenerate `tasks.md`.
- Confirm in one line with the new ID. Don't re-render the whole list to him unless he asks.
