# The terminal seat — Kairo in a terminal, with the harness as a switch

**Status:** scaffolded, not activated. Nothing here changes the running system until a phase
below is deliberately started. Owner-specific audit findings, costs and decisions live in the
private context repo (`reference/omp-transition-audit-*.md`), not here.

## What it is

A persistent, reconnectable terminal session that holds Kairo's interactive harness:

```
 laptop / VS Code Remote-SSH ─ ssh -t ──┐
 phone (Blink, Termius, …) ─── mosh ────┼──▶  tmux (private socket "kairo")
                                        │        └─ window per chat, cwd = workspace root
                                        │             └─ harness TUI: claude  |  omp
                                        │                  └─ reads the same context repo
 ntfy (phone) ◀── seat-notify.sh ◀── harness hook (turn finished / needs you, only when away)
```

- **Persistence:** tmux holds the session; a dropped connection doesn't end the conversation.
- **The harness is a switch, not a migration.** `KAIRO_HARNESS=claude|omp`. Everything around
  it — tmux, notifications, the workspace, the memory — is identical, so switching (or
  backing out) is one environment variable.

| File | Role |
|---|---|
| `scripts/kairo-term.sh` | launcher: attach / `new [name]` / `ls` / `check`; preflight + subscription guard |
| `config/tmux-kairo.conf` | tmux settings both TUIs need (extended keys, passthrough, true colour, mouse) |
| `scripts/hooks/seat-notify.sh` | push when a turn ends or the agent is waiting — only if you're away |
| `config/omp-kairo-profile.yml` | hardened omp profile (every key validated against the installed binary) |
| `.omp/agents/fleet-researcher.md` | omp port of the no-shell worker (omp ignores `.claude/agents`) |
| `scripts/omp-seat-check.sh` | acceptance test: effective config == template, guard, identity, boundary |

## Compose overlay — instant typing over a long link (Mac)

A terminal UI on a distant server pays the full round trip on every keystroke, and mosh's
predictive echo can't help a TUI that redraws its own input box. The fix lives on the client:
type locally, send the finished message once.

```
Mac: `kairo`  →  local tmux (private socket, prefix C-])
                 ├─ top:    ssh -t <host> kairo-term.sh  (reconnect loop; mosh optional)  — the real seat
                 └─ bottom: kairo-compose (respawn loop)  — instant local typing, history, Tab /commands
Enter → ONE ssh call (reuses a background shared connection) → kairo-send.sh → checks → paste + Enter
```

**kairo-send.sh refuses to type unless it's safe** (each check exists because a test or review
showed the failure): the harness is actually running in the pane (if it exited, the pane is a
shell and the message would run as commands) · its UI is up (not booting) · no approval prompt is
open (paste + Enter would pick the default, *Approve*) · copy-mode is exited first (keys would be
eaten while scrolled back) · any leftover draft is cleared with Ctrl+C, spaced ≥0.7 s apart (two
within 500 ms quit omp). Then: ANSI sequences and control characters are stripped (an embedded
`ESC[201~` breaks out of bracketed paste into live keystrokes — tmux does not filter it; strip with
`LC_ALL=C` or the ranges silently fail), a trailing space is added if the last token could open an
autocomplete popup, and paste + Enter go in ONE tmux command. A lock serialises concurrent sends.
`--approve` / `--deny` answer an open approval prompt (Enter / Down+Enter) and refuse otherwise.

**The seat** (`kairo-term.sh`) launches omp with `--continue` (a restart resumes the conversation)
and a seat-only settings overlay, `config/omp-seat-overlay.yml`, via `PI_CONFIG_FILES` (verifiable
with `omp config get`; the `config` subcommand ignores a `--config` flag): large-paste menu off
(otherwise ≥100-line pastes open a menu that swallows the Enter — verified), resize keeps scrollback,
no inline images, `task.maxConcurrency: 3`, auto-QA off, secret redaction on. Remote launches
don't get the login shell's PATH, so the launcher adds the user tool dirs itself.

