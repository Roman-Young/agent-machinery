#!/usr/bin/env python3
"""bus.py — the agent message bus. A shared SQLite store that the orchestrator and
every spawned agent write to (by thread) and read on each write, so one seat can SEE
and STEER the whole fleet instead of juggling N blind, disconnected chats.

WHY THIS EXISTS (2026-07-20)
Roman is moving toward the multi-agent org sketched with Dan: Roman = CEO, Cairo =
CTO/orchestrator, deep-work agents = managers, sub-agents = workers. Separate chats /
headless agents cannot talk to each other directly, so they talk THROUGH this table:
the orchestrator writes a brief under a thread id, an agent reads it to start, writes
back at every milestone / decision / uncertainty / completion, and reads on every write
so steering flows both ways. `needs_input` fires an ntfy push so a blocked agent pulls a
human in instead of guessing or stalling silently.

DELIBERATE DEPARTURES, both justified in docs/message-bus.md:
  * MULTI-WRITER. The memory layer keeps the one-writer rule (Rule 5). The bus is a
    SEPARATE coordination store, made safe by WAL + busy_timeout + append-only messages
    (every write is an INSERT; rows are never mutated, so there is no update race). seq
    is assigned inside a BEGIN IMMEDIATE transaction so two writers can never collide.
  * The DB lives ONLY in my-context/local-only/ — gitignored (never reaches GitHub, even
    the private repo) and inside the nightly backup tarball. Message content is personal
    data; it must never move out of local-only/. The PII gate uses `grep -I` and skips
    binaries, so the DB's safety is its LOCATION, not the gate.

House style: stdlib only, deterministic, path-free (reads BUS_DB from the environment),
Pacific timestamps via OWNER_TZ to match render-tasks.py. No `sqlite3` CLI on the box —
everything goes through this module.
"""
import argparse
import os
import secrets
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
import sqlite3

OWNER_TZ = os.environ.get("OWNER_TZ", "America/Los_Angeles")

KINDS = ("prompt", "milestone", "decision", "uncertainty",
         "question", "completion", "override", "note")
STATUSES = ("open", "working", "blocked", "needs_input", "done", "killed")

SCHEMA = """
CREATE TABLE IF NOT EXISTS threads (
  id         TEXT PRIMARY KEY,
  title      TEXT NOT NULL,
  project    TEXT,
  created_by TEXT NOT NULL,
  parent_id  TEXT,
  status     TEXT NOT NULL DEFAULT 'open',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  thread_id   TEXT NOT NULL REFERENCES threads(id),
  seq         INTEGER NOT NULL,
  sender      TEXT NOT NULL,
  kind        TEXT NOT NULL,
  body        TEXT NOT NULL,
  needs_input INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_msg_thread ON messages(thread_id, seq);
CREATE INDEX IF NOT EXISTS idx_thread_status ON threads(status);
CREATE INDEX IF NOT EXISTS idx_msg_needsinput ON messages(needs_input) WHERE needs_input = 1;
"""
USER_VERSION = 1


# ── helpers ───────────────────────────────────────────────────────────────────

def db_path() -> Path:
    """BUS_DB wins; else derive from CONTEXT_DIR; else the conventional default.
    Works whether or not .env has been sourced (an agent may call this directly)."""
    if os.environ.get("BUS_DB"):
        return Path(os.environ["BUS_DB"])
    ctx = os.environ.get("CONTEXT_DIR") or str(Path.home() / "agent" / "my-context")
    return Path(ctx) / "local-only" / "agent_bus.db"


def now_iso() -> str:
    return datetime.now(ZoneInfo(OWNER_TZ)).isoformat(timespec="seconds")


