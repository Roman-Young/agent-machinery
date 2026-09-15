#!/usr/bin/env python3
"""sheet_sync.py — append-only sync of the internship tracker into Roman's Google Sheet.

Runs under ~/.venvs/sheets/bin/python (gspread + google-auth, installed via uv). Needs:
  * a service-account key JSON — env SHEETS_SA_JSON, default my-context/local-only/google-sheets-sa.json
    (gitignored; never in the public agent-machinery repo), and
  * the sheet shared with that service account's e-mail as Editor.
Without the key it prints SHEET_SKIPPED=no-key and exits 0 — the sweep must never fail because of it.

Ownership contract (the reason this is append-only):
  Kairo writes  : Priority, Fit, Deadline, Program dates, Eligibility, Why it fits, Category, Source, First seen
  Roman writes  : Status, My notes   — NEVER touched by this script
  Rows are keyed by "Apply link". New postings are appended at the bottom; existing rows get only the
  Kairo columns refreshed when a value changed (e.g. a deadline learned later). Nothing is ever deleted.
"""
import datetime
import glob
import json
import os
import re
import sys
from pathlib import Path

SHEET_ID = os.environ.get("SHEETS_ID", "1mMD1O8GnEOjgrLRVjRELPZzYD7C1PmN-THuO_LNgTk4")
SA = Path(os.environ.get("SHEETS_SA_JSON", "/home/roman/agent/my-context/local-only/google-sheets-sa.json"))
ROOT = Path("/home/roman/agent/codebases/ai-job-search")
SEEN = ROOT / "job_scraper/seen_jobs.json"

HEADER = ["Priority", "Fit", "Company", "Role", "Location", "Deadline", "Program dates", "Eligibility",
          "Why it fits", "Apply link", "Category", "Source", "First seen", "Status", "My notes"]
KAIRO_COLS = ["Priority", "Fit", "Deadline", "Program dates", "Eligibility", "Why it fits", "Category",
              "Source", "First seen"]
NEVER_BLANK = {"Program dates", "Why it fits", "Source", "First seen"}   # keep seeded text if we have nothing better
STATUS_OPTIONS = ["Applying", "Applied", "Interview", "Offer", "Rejected", "Skip", "Waiting"]


def col_letter(i):  # 0-based index → A1 column
    s = ""
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        s = chr(65 + r) + s
    return s


def digest_categories(path):
    """url → section of the latest scoring digest (the scorer's verdict), if any."""
    cat, cur = {}, None
    if not path or not Path(path).exists():
        return cat
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.startswith("## ✅"):
            cur = "Summer-eligible"
        elif line.startswith("## ⚠️"):
            cur = "Verify"
        elif line.startswith("## 🔁"):
            cur = "Co-op (not summer)"
        elif line.startswith("## ❌"):
            cur = "Excluded"
        elif line.startswith("## 👀"):
            cur = "Other (not summer)"
        elif cur:
            for m in re.finditer(r"https?://\S+", line):
                cat.setdefault(m.group(0).rstrip(").,;"), cur)
    return cat


def row_for(e, cat, today):
    fit, verdict = e.get("fit"), e.get("eligibility_verdict")
    c = cat.get(e.get("url", "")) or e.get("category") or ("Summer-eligible" if fit else "Unreviewed")
    if fit == "dup":
        stars = "dup"
    elif fit == "high":
        stars = "⭐⭐⭐"
    elif fit == "medium" or c == "Summer-eligible":
        stars = "⭐⭐"
    elif c == "Verify":
        stars = "⭐"
    elif c.startswith("Co-op"):
        stars = "co-op"
    elif c == "Excluded":
        stars = "✗"
    else:
        stars = "—"
    dl = e.get("deadline") or ""
    soon = False
    try:
        soon = datetime.date.fromisoformat(dl[:10]) <= today + datetime.timedelta(days=30)
    except ValueError:
        pass
    pri = "⭐ PRIORITY" if (fit == "high" or (soon and not (c.startswith("Co-op") or c == "Excluded"))) else ""
    elig = (f"{verdict}: " if verdict else "") + (e.get("verify_note") or "")
    if not elig:
        ex = e.get("desc_excerpt") or {}
        if isinstance(ex, dict) and ex.get("gate_lines"):
            elig = " · ".join(ex["gate_lines"][:3])
        elif c == "Summer-eligible":
            elig = "Looks summer/undergrad from title — not yet detail-verified"
        elif c == "Verify":
            elig = "Not yet detail-verified (dates/class year unknown)"
        elif c.startswith("Co-op"):
            elig = "Semester co-op, not summer"
        elif c == "Excluded":
            elig = "Excluded by gate (grad-level / trainee / not summer)"
    return [pri, stars, e.get("company", ""), (e.get("title") or "")[:120], e.get("location", ""), dl,
            e.get("program_dates", ""), elig[:400], e.get("why_fit", ""), e.get("url", ""), c,
            e.get("portal", "linkedin-search"), e.get("first_seen", ""), "", ""]


