#!/usr/bin/env python3
"""ats_sources.py — DETERMINISTIC fetchers for applicant-tracking systems (no LLM).

Used by internship-sweep.py alongside the LinkedIn CLI. Why this exists: WebFetch cannot render
Workday/Phenom JS portals (blank pages / 403), which is how the 09-12 sweep missed Gilead R0054572
and Merck's whole 2027 cycle. The JSON endpoints below answer to plain curl with a browser
User-Agent — live-verified 2026-09-15 (see my-context/reference/ats-endpoints.md).

Contract: every function returns plain dicts and never raises. A dead source yields [] and a
count of 0, so internship-sweep.sh's "every source empty" alarm can distinguish rot from quiet.
Untrusted web text is only ever DATA here.
"""
import datetime
import html
import json
import re
import subprocess

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/128.0 Safari/537.36")
TIMEOUT = 25
MAX_PAGES = 10         # × 20 results per Workday tenant per run — bounded; boards with fewer hits stop early
SEARCH_TEXT = "intern"   # some tenants (Biogen, Regeneron, Novartis) AND the terms — "intern 2027" returned 0; the title filter + page cap do the narrowing

# (company label, tenant, pod, site) — all answered live to the cxs POST on 2026-09-15.
WORKDAY = [
    ("Gilead Sciences", "gilead", "wd1", "gileadcareers"),
    ("Kite Pharma", "gilead", "wd1", "kitepharmacareers"),
    ("Amgen", "amgen", "wd1", "Careers"),
    ("Genentech", "roche", "wd3", "ROG-A2O-GENE"),
    ("Illumina", "illumina", "wd1", "illumina-careers"),
    ("Illumina", "illumina", "wd1", "illumina-universityrecruiting"),
    ("Neurocrine Biosciences", "neurocrine", "wd5", "Neurocrinecareers"),
    ("Thermo Fisher Scientific", "thermofisher", "wd5", "ThermoFisherCareers"),
    ("Bristol Myers Squibb", "bristolmyerssquibb", "wd5", "BMS"),
    ("Moderna", "modernatx", "wd1", "M_tx"),
    ("Vertex Pharmaceuticals", "vrtx", "wd501", "Vertex_Careers"),   # wd5 pod is dead; wd501 answers
    ("Biogen", "biibhr", "wd3", "external"),
    ("Regeneron", "regeneron", "wd1", "Careers"),
    ("Pfizer", "pfizer", "wd1", "PfizerCareers"),
    ("Novartis", "novartis", "wd3", "Novartis_Careers"),
    ("Sanofi", "sanofi", "wd3", "SanofiCareers"),
    ("Labcorp", "labcorp", "wd1", "External"),
    ("23andMe", "23andme", "wd5", "23"),
    ("Merck", "msd", "wd5", "SearchJobs"),   # Merck's Phenom front-end applies into this Workday tenant
    # Takeda: takeda.wd3/External returned HTTP 422 on 2026-09-15 — site token unknown; not wired.
]
GREENHOUSE = [("Ginkgo Bioworks", "ginkgobioworks"), ("Recursion", "recursionpharmaceuticals")]
SMARTRECRUITERS = [("Guardant Health", "GuardantHealth")]

INTERN = re.compile(r"\bintern(ship)?s?\b|\bco-?op\b|\bsummer (20)?27\b", re.I)
SENIOR = re.compile(r"\b(senior|sr\.?|director|manager|principal|head of|vp)\b", re.I)


def curl(url, post=None):
    a = ["curl", "-sS", "-m", str(TIMEOUT), "--compressed", "-A", UA, "-H", "Accept: application/json"]
    if post is not None:
        a += ["-H", "Content-Type: application/json", "-X", "POST", "-d", json.dumps(post)]
    try:
        p = subprocess.run(a + [url], capture_output=True, text=True, timeout=TIMEOUT + 10)
        return p.stdout if p.returncode == 0 else ""
    except (subprocess.TimeoutExpired, OSError):
        return ""


def jload(raw):
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        return None


def looks_like_internship(title):
    t = title or ""
    return bool(INTERN.search(t)) and not (SENIOR.search(t) and "intern" not in t.lower())


def _rel_date(s):
    """Workday 'Posted 6 Days Ago' → ISO date. 'Posted 30+ Days Ago' → None (unknown, never guessed)."""
    if not s:
        return None
    t, s = datetime.date.today(), s.lower()
    if "today" in s:
        return t.isoformat()
    if "yesterday" in s:
        return (t - datetime.timedelta(days=1)).isoformat()
    m = re.search(r"(\d+)\+?\s*days?", s)
    if m and "+" not in s:
        return (t - datetime.timedelta(days=int(m.group(1)))).isoformat()
    return None


