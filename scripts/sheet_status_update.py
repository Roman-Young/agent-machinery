#!/usr/bin/env python3
"""sheet_status_update.py — write Status updates to the internship tracker sheet from
classified email signals (rejection / interview / application-ack), found during email
triage. This is the ONLY thing that writes Status/My-notes from email evidence — the
triage agent that reads the untrusted email itself never gets Bash or sheet access
(same trust-boundary rule as the message-bus workers); it only proposes structured
signals, and THIS deterministic script performs the actual write.

Runs under ~/.venvs/sheets/bin/python (gspread + google-auth). Needs the same
service-account key as sheet_sync.py (env SHEETS_SA_JSON, default
my-context/local-only/google-sheets-sa.json).

Ownership discipline (extends sheet_sync.py's contract, doesn't replace it):
  - Writes ONLY the Status cell (must be one of STATUS_OPTIONS) and APPENDS a bracketed,
    dated breadcrumb to My notes ("[auto <date>] <signal>: \"<subject>\"") — never
    overwrites existing My-notes text, never touches any other column.
  - NEVER writes status "Offer" — an offer always needs Roman's real decision (same rule
    the ai-job-search framework's own /gmail-sync command already encodes). Callers must
    route an offer signal to a task/notification instead of calling this script.
  - A row already in a FINAL status (Rejected, Skip) that gets a conflicting new signal
    is reported as a CONFLICT and left untouched — same conflict rule as /gmail-sync.
  - Idempotent in effect: if the row's current Status already equals new_status, it is a
    no-op (reported as "already-set"), so re-running never double-appends a note.

Usage:
  python3 sheet_status_update.py '<json>'
    where json is a list of objects:
      {"company": "...", "role_hint": "..." (optional, disambiguates multiple rows for
       the same company), "new_status": "Rejected"|"Interview"|"Applied"|"Applying"|
       "Waiting"|"Skip", "signal": "short label, e.g. Rejection",
       "source": "<email subject>", "date": "YYYY-MM-DD"}
  --dry-run flag (anywhere in argv) reports matches/writes it WOULD make without
  touching the sheet — use this to sanity-check matching before trusting a new caller.

Output (stdout, one line per input item, machine-parseable by the caller):
  WROTE|<row>|<company>|<role>|<old_status>->|<new_status>
  CONFLICT|<row>|<company>|<role>|<current_status>|<attempted_status>
  ALREADY_SET|<row>|<company>|<role>|<status>
  NO_MATCH|<company>|<role_hint>
  AMBIGUOUS|<company>|<n_candidates>
  REJECTED_OFFER_STATUS|<company>  (new_status == "Offer" — refused, not this script's job)
"""
import json
import os
import sys
from pathlib import Path

SHEET_ID = os.environ.get("SHEETS_ID", "1mMD1O8GnEOjgrLRVjRELPZzYD7C1PmN-THuO_LNgTk4")
SA = Path(os.environ.get("SHEETS_SA_JSON", "/home/roman/agent/my-context/local-only/google-sheets-sa.json"))

STATUS_OPTIONS = ["Applying", "Applied", "Interview", "Offer", "Rejected", "Skip", "Waiting"]
FINAL_STATUSES = {"Rejected", "Skip"}


def norm(s):
    return (s or "").strip().lower()


OPEN_STATUSES = {"Applying", "Applied", "Interview", "Waiting"}


def main():
    list_open = "--list-open" in sys.argv
    argv = [a for a in sys.argv[1:] if a not in ("--dry-run", "--list-open")]
    dry_run = "--dry-run" in sys.argv
    if not list_open and not argv:
        print("usage: sheet_status_update.py '<json>' [--dry-run] | --list-open", file=sys.stderr)
        sys.exit(2)

    if not SA.exists():
        print("SHEET_SKIPPED=no-key", file=sys.stderr)
        sys.exit(0)

    import gspread
    gc = gspread.service_account(filename=str(SA))
    sh = gc.open_by_key(SHEET_ID)
    ws = sh.sheet1
    vals = ws.get_all_values()
    hdr, rows = vals[0], vals[1:]
    ci = {h: i for i, h in enumerate(hdr)}

    if list_open:
        # Deterministic, read-only: the trusted list of currently-open tracked applications,
        # fed into the triage agent's prompt as context. Excludes rows with no real status
        # (never applied) and the "Prior cycle" category (a past cycle, not worth matching).
        for r in rows:
            if r[ci["Status"]] in OPEN_STATUSES and r[ci["Category"]] != "Prior cycle (from old tracker)":
                print(f'{r[ci["Company"]]} | {r[ci["Role"]]} | {r[ci["Status"]]}')
        return

    items = json.loads(argv[0])
    for item in items:
        company, role_hint = item.get("company", ""), item.get("role_hint", "")
        new_status, signal = item.get("new_status", ""), item.get("signal", "")
        source, date = item.get("source", ""), item.get("date", "")

        if new_status not in STATUS_OPTIONS:
            print(f"REJECTED_OFFER_STATUS|{company}| invalid status {new_status!r}")
            continue
        if new_status == "Offer":
            print(f"REJECTED_OFFER_STATUS|{company}")
            continue

        nc = norm(company)
        # Only match rows Roman has actually touched (a real applied/tracked status) — a
        # blank Status is just a scraped posting he never applied to, and matching those
        # is how "Machine Learning" collided across an applied row and an unrelated one.
        candidates = [(i + 2, r) for i, r in enumerate(rows)
                      if nc and nc in norm(r[ci["Company"]]) and r[ci["Status"]] != ""]
        if not candidates:
            print(f"NO_MATCH|{company}|{role_hint}")
            continue
        if len(candidates) > 1 and role_hint:
            nr = norm(role_hint)
            narrowed = [(rn, r) for rn, r in candidates if nr in norm(r[ci["Role"]]) or norm(r[ci["Role"]]) in nr]
            if narrowed:
                candidates = narrowed
        if len(candidates) > 1:
            print(f"AMBIGUOUS|{company}|{len(candidates)}")
            continue

        rownum, row = candidates[0]
        cur_status = row[ci["Status"]]
        role = row[ci["Role"]]

        if cur_status == new_status:
            print(f"ALREADY_SET|{rownum}|{company}|{role}|{cur_status}")
            continue
        if cur_status in FINAL_STATUSES:
            print(f"CONFLICT|{rownum}|{company}|{role}|{cur_status}|{new_status}")
            continue

        if dry_run:
            print(f"WROTE|{rownum}|{company}|{role}|{cur_status}->|{new_status} (dry-run, not written)")
            continue

        status_col = ci["Status"] + 1  # gspread is 1-indexed
        notes_col = ci["My notes"] + 1
        ws.update_cell(rownum, status_col, new_status)
        existing_notes = row[ci["My notes"]]
        breadcrumb = f'[auto {date}] {signal}: "{source}"'
        new_notes = (existing_notes + "\n" + breadcrumb) if existing_notes else breadcrumb
        ws.update_cell(rownum, notes_col, new_notes)
        print(f"WROTE|{rownum}|{company}|{role}|{cur_status}->|{new_status}")


if __name__ == "__main__":
    main()