**kairo-compose:** pasted multi-line text arrives as one message (lines that arrive together are
joined, and a `:` line inside a paste is text, not a command) · `:paste` for code (tabs kept) ·
`:e` editor (pane zooms; draft kept if the send fails) · failed sends are kept → `:retry` · messages
starting with `!` or `$ ` (shell / python, run by omp **without approval**) ask first · `:approve`
`:deny` `:switch` (Alt+P: session-only model) `:effort` (Shift+Tab) `:status` · history is 0600,
saved after each send, without `:` commands · plain prompt (colour codes garble readline).
Short ssh keepalives: a dead link fails in ~10 s, retried once on a fresh connection.

**Why ssh, not mosh, for the top half:** mosh keeps no scrollback and doesn't carry mouse-wheel
events, so you couldn't scroll back through a long reply. With ssh the wheel reaches the seat's
tmux (50k lines). Typing latency no longer matters there — it happens in the compose box.

Install / update on the Mac: `install-kairo-mac.sh user@host` (server address lives in
`~/.config/kairo/server`, never in this repo). `kairo restart` restarts the seat on the server.
Owner choices for the seat (harness, profile, guard override) live in `~/.config/kairo/seat.env`.

## The three layers — only one of them is actually in question

| Layer | Today | Moves to the seat? |
|---|---|---|
| **Interface** (how you reach the agent) | a phone app relaying to Claude Code | **Yes** — that is the point of the seat |
| **Interactive harness** (the TUI) | Claude Code | **Either** — the seat runs `claude` or `omp` |
| **Headless automation** (cron → `run-agent.sh` → `claude -p`, bus workers) | Claude Code print mode | **No** — see below |

**Why headless automation stays on `claude -p`** (verified in the omp source audit):
- `omp -p --tools …` is **not a hard allowlist**: MCP tools and extension/custom tools attach
  regardless, so it cannot enforce the bus workers' "no shell" trust boundary. The hard
  restriction exists only in omp's SDK (`restrictToolNames`), i.e. a rewrite, not a flag swap.
- No max-turns equivalent; `--max-time` ending at a turn boundary appears to exit 0.
- `omp` reads a non-TTY stdin to EOF even when a prompt is passed — cron must pass `</dev/null`.
- Jobs that use claude.ai-hosted connectors (Gmail/Drive/Calendar) have no omp equivalent.
- The subscription constraint below.

## The constraint that decides the omp route

