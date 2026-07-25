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
import re
from datetime import date, datetime
from zoneinfo import ZoneInfo

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
    # ONE call site for "now" (the whole reason this is a function). Roman is
    # Pacific; the server is UTC — so date.today() returns the SERVER's day, which
    # rolls to tomorrow at ~5pm Pacific and would flag a task due *today* as OVERDUE
    # a full day early. Compute the date in the owner's zone instead. (Caught
    # 2026-07-19: a card due that night read OVERDUE at 6:25pm PDT because UTC had
    # already crossed into the 20th.)
    tz = ZoneInfo(os.environ.get("OWNER_TZ", "America/Los_Angeles"))
    return datetime.now(tz).date()


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


TASK_ID_RE = re.compile(r"\bT\d+\b")
STALE_DAYS = 14  # an open task this far past due, unmentioned, is a reconciliation candidate


def _load_text(path):
    """Read a sibling context file if present; missing/unreadable -> '' (lint is best-effort)."""
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def context_lint(data, yaml_path):
    """Deterministic cross-file consistency checks. Pure function of tasks.yaml +
    (read-only) sibling context files. Returns a list of finding strings — the MECHANICAL
    half of reconciliation, so the nightly LLM step only has to adjudicate what's flagged,
    not scan every file. Never mutates anything. Same philosophy as the renderer itself:
    a script does the exact-comparison work, the model does the judgment work."""
    ctx = os.path.dirname(os.path.abspath(yaml_path))
    open_tasks = data.get("tasks", []) or []
    done_tasks = data.get("done", []) or []
    done_ids = {t.get("id") for t in done_tasks if t.get("id")}
    td = today()
    findings = []

    # 1. Answered open-questions: a task referenced in the STILL-OPEN part of
    #    open-questions.md that is already in done: -> the question is drainable.
    oq = _load_text(os.path.join(ctx, "open-questions.md"))
    if oq:
        active = re.split(r"(?im)^#+\s*.*answered", oq)[0]  # inspect only pre-"Answered" text
        refs = set(TASK_ID_RE.findall(active))
        for tid in sorted(refs & done_ids):
            findings.append(
                f"[drain] open-questions.md still lists a question tied to {tid}, "
                f"which is DONE — move it to the Answered section with a pointer."
            )

    # 2. Pointer drift in current.md: under the single-source model, current.md POINTS at
    #    live tasks; it must not narrate a DONE task as if it were still live. (We do NOT
    #    flag "references a task without repeating its due date" — a pointer omitting the
    #    date is correct, not drift; the date lives in tasks.yaml.)
    cur = _load_text(os.path.join(ctx, "current.md"))
    if cur:
        # line-by-line so a legitimate pointer ("old T59 is closed", a "do NOT sweep
        # T2/T3" hold-note) is distinguished from stale live-narration.
        done_kw = re.compile(r"\b(done|closed|superseded|archiv|swept|sweep|finished|complete)", re.I)
        cur_lines = cur.splitlines()
        for tid in sorted(set(TASK_ID_RE.findall(cur)) & done_ids):
            lines_with = [ln for ln in cur_lines if tid in TASK_ID_RE.findall(ln)]
            if any(not done_kw.search(ln) for ln in lines_with):
                findings.append(
                    f"[drift] current.md narrates {tid} (DONE) as if live — "
                    f"make it a pointer or drop it."
                )

    # 3. Long-overdue stale candidates (from tasks.yaml alone, fully deterministic).
    for t in open_tasks:
        d = parse_due(t.get("due"))
        if d and (td - d).days >= STALE_DAYS:
            findings.append(
                f"[stale] {t.get('id')} '{t.get('title')}' is {(td - d).days} days past "
                f"due ({t['due']}) and still open — close, reschedule, or confirm."
            )

    return findings


def print_lint(findings, stream=sys.stdout):
    if not findings:
        print("context-lint: clean", file=stream)
        return
    print(f"context-lint: {len(findings)} finding(s)", file=stream)
    for f in findings:
        print(f"  - {f}", file=stream)


def main():
    args = sys.argv[1:]
    lint_only = False
    if args and args[0] == "--lint":
        lint_only = True
        args = args[1:]

    yaml_path = args[0] if args else os.path.join(
        os.environ.get("CONTEXT_DIR", "."), "tasks.yaml"
    )
    md_path = os.path.join(os.path.dirname(yaml_path), "tasks.md")

    with open(yaml_path) as f:
        data = yaml.safe_load(f)

    if lint_only:
        # Read-only mode for the nightly reconciliation step: emit the report on stdout,
        # write nothing. Never let a lint bug break a render — this path doesn't touch md.
        print_lint(context_lint(data, yaml_path), stream=sys.stdout)
        return

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

    # Surface consistency findings on stderr (never fatal). A caller that wants the full
    # machine-readable report calls `render-tasks.py --lint`.
    try:
        findings = context_lint(data, yaml_path)
        if findings:
            print_lint(findings, stream=sys.stderr)
    except Exception as e:  # lint must never break a render
        print(f"context-lint: skipped ({e})", file=sys.stderr)


if __name__ == "__main__":
    main()
