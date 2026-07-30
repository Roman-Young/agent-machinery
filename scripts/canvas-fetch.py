#!/usr/bin/env python3
"""canvas-fetch.py — the read-only Canvas reader (the ONLY component that touches the web).

UCSD bars Canvas API tokens and the iCal feed is insufficient, so we drive a persistent,
already-logged-in headless Chrome (one-time SSO+Duo login, session kept in the profile) and call
Canvas's OWN JSON API from *inside* the session — the browser's session cookie authenticates the
request, no token needed. Talks to Chrome over CDP (loopback debug port) and prints ONE JSON
object to stdout:

    {"status":"ok","user":{...},"planner":[...],"courses":[...]}
    {"status":"logged_out"}                 # session expired -> caller pages Roman to re-auth
    {"status":"error","reason":"..."}

It has NO write access to anything and never parses HTML — only the versioned JSON API. Run it via
`uv run --with websockets python3 canvas-fetch.py` so `websockets` is an EPHEMERAL dep (nothing
permanently installed — house style). Config from env: KAIRO_CDP_URL, CANVAS_BASE_URL.

Learned the hard way (2026-07-30 spike): a `--headless` Chrome's default user-agent contains
"HeadlessChrome", which UCSD Duo BLOCKS (it dead-ends on the two-step help page instead of the push
prompt). The Chrome that serves this MUST be launched with a spoofed normal UA — see canvas-chrome.sh.
"""
import asyncio
import json
import os
import sys
import urllib.request

import websockets  # provided ephemerally by `uv run --with websockets`

CDP = os.environ.get("KAIRO_CDP_URL", "http://127.0.0.1:9333")
BASE = os.environ.get("CANVAS_BASE_URL", "https://canvas.ucsd.edu")
SENT = "@@@KAIRO@@@"          # field separator unlikely to appear in Canvas data
PAGE_CAP = 25                 # hard bound on pagination loops (safety)


def _list_targets():
    return json.load(urllib.request.urlopen(CDP + "/json/list", timeout=10))


def canvas_page_ws():
    """Return the webSocketDebuggerUrl of a page target already on the Canvas origin; if none is
    open, ask Chrome to open one, then look again. None if the browser is unreachable/blank."""
    for t in _list_targets():
        if t.get("type") == "page" and t.get("url", "").startswith(BASE):
            return t["webSocketDebuggerUrl"]
    try:  # open a Canvas tab (PUT /json/new?<url>) and retry
        urllib.request.urlopen(
            urllib.request.Request(CDP + "/json/new?" + BASE + "/", method="PUT"), timeout=10)
    except Exception:
        pass
    for t in _list_targets():
        if t.get("type") == "page" and t.get("url", "").startswith(BASE):
            return t["webSocketDebuggerUrl"]
    return None


async def api_get(ws, path, mid):
    """GET a Canvas API path from inside the logged-in page. Returns (status:int, link:str, body:str)."""
    url = path if path.startswith("http") else (BASE + path)
    expr = ("fetch(%r,{headers:{Accept:'application/json'},credentials:'include'})"
            ".then(r=>r.text().then(b=>r.status+%r+(r.headers.get('Link')||'')+%r+b))"
            % (url, SENT, SENT))
    await ws.send(json.dumps({"id": mid, "method": "Runtime.evaluate",
        "params": {"expression": expr, "awaitPromise": True, "returnByValue": True}}))
    while True:
        msg = json.loads(await ws.recv())
        if msg.get("id") == mid:
            r = msg.get("result", {})
            if "exceptionDetails" in r:
                return -1, "", "JS_EXCEPTION"
            val = r.get("result", {}).get("value") or ""
            status, _, rest = val.partition(SENT)
            link, _, body = rest.partition(SENT)
            try:
                status = int(status)
            except ValueError:
                status = -1
            return status, link, body


