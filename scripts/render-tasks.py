#!/usr/bin/env python3
"""render-tasks.py — regenerate tasks.md from tasks.yaml. THE SOURCE OF TRUTH IS
tasks.yaml; this script is a pure function of it: same input -> same output, every
time. That is the whole point.

WHY THIS EXISTS (2026-07-17): the old tasks.md was hand-sorted prose. Every reorder,
every "is this overdue," every regrouping depended on an LLM correctly parsing and
rewriting ~180 lines of text — the exact failure class (LLM inference doing a job a
script should do exactly) that has bitten this system before. This script makes
sorting, grouping, and overdue-detection MECHANICAL: real fields, real date
comparisons, deterministic output.

Usage:
    python3 render-tasks.py [path/to/tasks.yaml]   # defaults to CONTEXT_DIR/tasks.yaml
"""
import sys
import os
from datetime import date, datetime

import yaml

URGENCY_ORDER = {"red": 0, "yellow": 1, "green": 2}
URGENCY_ICON = {"red": "🔴", "yellow": "🟡", "green": "🟢"}
DOMAIN_ORDER = ["work", "school", "personal", "other"]
DOMAIN_LABEL = {
    "work": "🏢 Work",
    "school": "🎓 School",
    "personal": "🧩 Personal",
    "other": "📎 Other",
}


def today():
    # Never Date.now()-style implicit "now" scattered through the script — one
    # call site, so a future change (e.g. timezone) only needs to happen once.
    return date.today()


def parse_due(due_str):
    if not due_str:
        return None
    return datetime.strptime(due_str, "%Y-%m-%d").date()


def sort_key(t):
    due = parse_due(t.get("due"))
    # Overdue and near-term first: sort by (urgency, due-date-or-far-future).
    far_future = date(9999, 1, 1)
    return (URGENCY_ORDER.get(t.get("urgency", "green"), 2), due or far_future, t["id"] or "")


def render_task_line(t):
    parts = [f"**{t['id']}**" if t.get("id") else "—", f"{URGENCY_ICON.get(t.get('urgency', 'green'), '')} {t['title']}"]
    due = parse_due(t.get("due"))
    if due:
        overdue = due < today()
        due_str = f"⏰ **OVERDUE** ({t['due']})" if overdue else t["due"]
        parts.append(due_str)
    else:
        parts.append("—")
    status = t.get("status", "open")
    tail = []
    if t.get("project"):
        tail.append(f"*{t['project']}*")
    if status == "blocked":
        tail.append(f"⏸ blocked on {t.get('blocked_on', '?')}")
    notes = (t.get("notes") or "").strip().replace("\n", " ")
    if notes:
        tail.append(notes)
    parts.append(" — ".join(tail))
    return "| " + " | ".join(parts) + " |"


def render_done_line(t):
    notes = (t.get("notes") or "").strip().replace("\n", " ")
    idpart = f"~~{t['id']}~~" if t.get("id") else "—"
    return f"- **{t.get('done_date', '?')}** — {idpart} **{t['title']}** → {notes}"


def main():
    yaml_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.environ.get("CONTEXT_DIR", "."), "tasks.yaml"
    )
    md_path = os.path.join(os.path.dirname(yaml_path), "tasks.md")

    with open(yaml_path) as f:
        data = yaml.safe_load(f)

    meta = data.get("meta", {})
    open_tasks = [t for t in data.get("tasks", [])]
    done_tasks = data.get("done", [])

    overdue_count = sum(
        1 for t in open_tasks if (d := parse_due(t.get("due"))) and d < today()
    )

    lines = []
    lines.append("# Tasks — the single to-do list")
    lines.append("")
    lines.append(
        "<!-- ⚠️ GENERATED FILE — DO NOT HAND-EDIT. Edit tasks.yaml, then run:\n"
        "     python3 agent-machinery/scripts/render-tasks.py\n"
        "Any hand-edit here is silently overwritten on the next render.\n\n"
        f"Next free ID: T{meta.get('next_id', '?')}\n"
        f"Last reviewed: {meta.get('last_reviewed', '?')}\n"
        f"Rendered: {today().isoformat()}\n"
        "-->"
    )
    lines.append("")
    lines.append("## How this works")
    lines.append("")
    lines.append("Just talk to me. No syntax to remember.")
    lines.append("")
    lines.append("| You say | I do |")
    lines.append("|---|---|")
    lines.append(
        "| *\"what are my to-dos\"* | Render the live list, most urgent first. I don't dump Done at you. |"
    )
    lines.append("| *\"add: X\"* | Append a new task to tasks.yaml with the next free ID, then re-render. |")
    lines.append("| *\"done with X\"* | Move it to `done:` in tasks.yaml with today's date, then re-render. |")
    lines.append("| *\"push X to next week\"* | Update its `due:` field, then re-render. |")
    lines.append("")
    lines.append(
        "**Nothing is ever deleted.** Completed tasks move to `done:` in tasks.yaml, "
        "never removed. IDs are never reused."
    )
    lines.append("")
    if overdue_count:
        lines.append(f"### ⏰ {overdue_count} item(s) overdue — see below")
        lines.append("")
    lines.append("---")
    lines.append("")

    for domain in DOMAIN_ORDER:
        domain_tasks = [t for t in open_tasks if t.get("domain") == domain]
        if not domain_tasks:
            continue
        domain_tasks.sort(key=sort_key)
        lines.append(f"## {DOMAIN_LABEL[domain]}")
        lines.append("")
        lines.append("| ID | Task | Due | Notes |")
        lines.append("|---|---|---|---|")
        for t in domain_tasks:
            lines.append(render_task_line(t))
        lines.append("")

    # Catch anything with an unrecognized/missing domain rather than silently
    # dropping it — a silent drop is worse than an ugly "Unsorted" bucket.
    known = set(DOMAIN_ORDER)
    stray = [t for t in open_tasks if t.get("domain") not in known]
    if stray:
        lines.append("## ⚠️ Unsorted (bad `domain:` field — fix in tasks.yaml)")
        lines.append("")
        lines.append("| ID | Task | Due | Notes |")
        lines.append("|---|---|---|---|")
        for t in sorted(stray, key=sort_key):
            lines.append(render_task_line(t))
        lines.append("")

    lines.append("---")
    lines.append("")
    lines.append("## ✅ Done")
    lines.append("")
    lines.append("*Newest first. Never deleted. Full narrative for any entry lives in `logs/`.*")
    lines.append("")
    for t in sorted(done_tasks, key=lambda t: t.get("done_date", ""), reverse=True):
        lines.append(render_done_line(t))
    lines.append("")

    with open(md_path, "w") as f:
        f.write("\n".join(lines))

    print(f"rendered {len(open_tasks)} open ({overdue_count} overdue), "
          f"{len(done_tasks)} done -> {md_path}")


if __name__ == "__main__":
    main()
