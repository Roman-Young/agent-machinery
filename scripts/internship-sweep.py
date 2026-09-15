#!/usr/bin/env python3
"""internship-sweep.py — the DETERMINISTIC half of the weekly Summer-2027 internship sweep.

Runs the ai-job-search portal CLIs (bun, no LLM), dedups against the tool's own
seen_jobs.json, detail-fetches a BOUNDED number of new postings, and writes
runs/<date>/new_jobs.json for the scoring agent.

Trust boundary (docs/message-bus.md): job postings are untrusted web content. This file
only ever treats them as DATA — it never interprets them, and the LLM that later reads
new_jobs.json runs with Read/Glob/Grep only (no shell, no send). Keep it that way.

Exit codes: 0 ok · 2 every query returned nothing (portal rot — caller alerts) · 1 error.
Prints shell-evaluable KEY=VALUE lines on stdout for internship-sweep.sh.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path("/home/roman/agent/codebases/ai-job-search")
sys.path.insert(0, str(ROOT / "tools"))
from job_key import make_key  # noqa: E402  (the tool's canonical dedup key)
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ats_sources  # noqa: E402  (deterministic Workday / Greenhouse / SmartRecruiters fetchers)

CLI = ROOT / ".agents/skills/linkedin-search/cli/src/cli.ts"
SEEN = ROOT / "job_scraper/seen_jobs.json"
TRACKER = ROOT / "job_search_tracker.csv"
TRACKER_HEADER = ("date,company,sector,role,role_type,channel,status,contact_person,"
                  "fit_rating,notes,cv_file,cover_letter_file,source,deadline\n")
TODAY = datetime.date.today().isoformat()
RUN = ROOT / "job_scraper/runs" / TODAY
RUN.mkdir(parents=True, exist_ok=True)

JOBAGE = int(os.environ.get("SWEEP_JOBAGE", "45"))
PER_QUERY = int(os.environ.get("SWEEP_N", "15"))
MAX_DETAIL = int(os.environ.get("SWEEP_MAX_DETAIL", "12"))   # LinkedIn ToS: keep volume low

# The query matrix — mirrors .claude/skills/job-scraper/search-queries.md (5 categories,
# US-wide + San Diego + US-scoped remote). Bounded: ~10 searches per run.
QUERIES = [
    ("bioinformatics intern",            "United States", False),
    ("bioinformatics intern",            "San Diego, CA", False),
    ("computational biology intern",     "United States", False),
    ("data science intern biotech",      "United States", False),
    ("data scientist intern",            "United States", True),   # remote, US-scoped
    ("biology research intern",          "United States", False),
    ("immunology intern",                "United States", False),
    ("software engineer intern biotech", "United States", False),
    ("biotech intern",                   "United States", False),
    ("summer 2027 intern life sciences", "United States", False),
]

# search-queries.md Location Filter: drop anything outside the US (the CLI can leak global roles).
NON_US = re.compile(
    r"\b(India|China|France|Germany|United Kingdom|Canada|Ireland|Singapore|Australia|"
    r"Netherlands|Spain|Italy|Brazil|Mexico|Japan|Korea|Denmark|Sweden|Poland|Israel|"
    r"Switzerland|Belgium|Austria|Portugal|Philippines|Pakistan|Nigeria|Kenya|Egypt|"
    r"Emirates|Saudi|Turkey|Vietnam|Thailand|Malaysia|Indonesia|Taiwan|Hong Kong|"
    r"New Zealand|Argentina|Chile|Colombia|Peru|Shanghai|Shenzhen|Bengaluru|Mumbai|Hyderabad|Basel|"
    r"Toronto|Montreal|Vancouver|Dublin|Paris|Barcelona|Madrid|Frankfurt|Munich|Berlin|Copenhagen|"
    r"Stockholm|Tokyo|Sydney|Melbourne|Bangalore|Chennai|Pune|Beijing|Cambridge, UK|Kingdom|"
    r"Zurich|Geneva|Amsterdam|Brussels|Warsaw|Prague|Budapest|Lisbon|Milan|Rome)\b", re.I)

# Sentences the gates in 04-job-evaluation.md need (class year, timing, eligibility, pay).
GATE_KW = re.compile(
    r"rising|junior|senior|sophomore|freshman|graduat|class of|bachelor|master|ph\.?d|"
    r"undergrad|enrolled|returning to|citizen|sponsor|authoriz|clearance|deadline|apply by|"
    r"eligib|co-?op|summer|20(26|27)|weeks|months|full[- ]time|start date|january|may |june|"
    r"july|august|september|hourly|stipend|trainee|recent graduate|post-?bac", re.I)


def bun(args, timeout=120):
    """Run one portal-CLI call; return stdout text ('' on any failure — never raise)."""
    try:
        p = subprocess.run(["bun", "run", str(CLI), *args], cwd=ROOT, capture_output=True,
                           text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else ""
    except (subprocess.TimeoutExpired, OSError):
        return ""


def parse_results(raw):
    try:
        d = json.loads(raw)
    except (ValueError, TypeError):
        return []
    if isinstance(d, list):
        return d
    for k in ("results", "jobs", "data", "items"):
        if isinstance(d.get(k), list):
            return d[k]
    return []


def search(q, loc, remote):
    args = ["search", "-q", q, "-l", loc, "--jobage", str(JOBAGE), "-n", str(PER_QUERY),
            "--format", "json"]
    if remote:
        args += ["--remote", "remote"]
    return parse_results(bun(args))


def excerpt(text, limit=14):
    """Gate-relevant sentences + a short lead, so the scorer can decide without web access."""
    text = re.sub(r"\s+", " ", text or "")
    lead = text[:500]
    sents = re.split(r"(?<=[.!?;])\s+", text)
    out, seen = [], set()
    for s in sents:
        if GATE_KW.search(s):
            k = s[:80]
            if k not in seen:
                seen.add(k)
                out.append(s.strip()[:240])
            if len(out) >= limit:
                break
    return {"lead": lead, "gate_lines": out}


def detail(job_id):
    raw = bun(["detail", str(job_id), "--format", "plain"], timeout=90)
    if not raw:
        return None
    status = "ACTIVE" if re.search(r"^Status:\s*ACTIVE", raw, re.M) else (
        "INACTIVE" if re.search(r"^Status:\s*INACTIVE", raw, re.M) else "unknown")
    return {"status": status, **excerpt(raw)}


def main():
    # State the tool expects (create-if-missing per job-scraper/SKILL.md Step 0).
    seen_doc = {"seen": {}}
    if SEEN.exists():
        try:
            seen_doc = json.loads(SEEN.read_text(encoding="utf-8"))
        except ValueError:
            print("ERROR=seen_jobs.json is not valid JSON; refusing to overwrite", file=sys.stderr)
            return 1
    seen = seen_doc.setdefault("seen", {})
    seen_urls = {(v.get("url") or "").rstrip("/") for v in seen.values()}
    if not TRACKER.exists():
        TRACKER.write_text(TRACKER_HEADER, encoding="utf-8")

    fetched, by_key = 0, {}

    def ingest(r, tag, portal="linkedin-search", source="cli"):
        nonlocal fetched
        fetched += 1
        title, company = (r.get("title") or "").strip(), (r.get("company") or "").strip()
        url = (r.get("url") or "").strip()
        location = (r.get("location") or "").strip()
        if not title or not url or NON_US.search(location):
            return
        key = make_key(company, title, url)
        entry = by_key.setdefault(key, {
            "id": str(r.get("id") or ""), "title": title, "company": company,
            "location": location, "date": r.get("date"), "url": url, "queries": [],
            "portal": portal, "source": source, "description": r.get("description")})
        entry["queries"].append(tag)

    for q, loc, remote in QUERIES:
        for r in search(q, loc, remote):
            ingest(r, q)
    # ATS boards (Workday / Greenhouse / SmartRecruiters) — the postings LinkedIn never shows.
    ats_counts = {}
    for r in ats_sources.fetch_all(ats_counts):
        ingest(r, r["portal"], portal=r["portal"], source="ats")

    if fetched == 0:
        print("FETCHED=0\nNEW=0")
        return 2   # every query empty → portal rot, not "no jobs"

    new = {k: v for k, v in by_key.items()
           if k not in seen and v["url"].rstrip("/") not in seen_urls}

    # Bounded detail pass on NEW postings, summer-looking titles first (that's where the
    # class-year / timing gates actually need the description).
    def prio(v):
        t = v["title"].lower()
        return (0 if ("summer" in t or "2027" in t) else 1, 0 if "intern" in t else 1)
    detailed = 0
    for k in sorted(new, key=lambda k: prio(new[k]))[:MAX_DETAIL]:
        job = new[k]
        if "myworkdayjobs.com" in job["url"]:          # Workday: cxs JSON carries endDate = the deadline
            d = ats_sources.workday_detail(job["url"])
            if d:
                d = {"status": d["status"], "deadline": d.get("deadline"), **excerpt(d.get("text", ""))}
        elif job.get("description"):                    # Greenhouse: description came with the listing
            d = {"status": "unknown", **excerpt(job["description"])}
        else:                                           # LinkedIn: the portal CLI's detail command
            d = detail(job["id"]) if job["id"] else None
        if d:
            job["desc_excerpt"] = d
            if d.get("deadline"):
                job["deadline"] = d["deadline"]
            detailed += 1
    for v in new.values():
        v.pop("description", None)   # keep new_jobs.json small; the excerpt is what the scorer reads

    # Persist ALL fetched postings to seen_jobs.json in the tool's schema (Step 4).
    for k, v in by_key.items():
        if k in seen:
            continue
        seen[k] = {"title": v["title"], "company": v["company"], "location": v["location"],
                   "url": v["url"], "first_seen": TODAY, "posted_date": v.get("date"),
                   "deadline": v.get("deadline"), "fit": None, "status": "new",
                   "portal": v.get("portal", "linkedin-search"), "source": v.get("source", "cli")}
    tmp = tempfile.NamedTemporaryFile("w", dir=SEEN.parent, delete=False, encoding="utf-8")
    json.dump(seen_doc, tmp, indent=2, ensure_ascii=False)
    tmp.close()
    os.replace(tmp.name, SEEN)

    out_path = RUN / "new_jobs.json"
    out_path.write_text(json.dumps({"run_date": TODAY, "fetched": fetched,
                                    "new_count": len(new), "jobs": list(new.values())},
                                   indent=2, ensure_ascii=False), encoding="utf-8")
    ats_summary = ",".join(f"{k.split(':', 1)[1]}={v}" for k, v in sorted(ats_counts.items()))
    print(f"FETCHED={fetched}\nUNIQUE={len(by_key)}\nNEW={len(new)}\nDETAILED={detailed}\n"
          f"NEW_PATH={out_path}\nATS_SOURCES=\"{ats_summary}\"")
    return 0


if __name__ == "__main__":
    sys.exit(main())