def connect(create: bool = False) -> sqlite3.Connection:
    p = db_path()
    if not p.exists() and not create:
        sys.exit(f"bus: no DB at {p} — run `bus.py init` first")
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(p), timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def notify(title: str, message: str) -> None:
    """Fire an alert-tier ntfy push via the existing notify.sh. Best-effort: a failed
    push must never fail the write (but we say so on stderr rather than swallow silently)."""
    script = Path(__file__).resolve().parent / "notify.sh"
    try:
        subprocess.run([str(script), "alert", title, message],
                       check=True, timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:  # noqa: BLE001 — notify is best-effort by design
        print(f"bus: WARNING — needs_input written but ntfy push failed: {e}",
              file=sys.stderr)


def new_thread_id(project: str | None) -> str:
    slug = "".join(c for c in (project or "").lower() if c.isalnum())[:12]
    tail = secrets.token_hex(3)
    return f"th_{slug}_{tail}" if slug else f"th_{tail}"


def require_thread(conn: sqlite3.Connection, tid: str) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM threads WHERE id=?", (tid,)).fetchone()
    if not row:
        sys.exit(f"bus: no such thread '{tid}'")
    return row


# ── commands ──────────────────────────────────────────────────────────────────

def cmd_init(_args) -> None:
    conn = connect(create=True)
    conn.executescript(SCHEMA)
    conn.execute(f"PRAGMA user_version={USER_VERSION}")
    conn.commit()
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    ver = conn.execute("PRAGMA user_version").fetchone()[0]
    conn.close()
    print(f"bus: initialized {db_path()}  (journal_mode={mode}, user_version={ver})")


def _append(conn, tid, sender, kind, body, needs_input) -> int:
    """Append one message inside an IMMEDIATE transaction so seq is race-safe."""
    conn.isolation_level = None  # manual transaction control
    conn.execute("BEGIN IMMEDIATE")
    seq = conn.execute(
        "SELECT COALESCE(MAX(seq), 0) + 1 FROM messages WHERE thread_id=?", (tid,)
    ).fetchone()[0]
    ts = now_iso()
    conn.execute(
        "INSERT INTO messages(thread_id, seq, sender, kind, body, needs_input, created_at)"
        " VALUES(?,?,?,?,?,?,?)",
        (tid, seq, sender, kind, body, 1 if needs_input else 0, ts),
    )
    # derive the thread's new status from this message. The 'prompt' (the brief) leaves the
    # thread 'open' — a briefed thread hasn't been worked yet; only a real work message
    # flips a fresh thread to 'working'.
    if needs_input:
        conn.execute("UPDATE threads SET status='needs_input', updated_at=? WHERE id=?", (ts, tid))
    elif kind == "completion":
        conn.execute("UPDATE threads SET status='done', updated_at=? WHERE id=?", (ts, tid))
    elif kind == "override":
        conn.execute("UPDATE threads SET status='working', updated_at=? WHERE id=?", (ts, tid))
    elif kind == "prompt":
        conn.execute("UPDATE threads SET updated_at=? WHERE id=?", (ts, tid))
    else:
        conn.execute(
            "UPDATE threads SET status=CASE WHEN status='open' THEN 'working' ELSE status END,"
            " updated_at=? WHERE id=?", (ts, tid))
    conn.execute("COMMIT")
    return seq


def cmd_spawn(args) -> None:
    conn = connect()
    if args.parent:
        require_thread(conn, args.parent)
    tid = new_thread_id(args.project)
    ts = now_iso()
    conn.execute(
        "INSERT INTO threads(id, title, project, created_by, parent_id, status, created_at, updated_at)"
        " VALUES(?,?,?,?,?,?,?,?)",
        (tid, args.title, args.project, args.by, args.parent, "open", ts, ts),
    )
    conn.commit()
    _append(conn, tid, args.by, "prompt", args.prompt, False)
    conn.close()
    print(tid)


def cmd_write(args) -> None:
    if args.kind not in KINDS:
        sys.exit(f"bus: --kind must be one of {', '.join(KINDS)}")
    conn = connect()
    t = require_thread(conn, args.thread)
    seq = _append(conn, args.thread, args.by, args.kind, args.body, args.needs_input)
    conn.close()
    print(f"{args.thread} #{seq} {args.kind}" + (" [needs-input]" if args.needs_input else ""))
    if args.needs_input:
        notify(
            f"🔔 needs input — {t['title']}",
            f"Thread `{args.thread}` ({t['project'] or 'no project'}) is waiting:\n\n"
            f"{args.body}\n\n"
            f"Steer it: `bus.py write {args.thread} --kind override --by roman \"...\"`",
        )


def _fmt_msg(m: sqlite3.Row) -> str:
    flag = "  🔔 NEEDS INPUT" if m["needs_input"] else ""
    return (f"  #{m['seq']:<3} [{m['created_at']}] {m['sender']} · {m['kind']}{flag}\n"
            f"      {m['body']}")


def cmd_read(args) -> None:
    conn = connect()
    t = require_thread(conn, args.thread)
    rows = conn.execute(
        "SELECT * FROM messages WHERE thread_id=? AND seq>? ORDER BY seq",
        (args.thread, args.since),
    ).fetchall()
    conn.close()
    if args.json:
        import json
        print(json.dumps({"thread": dict(t), "messages": [dict(r) for r in rows]},
                         indent=2))
        return
    print(f"═ {t['id']}  [{t['status']}]  {t['title']}  ({t['project'] or '—'})")
    if not rows:
        print("  (no messages after seq %d)" % args.since)
    for m in rows:
        print(_fmt_msg(m))


def cmd_watch(args) -> None:
    conn = connect()
    rows = conn.execute(
        "SELECT t.*, "
        "  (SELECT COUNT(*) FROM messages m WHERE m.thread_id=t.id AND m.needs_input=1) AS waiting, "
        "  (SELECT COUNT(*) FROM messages m WHERE m.thread_id=t.id) AS msgs "
        "FROM threads t "
        + ("" if args.all else "WHERE t.status NOT IN ('done','killed') ")
        + "ORDER BY t.updated_at DESC",
    ).fetchall()
    conn.close()
    if not rows:
        print("bus: no active threads")
        return
    print(f"{'THREAD':<22} {'STATUS':<11} {'MSGS':>4} {'WAIT':>4}  PROJECT / TITLE")
    for t in rows:
        flag = "🔔" if t["waiting"] else "  "
        print(f"{t['id']:<22} {t['status']:<11} {t['msgs']:>4} {t['waiting']:>3}{flag} "
              f"{(t['project'] or '—')} / {t['title']}")


def cmd_status(args) -> None:
    if args.set not in STATUSES:
        sys.exit(f"bus: --set must be one of {', '.join(STATUSES)}")
    conn = connect()
    require_thread(conn, args.thread)
    conn.execute("UPDATE threads SET status=?, updated_at=? WHERE id=?",
                 (args.set, now_iso(), args.thread))
    conn.commit()
    conn.close()
    print(f"{args.thread} -> {args.set}")


def cmd_get(args) -> None:
    """Print one field of a thread — a clean hook for shell scripts (spawn-agent.sh)."""
    conn = connect()
    row = require_thread(conn, args.thread)
    conn.close()
    if args.field not in row.keys():
        sys.exit(f"bus: no field '{args.field}' (have: {', '.join(row.keys())})")
    val = row[args.field]
    print("" if val is None else val)


def cmd_snapshot(args) -> None:
    """Consistent copy via VACUUM INTO — safe even against a mid-write live DB.
    Used by backup-context.sh to put a coherent snapshot inside the nightly tarball."""
    conn = connect()
    dest = Path(args.path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        dest.unlink()  # VACUUM INTO refuses to overwrite
    conn.execute("VACUUM INTO ?", (str(dest),))
    conn.close()
    print(f"bus: snapshot -> {dest}")


# ── argparse ──────────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="bus.py", description="agent message bus")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init", help="create the DB + schema (idempotent)").set_defaults(fn=cmd_init)

    sp = sub.add_parser("spawn", help="create a thread + its initial prompt")
    sp.add_argument("--title", required=True)
    sp.add_argument("--project", default=None)
    sp.add_argument("--parent", default=None, help="parent thread id (hierarchy)")
    sp.add_argument("--by", default="cairo")
    sp.add_argument("--prompt", required=True)
    sp.set_defaults(fn=cmd_spawn)

    rd = sub.add_parser("read", help="messages on a thread")
    rd.add_argument("thread")
    rd.add_argument("--since", type=int, default=0, help="only seq > SINCE")
    rd.add_argument("--json", action="store_true")
    rd.set_defaults(fn=cmd_read)

    wr = sub.add_parser("write", help="append a message to a thread")
    wr.add_argument("thread")
    wr.add_argument("--kind", required=True, help=f"one of: {', '.join(KINDS)}")
    wr.add_argument("--by", default="cairo")
    wr.add_argument("--needs-input", action="store_true", dest="needs_input",
                    help="flag a decision request + fire an ntfy alert")
    wr.add_argument("body")
    wr.set_defaults(fn=cmd_write)

    wa = sub.add_parser("watch", help="dashboard of threads (needs-input first)")
    wa.add_argument("--all", action="store_true", help="include done/killed")
    wa.set_defaults(fn=cmd_watch)

    st = sub.add_parser("status", help="set a thread's status")
    st.add_argument("thread")
    st.add_argument("--set", required=True, help=f"one of: {', '.join(STATUSES)}")
    st.set_defaults(fn=cmd_status)

    gt = sub.add_parser("get", help="print one thread field (for scripting)")
    gt.add_argument("thread")
    gt.add_argument("field", help="status|title|project|created_by|parent_id|created_at|updated_at")
    gt.set_defaults(fn=cmd_get)

    sn = sub.add_parser("snapshot", help="VACUUM INTO a consistent copy (for backup)")
    sn.add_argument("path")
    sn.set_defaults(fn=cmd_snapshot)
    return p


def main() -> None:
    args = build_parser().parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