def _next_link(link_header):
    for part in (link_header or "").split(","):
        seg = part.split(";")
        if len(seg) >= 2 and 'rel="next"' in seg[1] and seg[0].strip():
            return seg[0].strip().strip("<>").strip()
    return None


def _looks_logged_out(status, body):
    if status in (401, 403):
        return True
    stripped = (body or "").lstrip()
    # A valid JSON body is NEVER a login page — parse first. Only sniff for SSO/HTML markers when the
    # body is not JSON, else a course/assignment named "Triton…"/"…SAML…" would false-trigger re-auth.
    if stripped[:1] in ("{", "["):
        try:
            json.loads(stripped)
            return False
        except ValueError:
            pass
    head = stripped[:300].lower()
    return head.startswith("<") or "saml" in head or "single sign" in head or "triton" in head


class LoggedOut(Exception):
    pass


async def _paged(ws, path, base_mid):
    items, mid, url = [], base_mid, path
    for _ in range(PAGE_CAP):
        status, link, body = await api_get(ws, url, mid); mid += 1
        if _looks_logged_out(status, body):
            raise LoggedOut()
        if status != 200:
            raise RuntimeError("HTTP %s on %s" % (status, url))
        items.extend(json.loads(body))
        url = _next_link(link)
        if not url:
            break
    return items


async def main():
    try:
        # Inside the try: if Chrome/the CDP port is down, canvas_page_ws() raises URLError, and the
        # generic except below turns it into clean error JSON (not a traceback + exit 1).
        ws_url = canvas_page_ws()
        if not ws_url:
            print(json.dumps({"status": "error", "reason": "no_canvas_tab_or_browser_down"}))
            return
        async with websockets.connect(ws_url, max_size=None) as ws:
            await ws.send(json.dumps({"id": 1, "method": "Runtime.enable"}))
            s, _, body = await api_get(ws, "/api/v1/users/self", 5)
            if _looks_logged_out(s, body):
                print(json.dumps({"status": "logged_out"})); return
            if s != 200:
                print(json.dumps({"status": "error", "reason": "users_self_http_%s" % s})); return
            user = json.loads(body)

            # Active courses first, then EACH course's assignments — the authoritative deadline
            # source (the planner only surfaces upcoming-incomplete items, so it silently misses
            # assignments; the assignments endpoint carries due_at + the student's submission).
            courses = await _paged(ws, "/api/v1/courses?enrollment_state=active&per_page=100", 400)
            assignments = []
            for ci, c in enumerate(courses):
                cid = c.get("id")
                if cid is None:
                    continue
                base = 1000 + ci * (PAGE_CAP + 2)   # disjoint message-id range per course
                raw = await _paged(
                    ws, "/api/v1/courses/%s/assignments?include[]=submission&per_page=100" % cid, base)
                for a in raw:
                    sub = a.get("submission") or {}
                    assignments.append({
                        "course_id": cid,
                        "course_name": c.get("name"),
                        "id": a.get("id"),
                        "name": a.get("name"),
                        "due_at": a.get("due_at"),                       # ISO8601 UTC or null
                        "html_url": a.get("html_url"),
                        "points_possible": a.get("points_possible"),
                        "submitted": sub.get("submitted_at") is not None,
                        "workflow_state": sub.get("workflow_state"),      # unsubmitted|submitted|graded|pending_review
                        "graded": sub.get("workflow_state") == "graded",
                    })
    except LoggedOut:
        print(json.dumps({"status": "logged_out"})); return
    except Exception as e:  # noqa: BLE001 — any failure is a hard, loud error for the caller
        print(json.dumps({"status": "error", "reason": type(e).__name__ + ": " + str(e)[:200]})); return

    print(json.dumps({
        "status": "ok",
        "user": {"id": user.get("id"), "name": user.get("name")},
        "courses": [{"id": c.get("id"), "name": c.get("name")} for c in courses],
        "assignments": assignments,
    }))


if __name__ == "__main__":
    asyncio.run(main())