def ensure_dashboard(sh, ws):
    """A small Dashboard tab + a Status dropdown. Idempotent."""
    t = ws.title.replace("'", "''")
    try:
        sh.worksheet("Dashboard")
    except Exception:
        d = sh.add_worksheet("Dashboard", rows=20, cols=3)
        rows = [["Metric", "Count", "Status options: " + " → ".join(STATUS_OPTIONS)],
                ["Total postings", f"=COUNTA('{t}'!J2:J)", ""],
                ["⭐ Priority", f"=COUNTIF('{t}'!A2:A,\"*PRIORITY*\")", ""],
                ["Summer-eligible", f"=COUNTIF('{t}'!K2:K,\"Summer-eligible\")", ""],
                ["Applying", f"=COUNTIF('{t}'!N2:N,\"Applying\")", ""],
                ["Applied", f"=COUNTIF('{t}'!N2:N,\"Applied\")", ""],
                ["Interview", f"=COUNTIF('{t}'!N2:N,\"Interview\")", ""],
                ["Offer", f"=COUNTIF('{t}'!N2:N,\"Offer\")", ""],
                ["Deadlines in next 7 days (not yet applied)",
                 f"=COUNTIFS('{t}'!F2:F,\">=\"&TODAY(),'{t}'!F2:F,\"<=\"&TODAY()+7,'{t}'!N2:N,\"<>Applied\")", ""],
                ["Deadlines in next 30 days", f"=COUNTIFS('{t}'!F2:F,\">=\"&TODAY(),'{t}'!F2:F,\"<=\"&TODAY()+30)", ""],
                ["Overdue (not applied)", f"=COUNTIFS('{t}'!F2:F,\"<\"&TODAY(),'{t}'!F2:F,\"<>\",'{t}'!N2:N,\"<>Applied\")", ""]]
        d.update(values=rows, range_name="A1", value_input_option="USER_ENTERED")
    # Status dropdown on column N (index 13), rows 2..2000
    sh.batch_update({"requests": [{"setDataValidation": {
        "range": {"sheetId": ws.id, "startRowIndex": 1, "endRowIndex": 2000, "startColumnIndex": 13, "endColumnIndex": 14},
        "rule": {"condition": {"type": "ONE_OF_LIST", "values": [{"userEnteredValue": v} for v in STATUS_OPTIONS]},
                 "showCustomUi": True, "strict": False}}}]})


FIT_ORDER = {"⭐⭐⭐": 0, "⭐⭐": 1, "⭐": 2, "—": 3, "dup": 3.5, "co-op": 4, "✗": 5}