Anthropic's Consumer Terms forbid using **Claude Free/Pro/Max OAuth tokens in any product
other than Claude Code / Claude.ai**, and Anthropic enforces it without notice — including
automatic account bans during the January-2026 rollout
([The Register](https://www.theregister.com/2026/02/20/anthropic_clarifies_ban_third_party_claude_access/),
[VentureBeat](https://venturebeat.com/technology/anthropic-cracks-down-on-unauthorized-claude-usage-by-third-party-harnesses),
[Claude Code legal & compliance](https://code.claude.com/docs/en/legal-and-compliance)).
omp's Anthropic OAuth works by presenting itself as Claude Code (its source sends a
`claude-cli/…` user-agent, `x-app: cli`, and "You are Claude Code…" as the first system block).

So Claude under omp means an **API key** (pay-per-token) or a cloud provider; other model
vendors have their own terms. `kairo-term.sh` refuses to start omp if the profile stores an
Anthropic subscription login (checked without ever reading the secret);
`KAIRO_ALLOW_SUBSCRIPTION_OAUTH=1` overrides, and says so loudly.

## Phases — each has an entry gate, an exit gate, and a rollback

### Phase A — terminal seat on Claude Code (no new risk)
Delivers "work in a terminal" immediately, on the harness the subscription is licensed for,
keeping claude.ai connectors, `permissions.deny`, custom agents and hooks.

1. `scripts/kairo-term.sh check` → `scripts/kairo-term.sh` (from a laptop: `ssh -t <host> <path>/kairo-term.sh`).
2. Phone: a terminal app with mosh → `mosh <host> -- <path>/kairo-term.sh`. Voice: the phone
   keyboard's dictation works in any terminal app. Files: drop into Drive and ask the agent.
3. Install the notification hook — add to `~/.claude/settings.json` (it no-ops outside the seat,
   so headless jobs and app sessions are unaffected):
   ```json
   "hooks": {
     "Stop":         [{ "hooks": [{ "type": "command", "command": "<workspace>/agent-machinery/scripts/hooks/seat-notify.sh" }] }],
     "Notification": [{ "hooks": [{ "type": "command", "command": "<workspace>/agent-machinery/scripts/hooks/seat-notify.sh" }] }]
   }
   ```
4. Run it alongside the phone app for a trial period. **Exit gate:** a stretch of real days with
   no reach for the app, and a list of anything missed.
**Rollback:** stop using it. Nothing else changed.

### Phase B — omp in the seat (trial, API key)
**Entry gate:** a decision to pay per token for Claude under omp (or to use another vendor), with
a hard monthly spend cap set in the provider console first.
1. Install the profile: `mkdir -p ~/.omp/profiles/kairo/agent && cp config/omp-kairo-profile.yml ~/.omp/profiles/kairo/agent/config.yml`.
2. Authenticate the profile with an **API key** (never `/login` with a subscription).
3. Activate the no-shell worker: link `<workspace>/.omp/agents` → `agent-machinery/.omp/agents`.
4. Fix the seat identity (`<workspace>/AGENTS.md` — under omp it shadows `CLAUDE.md`): model
   route, the connector-delegation note, the profile path of `bash.patterns`, `/todo` collision.
5. Pin the version; `scripts/omp-seat-check.sh --live` must be all-PASS.
6. `KAIRO_HARNESS=omp scripts/kairo-term.sh new omp` — run it next to the Claude window.
7. Phone pushes under omp: port `seat-notify.sh` to an omp hook (`agent_end`,
   `tool_approval_requested`; hooks are TS/JS factories — `docs/hooks.md` upstream).
**Exit gate:** measured spend within budget, zero config drift in `omp-seat-check.sh`, and
the worker boundary re-verified. **Rollback:** `KAIRO_HARNESS=claude` (default).

### Phase C — retire the phone app (only after A's exit gate)
1. Stop, don't uninstall: disable the watchdog cron line, stop the daemon; keep it installed
   ~30 days as the rollback.
2. Update `healthcheck.sh` (it alerts when the app's daemon is down) and the interface lines in
   the context repo. 3. Uninstall after the window.
**What is genuinely lost** (no terminal equivalent): phone-mic voice *inside* the app, photo
upload from the phone into a chat, and a phone-side chat list. omp's `/collab` link is a partial
stand-in, but its relay is third-party, not self-hostable, and the link is bearer access to a
shell-holding agent — not recommended as the phone channel.

## omp hardening (stock default → seat profile)

| Setting | omp stock | Seat | Why |
|---|---|---|---|
| `tools.approvalMode` | `yolo` (prompts for nothing) | `write` + CLI `--approval-mode` pin | outward/irreversible actions must pause; CLI pin can't be overridden by a config edit |
| `tools.approval.{bash,eval,task}` | — | `prompt` | enforced even under yolo; `eval` can reach a shell `bash.patterns` never sees |
| `web_search` / `fetch` / `browser` | on | off | untrusted ingestion must not share a context with a shell; default search chain egresses to keyless third parties |
| `dev.autoqa` | on | off | can POST model-written reports + install id |
| `secrets.enabled` | off | on | redacts credential-shaped tokens (not a read restriction) |
| `task.maxConcurrency` | 32 | 3 | each subagent is a process (~250 MB) — 32 would OOM a small box |
| `memory.backend` / `autolearn` | off / off | off / off | the context repo is the only memory |
| `startup.checkUpdate`, `marketplace.autoUpdate` | on / notify | off / off | upgrades are deliberate |
| `modelRoles` | unset | pinned | background jobs can't route conversation text to another authenticated vendor |

**Known gaps even when hardened:** omp ignores Claude Code's `permissions.deny` (e.g. reads of
`.env`) and auto-approves `read` in every mode; `write` mode auto-approves file writes and MCP
tools (add `tools.approval.mcp__<name>: prompt` before adding any MCP server that can act);
subagents get MCP/extension tools regardless of their `tools:` list.

## Upgrading omp
omp ships roughly daily and ~a quarter of recent releases carried breaking changes (renamed
settings, changed context-file loading — e.g. user-level `~/.claude/CLAUDE.md` became opt-in and
project `CLAUDE.md` loading was added in 18.1.x). Procedure: read the CHANGELOG's *Breaking*
sections since the pinned version → upgrade → `scripts/omp-seat-check.sh --live` → update the pin.
Never let it self-update (the profile disables the check).
