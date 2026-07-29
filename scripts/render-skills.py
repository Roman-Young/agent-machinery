#!/usr/bin/env python3
"""render-skills.py — regenerate skills-index.md from the skills/ directory. The SOURCE
OF TRUTH is the individual skill files; this script is a pure function of them: same
inputs -> same output, every time (the render-tasks.py discipline, applied to procedural
memory).

WHY THIS EXISTS (2026-07-28): Kairo has declarative memory (me.md/insights.md) and
episodic memory (logs/), but had NO procedural memory — every "how I do X for Roman" got
re-derived each session or wedged into insights.md. This is the procedural layer: a
skill is one markdown file (a reusable procedure); this script indexes them so session
start can load a cheap name+description INDEX, and a full skill is read on demand only
when a task matches (progressive disclosure — the same pattern the reference/ briefings use).

THE 60-CHAR RULE IS LOAD-BEARING. A skill routes off its `description`. The index shows
only name+description, so an overlong description is one the model never actually reads
in full at routing time — it silently never gets found. So an over-limit description is a
HARD ERROR here (fail-loud), not a warning: a bad skill that can't be found is worse than
no skill. (Lesson borrowed from Hermes's skill_manager, which hard-fails the same way.)

Usage:
    python3 render-skills.py [CONTEXT_DIR]     # defaults to $CONTEXT_DIR, then ~/agent/my-context
"""
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import yaml

OWNER_TZ = os.environ.get("OWNER_TZ", "America/Los_Angeles")
DESC_LIMIT = 60          # the routing budget — enforced, not advisory
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
# A small, ordered starter set; anything else falls into "Other" rather than being dropped.
CATEGORY_ORDER = ["agent-ops", "lab", "school", "build", "personal", "other"]
CATEGORY_LABEL = {
    "agent-ops": "🤖 Agent ops",
    "lab": "🔬 Lab",
    "school": "🎓 School",
    "build": "🛠 Build",
    "personal": "🧩 Personal",
    "other": "📎 Other",
}


def today_str() -> str:
    return datetime.now(ZoneInfo(OWNER_TZ)).date().isoformat()


def context_dir() -> Path:
    if len(sys.argv) > 1:
        return Path(sys.argv[1])
    return Path(os.environ.get("CONTEXT_DIR") or (Path.home() / "agent" / "my-context"))


def parse_frontmatter(text: str, path: Path):
    """Split a skill file into (frontmatter dict, body). Frontmatter is the YAML block
    between the first two '---' fences. Returns (None, error-string) on malformed input."""
    if not text.startswith("---"):
        return None, "no '---' frontmatter block at top of file"
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None, "frontmatter block is not closed with a second '---'"
    try:
        fm = yaml.safe_load(parts[1]) or {}
    except yaml.YAMLError as e:
        return None, f"frontmatter is not valid YAML: {e}"
    if not isinstance(fm, dict):
        return None, "frontmatter did not parse to a mapping"
    fm["_body"] = parts[2].strip()
    return fm, None


def load_skills(skills_dir: Path):
    """Return (skills, errors). Picks up both flat `skills/<name>.md` and the graduated
    `skills/<name>/SKILL.md` form. errors is a list of 'file: reason' strings."""
    files = sorted(skills_dir.glob("*.md")) + sorted(skills_dir.glob("*/SKILL.md"))
    skills, errors = [], []
    seen = {}
    for f in files:
        if f.name == "skills-index.md":
            continue
        rel = f.relative_to(skills_dir)
        fm, err = parse_frontmatter(f.read_text(), f)
        if err:
            errors.append(f"{rel}: {err}")
            continue
        name = fm.get("name")
        desc = fm.get("description")
        if not name:
            errors.append(f"{rel}: missing required 'name'")
            continue
        if not NAME_RE.match(str(name)):
            errors.append(f"{rel}: name '{name}' must be kebab-case (a-z, 0-9, -), <=64 chars")
        if not desc:
            errors.append(f"{rel}: missing required 'description'")
        elif len(str(desc)) > DESC_LIMIT:
            errors.append(
                f"{rel}: description is {len(str(desc))} chars (limit {DESC_LIMIT}) — "
                f"a skill routes off its description; over-limit means it never gets found. Trim it."
            )
        if name in seen:
            errors.append(f"{rel}: duplicate skill name '{name}' (also in {seen[name]})")
        else:
            seen[name] = str(rel)
        skills.append({
            "name": name,
            "description": desc or "",
            "category": (fm.get("category") or "other"),
            "path": str(rel),
        })
    return skills, errors


def render(skills, skills_dir: Path) -> str:
    by_cat = {}
    for s in skills:
        cat = s["category"] if s["category"] in CATEGORY_LABEL else "other"
        by_cat.setdefault(cat, []).append(s)

    lines = []
    lines.append("# Skills — Kairo's procedural memory")
    lines.append("")
    lines.append(
        "<!-- ⚠️ GENERATED FILE — DO NOT HAND-EDIT. Add a skill by writing skills/<name>.md, then run:\n"
        "     python3 agent-machinery/scripts/render-skills.py\n"
        "Any hand-edit here is overwritten on the next render.\n\n"
        f"Rendered: {today_str()}   ·   {len(skills)} skill(s)\n"
        "-->"
    )
    lines.append("")
    lines.append("## How this works")
    lines.append("")
    lines.append(
        "This index loads at session start (cheap — just names + one-liners). When a task "
        "matches a skill's description, **read that skill's full file in `skills/` before doing "
        "the work** — same progressive-disclosure pattern as the `reference/` briefings. New "
        "skills are proposed and approved (Roman is the curator), never written autonomously."
    )
    lines.append("")
    lines.append("| Skill | What it's for |")
    lines.append("|---|---|")
    # A flat routing table first (this is what the model scans), then per-category detail.
    for s in sorted(skills, key=lambda s: s["name"]):
        lines.append(f"| `{s['name']}` | {s['description']} |")
    lines.append("")

    for cat in CATEGORY_ORDER:
        group = by_cat.get(cat)
        if not group:
            continue
        lines.append(f"## {CATEGORY_LABEL[cat]}")
        lines.append("")
        for s in sorted(group, key=lambda s: s["name"]):
            lines.append(f"- **`{s['name']}`** — {s['description']}  ·  `skills/{s['path']}`")
        lines.append("")

    if not skills:
        lines.append("*No skills yet. Write `skills/<name>.md` and re-render.*")
        lines.append("")
    return "\n".join(lines)


def main():
    ctx = context_dir()
    skills_dir = ctx / "skills"
    if not skills_dir.is_dir():
        sys.exit(f"render-skills: no skills/ dir at {skills_dir}")

    skills, errors = load_skills(skills_dir)
    if errors:
        # Fail loud, write NOTHING — a broken index must never ship (the whole point of the
        # 60-char rule is that an unfindable skill is worse than no skill).
        print(f"render-skills: {len(errors)} error(s) — index NOT written:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    out = skills_dir / "skills-index.md"
    out.write_text(render(skills, skills_dir))
    print(f"rendered {len(skills)} skill(s) -> {out}")


if __name__ == "__main__":
    main()