def strip_html(h):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", h or ""))).strip()


def workday_search(label, tenant, pod, site, counts):
    out, base = [], f"https://{tenant}.{pod}.myworkdayjobs.com"
    for page in range(MAX_PAGES):
        d = jload(curl(f"{base}/wday/cxs/{tenant}/{site}/jobs",
                       {"appliedFacets": {}, "limit": 20, "offset": page * 20, "searchText": SEARCH_TEXT}))
        jp = d.get("jobPostings") if isinstance(d, dict) else None
        if not jp:
            break
        for j in jp:
            title = (j.get("title") or "").replace("\xa0", " ").strip()
            if not looks_like_internship(title):
                continue
            path = j.get("externalPath") or ""
            m = re.search(r"_([A-Za-z]*-?\d[\w-]*)$", path)
            rid = (j.get("bulletFields") or [""])[0] or (m.group(1) if m else "")
            out.append({"id": rid, "title": title, "company": label,
                        "location": j.get("locationsText") or "", "date": _rel_date(j.get("postedOn")),
                        "url": f"{base}/{site}{path}", "portal": f"workday:{tenant}/{site}"})
        if len(jp) < 20:
            break
    counts[f"workday:{label}"] = counts.get(f"workday:{label}", 0) + len(out)
    return out


def workday_detail(url):
    """cxs JSON for one Workday posting → {status, deadline, start, location, text}. None on failure."""
    m = re.match(r"https://([^.]+)\.(wd\d+)\.myworkdayjobs\.com/([^/]+)(/job/.*)$", url)
    if not m:
        return None
    tenant, pod, site, path = m.groups()
    d = jload(curl(f"https://{tenant}.{pod}.myworkdayjobs.com/wday/cxs/{tenant}/{site}{path}"))
    info = d.get("jobPostingInfo") if isinstance(d, dict) else None
    if not info:
        return None
    return {"status": "ACTIVE", "deadline": info.get("endDate"), "start": info.get("startDate"),
            "location": info.get("location"), "text": strip_html(info.get("jobDescription", ""))}


def greenhouse(label, board, counts):
    d = jload(curl(f"https://boards-api.greenhouse.io/v1/boards/{board}/jobs?content=true"))
    out = []
    for j in (d.get("jobs", []) if isinstance(d, dict) else []):
        if not looks_like_internship(j.get("title", "")):
            continue
        out.append({"id": str(j.get("id", "")), "title": j["title"], "company": label,
                    "location": (j.get("location") or {}).get("name") or "",
                    "date": (j.get("updated_at") or "")[:10] or None, "url": j.get("absolute_url", ""),
                    "portal": f"greenhouse:{board}", "description": strip_html(j.get("content", ""))[:6000]})
    counts[f"greenhouse:{label}"] = len(out)
    return out


def smartrecruiters(label, company, counts):
    d = jload(curl(f"https://api.smartrecruiters.com/v1/companies/{company}/postings?q=intern&limit=50"))
    out = []
    for j in (d.get("content", []) if isinstance(d, dict) else []):
        if not looks_like_internship(j.get("name", "")):
            continue
        loc = j.get("location") or {}
        out.append({"id": str(j.get("id", "")), "title": j["name"], "company": label,
                    "location": ", ".join(x for x in [loc.get("city"), loc.get("region"), loc.get("country")] if x),
                    "date": (j.get("releasedDate") or "")[:10] or None,
                    "url": f"https://jobs.smartrecruiters.com/{company}/{j.get('id')}",
                    "portal": f"smartrecruiters:{company}"})
    counts[f"smartrecruiters:{label}"] = len(out)
    return out


def fetch_all(counts=None):
    counts = counts if counts is not None else {}
    out = []
    for label, tenant, pod, site in WORKDAY:
        out += workday_search(label, tenant, pod, site, counts)
    for label, board in GREENHOUSE:
        out += greenhouse(label, board, counts)
    for label, co in SMARTRECRUITERS:
        out += smartrecruiters(label, co, counts)
    return out


if __name__ == "__main__":
    c = {}
    jobs = fetch_all(c)
    print(json.dumps({"counts": c, "n": len(jobs), "sample": jobs[:5]}, indent=2, ensure_ascii=False))
