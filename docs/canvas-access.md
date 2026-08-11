# Canvas access — the browser-session route (BUILT + PROVEN 2026-07-30)

UCSD **bars student API tokens** and the **iCal feed is insufficient** (dates only, no submission
status; Roman's call). So Canvas is reached through a **persistent, logged-in headless Chrome** that
holds the SSO+Duo session; deadlines come from Canvas's **own JSON API**, called from inside that
session. Proven end-to-end on the live account 2026-07-30.

> Supersedes the old "SOLVED without a token — use the calendar feed" version of this doc (the iCal
> route was rejected 2026-07-19). It also supersedes T21's "Playwright-MCP" framing.

## The thesis (why this is robust)

**The hard part is AUTH, not reading.** Once a browser is past UCSD SSO + Duo, you do NOT scrape
HTML — you call Canvas's versioned JSON API (`/api/v1/…`) from a page on the `canvas.ucsd.edu`
origin; the browser's **session cookie** authenticates it (GET reads need no CSRF token). Structured
JSON, immune to page-layout changes. The browser's only job is to hold the session.

## Two gotchas that are load-bearing (both cost real time in the spike)

1. **Headless UA is BLOCKED by Duo.** A `--headless` Chrome's default user-agent contains
   `HeadlessChrome`; UCSD Duo detects it and dead-ends the login on the two-step *help* page instead
   of showing the push prompt. **The fix is a spoofed normal `Chrome/…` UA** (`--user-agent=…` in
   `canvas-chrome.sh`). Never remove it.
2. **The assignments endpoint is authoritative, NOT the planner.** `/api/v1/planner/items` only
   returns *upcoming-incomplete* items and silently omits assignments — it returned **zero** for a
   course that had exams. Enumerate active courses, then pull
   **`/api/v1/courses/:id/assignments?include[]=submission`** per course (due dates + submission).

## Components (all in agent-machinery/scripts/)

| File | Role |
|---|---|
| `canvas-chrome.sh` | Ensures the persistent headless Chrome is up: `--headless=new`, loopback debug port (`KAIRO_CDP_PORT`, default 9333), persistent `--user-data-dir` (`KAIRO_CANVAS_PROFILE`), **spoofed UA**, `--disable-blink-features=AutomationControlled`. Idempotent (exits if already up). Runs at boot + every 10 min via cron (the watchdog). |
| `canvas-login.sh` | The ~2-min re-auth helper. Prints the exact `ssh -L …` tunnel + `chrome://inspect` checklist (SERVER_IP from `.env`). Human step only. |
| `canvas-fetch.py` | Read-only reader — the ONLY web-toucher. Drives Chrome over CDP (`uv run --with websockets`, ephemeral dep), pulls users/self + active courses + per-course assignments. Emits one JSON object; detects `logged_out`. No write access. |
| `canvas-sync.py` | Deterministic, LLM-free merge into `tasks.yaml` (`uv run --with ruamel.yaml`, comment-preserving). Add / update-on-move / conservative auto-close (on `submitted`) / skip; dedup on `[canvas:assignment/<id>]` in notes; idempotent. Never touches non-Canvas tasks. |
| `canvas-sync.sh` | Orchestrator (own flock+timeout+fail-loud; NOT a `claude -p` job): ensure Chrome → fetch → merge → `render-tasks.py`. Asserts `SOURCES: canvas=ok`; on `logged_out`/FAIL, pings Roman to re-auth. |

**Cron:** `@reboot` + `*/10 * * * *` canvas-chrome.sh (watchdog); `15 8,14,20 * * *` canvas-sync.sh.

## The one-time login (and ~weekly re-auth)

`canvas-login.sh` (2026-08-10: auto-discovers the target) collapses this to two human actions —
run the tunnel, approve Duo. It queries the CDP `/json/list` endpoint server-side and prints the
exact "inspect fallback" DevTools URL pre-selected on the live ucsd.edu tab (same loopback port
both sides of the tunnel, so the URL computed on the server is valid once the tunnel's up) —
no more manually opening `chrome://inspect`, adding the target under Configure, or hunting the
target list for the right entry:

1. On the Mac: `ssh -L 9333:127.0.0.1:9333 roman@<server>` (leave open).
2. Paste the URL `canvas-login.sh` printed straight into Mac Chrome's address bar.
3. Log in → approve Duo push → **tick "remember this device."**
4. Session lives in the profile.

Falls back to the old manual path (chrome://inspect → Configure → add `127.0.0.1:9333` →
**inspect fallback** on the target — the remote Chrome is newer, so use *fallback*) only if
target auto-discovery fails (e.g. no matching tab is open yet).

**Cadence:** UCSD Duo "remember this device" ≈ **7 days**, refreshable → expect a ~2-minute re-login
roughly weekly. `canvas-sync` detects the lapse (fetch returns an SSO/HTML page or 401) and pushes an
ntfy alert with the re-auth command. Between lapses everything is automatic.

## Security (non-negotiable)

- Debug port bound to **127.0.0.1 only**; reached exclusively over the SSH tunnel. An open CDP port
  is unauthenticated RCE — **never** `--remote-debugging-address=0.0.0.0`.
- Untrusted web content never reaches a shell or an edit-capable LLM: the reader only reads via CDP,
  the merge is deterministic Python, and they never share a privilege context.
- Not Browser Use Cloud (would upload cookies to a vendor); `browser-harness` telemetry stays off.

## RAM (measured 2026-07-30)

Logged-in Chrome + dashboard + API ≈ **~600 MB** real; ~5.6 GB free on the 8 GB + 4 GB-swap box.
Comfortable; the 16 GB upgrade proved unnecessary.

## Beyond Canvas — this is a general capability

Canvas is the safe, read-only first use of "Kairo drives a logged-in browser." The same persistent
profile + CDP can **read any login-walled portal** (WebReg/enrollment, grades, financial aid,
package tracking) and, gated by the **approval protocol (P2)**, **take actions** (order, book,
submit) — where every irreversible/spending step pauses and surfaces the exact action for approval,
never autonomous. Per-site playbooks live as `skills/browser/<host>/` skills (the browser-harness
domain-skills idea), minted propose-and-wait, so the capability compounds. See the plan file
`~/.claude/plans/hello-cairo-this-chat-delightful-whale.md` (Phase 3).

## Content (syllabi, files) — still the manual drop

The JSON API gives dates + submission status, not syllabus text/rubrics/files. Keep dropping each
syllabus into `courses/<term>/<course>/syllabus.md` per quarter. A browser-driven content pull is a
later, optional layer (Phase 3), not built.
