#!/usr/bin/env python3
"""canvas-sync.py — deterministic, LLM-free merge of Canvas assignments into tasks.yaml.

Reads canvas-fetch.py's JSON (arg 1, or stdin) and upserts dated school tasks. No model is in the
loop: assignment titles are untrusted web text, and a pure function that never hands them to an
LLM-with-edit-rights removes a prompt-injection surface. Idempotent by construction (keyed upsert).

Rules (per assignment that HAS a due date):
  * dedup key  = a grep-able token in notes: [canvas:assignment/<id>] (survives date moves).
  * submitted  = submitted_at set OR workflow_state in {submitted, graded, pending_review}.
  * ADD    — not yet tracked AND not submitted  -> append open task (next_id++), domain school,
             project=<course short name>, due=<ISO, Pacific>, urgency by proximity.
  * UPDATE — already tracked (open) AND not submitted -> refresh due/title/urgency in place.
  * CLOSE  — already tracked (open) AND now submitted -> move to done: with done_date=today.
  * SKIP   — not tracked AND submitted (a done item we never tracked -> don't clutter).
Never touches non-Canvas tasks; never resurrects a done task; never edits tasks.md (generated).

Run via: uv run --with "ruamel.yaml" python3 canvas-sync.py <fetch.json>
Exit 0 on success; 3 on logged_out; 4 on fetch error; other non-zero on internal failure.
Prints a coverage line the orchestrator asserts: SOURCES: canvas=ok|FAIL (...).
"""
import json
import os
import re
import sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from ruamel.yaml import YAML
from ruamel.yaml.scalarstring import LiteralScalarString

OWNER_TZ = ZoneInfo(os.environ.get("OWNER_TZ", "America/Los_Angeles"))
CONTEXT_DIR = os.environ.get("CONTEXT_DIR") or os.path.expanduser("~/agent/my-context")
TASKS = os.path.join(CONTEXT_DIR, "tasks.yaml")
TOKEN_RE = re.compile(r"\[canvas:assignment/(\d+)\]")


def today():
    return datetime.now(OWNER_TZ).date()


def due_to_iso(due_at):
    """Canvas due_at is ISO8601 UTC ('...Z'); convert to the owner's calendar date (Pacific)."""
    if not due_at:
        return None
    dt = datetime.fromisoformat(due_at.replace("Z", "+00:00")).astimezone(OWNER_TZ)
    return dt.date()


def urgency_for(due_date):
    days = (due_date - today()).days
    if days <= 2:      # overdue or within 2 days
        return "red"
    if days <= 7:
        return "yellow"
    return "green"


def submitted(a):
    return bool(a.get("submitted")) or a.get("workflow_state") in ("submitted", "graded", "pending_review")


def short_course(name):
    """'PHIL 27 - Ethics And Society - Bazargan-Forward [S126]' -> 'PHIL 27'."""
    if not name:
        return None
    m = re.match(r"\s*([A-Z]{2,5}\s?\d+[A-Z]?)", name)
    return m.group(1).strip() if m else name.split(" - ")[0].strip()[:24]


def index_by_token(*lists):
    idx = {}
    for lst in lists:
        for t in (lst or []):
            m = TOKEN_RE.search(str(t.get("notes", "")))
            if m:
                idx[m.group(1)] = t
    return idx


def make_note(assignment, course_short):
    aid = assignment["id"]
    url = assignment.get("html_url") or ""
    return LiteralScalarString(
        "From Canvas (auto-synced). [canvas:assignment/%s] course: %s.\n%s\n"
        "Managed by canvas-sync — edit the assignment in Canvas, not here." % (aid, course_short, url))


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "-"
    raw = sys.stdin.read() if src == "-" else open(src).read()
    payload = json.loads(raw)

    st = payload.get("status")
    if st == "logged_out":
        print("SOURCES: canvas=FAIL (logged_out)"); sys.exit(3)
    if st != "ok":
        print("SOURCES: canvas=FAIL (%s)" % payload.get("reason", "fetch_error")); sys.exit(4)

    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096                              # never wrap our long note lines
    yaml.indent(mapping=2, sequence=4, offset=2)   # match tasks.yaml: "  - id:" (dash at col 2)
    # tasks.yaml writes empty due dates as `null`; ruamel defaults None -> empty. Force `null`
    # so untouched tasks round-trip byte-identical (no cosmetic diff on every dated field).
    yaml.representer.add_representer(
        type(None), lambda r, d: r.represent_scalar("tag:yaml.org,2002:null", "null"))
    with open(TASKS) as f:
        data = yaml.load(f)

    tasks = data.setdefault("tasks", [])
    done = data.setdefault("done", [])
    meta = data.setdefault("meta", {})
    idx = index_by_token(tasks, done)

    added = updated = closed = skipped = 0
    td = today()

    for a in payload.get("assignments", []):
        due = due_to_iso(a.get("due_at"))
        if due is None:                      # undated assignment -> not a dated task
            continue
        aid = str(a.get("id"))
        existing = idx.get(aid)
        is_sub = submitted(a)
        title = "Canvas: %s (%s)" % ((a.get("name") or "assignment").strip(), short_course(a.get("course_name")))

        if existing is not None:
            in_done = any(existing is d for d in done)
            if in_done:
                continue                      # already closed; never resurrect
            if is_sub:                        # CLOSE — move open->done
                existing["status"] = "done"
                existing["done_date"] = td.isoformat()
                tasks.remove(existing)
                done.insert(0, existing)
                closed += 1
            else:                             # UPDATE in place — only if something actually changed
                new_due, new_urg = due.isoformat(), urgency_for(due)
                if (existing.get("due") != new_due or existing.get("title") != title
                        or existing.get("urgency") != new_urg):
                    existing["due"] = new_due
                    existing["title"] = title
                    existing["urgency"] = new_urg
                    updated += 1
            continue

        # not tracked yet
        if is_sub:
            skipped += 1                       # done and never tracked -> don't add clutter
            continue

        tid = "T%s" % meta.get("next_id", 1)
        meta["next_id"] = int(meta.get("next_id", 1)) + 1
        new = {
            "id": tid,
            "title": title,
            "domain": "school",
            "project": short_course(a.get("course_name")),
            "urgency": urgency_for(due),
            "due": due.isoformat(),
            "status": "open",
            "notes": make_note(a, short_course(a.get("course_name"))),
        }
        tasks.append(new)
        added += 1

    if added or updated or closed:
        with open(TASKS, "w") as f:
            yaml.dump(data, f)

    print("SOURCES: canvas=ok added=%d updated=%d closed=%d skipped=%d (courses=%d assignments=%d)"
          % (added, updated, closed, skipped, len(payload.get("courses", [])), len(payload.get("assignments", []))))


if __name__ == "__main__":
    main()