def sort_sheet(ws):
    """Reorder the whole sheet priority → fit → deadline so Roman reads it top-down.

    Safe with the ownership contract: it rewrites COMPLETE rows read back from the sheet,
    so each row's manual Status/My-notes travel with it — nothing is detached or lost."""
    vals = ws.get_all_values()
    if len(vals) < 3:
        return
    hdr, rows = vals[0], vals[1:]
    w = len(hdr)

    def key(r):
        r = r + [""] * (w - len(r))
        status = r[13].strip().lower()
        done = 1 if status in ("applied", "rejected", "skip") else 0   # finished rows sink to the bottom
        dl = r[5][:10]
        dl = dl if re.match(r"\d{4}-\d{2}-\d{2}$", dl) else "9999-99-99"   # dated first, blanks last
        return (done, 0 if "PRIORITY" in r[0] else 1, FIT_ORDER.get(r[1], 9), dl, r[2].lower())

    rows.sort(key=key)
    ws.update(values=[hdr] + [r + [""] * (w - len(r)) for r in rows],
              range_name="A1", value_input_option="USER_ENTERED")
    # Safety: a sort must never lose rows. If the sheet came back shorter, something raced —
    # surface it loudly rather than silently dropping applications.
    after = len(ws.get_all_values()) - 1
    if after < len(rows):
        raise RuntimeError(f"sort_sheet row-count dropped {len(rows)} -> {after}")


def main():
    if not SA.exists():
        print("SHEET_SKIPPED=no-key")
        return 0
    import gspread
    from google.oauth2.service_account import Credentials
    creds = Credentials.from_service_account_file(str(SA), scopes=["https://www.googleapis.com/auth/spreadsheets"])
    sh = gspread.authorize(creds).open_by_key(SHEET_ID)
    ws = sh.sheet1
    values = ws.get_all_values()
    if not values:
        ws.append_row(HEADER)
        values = [HEADER]
    header = values[0]
    link_i = header.index("Apply link") if "Apply link" in header else 9
    existing = {}
    for i, r in enumerate(values[1:], start=2):   # sheet row numbers (1 = header)
        if len(r) > link_i and r[link_i]:
            existing[r[link_i]] = i

    seen = json.loads(SEEN.read_text(encoding="utf-8"))["seen"]
    digests = sorted(glob.glob(str(ROOT / "job_scraper/digests/*.md")))
    cat = digest_categories(digests[-1] if digests else None)
    runs = sorted(glob.glob(str(ROOT / "job_scraper/runs/*/new_jobs.json")))
    latest = {j["url"]: j for j in json.load(open(runs[-1], encoding="utf-8"))["jobs"]} if runs else {}
    today = datetime.date.today()

    to_append, updates = [], []
    col_idx = {name: header.index(name) for name in KAIRO_COLS if name in header}
    for e in seen.values():
        url = e.get("url", "")
        if not url:
            continue
        m = dict(e)
        nj = latest.get(url, {})
        if not m.get("deadline") and nj.get("deadline"):
            m["deadline"] = nj["deadline"]
        m["desc_excerpt"] = nj.get("desc_excerpt")
        row = row_for(m, cat, today)
        if url in existing:
            r = existing[url]
            cur = values[r - 1] + [""] * (len(HEADER) - len(values[r - 1]))
            for name, ci in col_idx.items():
                newv = row[HEADER.index(name)]
                if not newv and name in NEVER_BLANK:
                    continue          # keep seeded descriptive text (Program dates / Why / Source / First seen)
                if newv != cur[ci]:    # authoritative columns (Priority/Fit/Deadline/Category) may be cleared
                    updates.append({"range": f"{col_letter(ci)}{r}", "values": [[newv]]})
        else:
            to_append.append(row)

    if to_append:
        ws.append_rows(to_append, value_input_option="USER_ENTERED")
    if updates:
        for i in range(0, len(updates), 200):
            ws.batch_update(updates[i:i + 200], value_input_option="USER_ENTERED")
    try:
        sort_sheet(ws)
    except Exception as exc:  # sort is a nicety — never fail the sync over ordering
        print(f"SHEET_SORT_WARN={type(exc).__name__}", file=sys.stderr)
    try:
        ensure_dashboard(sh, ws)
    except Exception as exc:  # cosmetic — never fail the sync over the dashboard
        print(f"SHEET_DASHBOARD_WARN={type(exc).__name__}", file=sys.stderr)
    print(f"SHEET_ADDED={len(to_append)}\nSHEET_UPDATED={len(updates)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"SHEET_ERROR={type(exc).__name__}: {str(exc)[:160]}")
        sys.exit(1)
