#!/usr/bin/env bash
# healthcheck-omp.sh — prove the OMP seat still works. Companion to healthcheck.sh
# (the Claude Code / Paseo seat's healthcheck) — same Five Properties framework,
# applied to the terminal/coding seat added 2026-08. Run after ANY change to
# AGENTS.md, ~/.omp/agent/config.yml, or the delegate mechanism.
#
# WHY A SEPARATE SCRIPT: OMP is a second harness with its own config, its own
# instruction-discovery mechanism (AGENTS.md, not CLAUDE.md), and its own way of
# touching memory (delegated through run-agent.sh, never direct writes) — none of
# which healthcheck.sh can see. Same core lesson as that script: "I read the code
# and it looks right" is not evidence; a bug is invisible on read and obvious
# within 60 seconds of actually running the operation.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"       # agent-machinery
AGENT_DIR="$(dirname "$REPO_DIR")"        # /home/roman/agent
# shellcheck disable=SC1091
[[ -f "$REPO_DIR/.env" ]] && { set +u; source "$REPO_DIR/.env"; set -u; }
CTX="${CONTEXT_DIR:-$HOME/agent/my-context}"

PASS=0; FAIL=0; WARN=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN+1)); }
hdr()  { echo; echo "─── $1"; }

echo "═══ Kairo-on-OMP healthcheck — $(date '+%F %H:%M %Z') ═══"

export PATH="$HOME/.bun/bin:$PATH"

# ── 1. LIVENESS ───────────────────────────────────────────────────────────────
hdr "1. LIVENESS — does the OMP seat work right now?"

command -v bun >/dev/null 2>&1 && ok "bun present" || bad "bun MISSING — omp cannot run at all"
command -v omp >/dev/null 2>&1 && ok "omp on PATH" || bad "omp NOT on PATH"

[[ -f "$HOME/.omp/agent/config.yml" ]] && ok "config.yml exists" || bad "config.yml MISSING — omp has no config"
[[ -f "$AGENT_DIR/AGENTS.md" ]] && ok "AGENTS.md exists at $AGENT_DIR" || bad "AGENTS.md MISSING — OMP has no identity"

# THE REAL TEST, not just "does the file exist" — prove OMP actually DISCOVERS and
# FOLLOWS it. A moved file, a changed discovery rule, or a stale cache would be
# invisible to a plain existence check and obvious here.
if command -v omp >/dev/null 2>&1 && [[ -f "$AGENT_DIR/AGENTS.md" ]]; then
  IDENT=$(cd "$AGENT_DIR" && timeout 60 omp -p "One word: what is your name per AGENTS.md?" 2>/dev/null | tr -d '[:space:]')
  [[ "$IDENT" == *"Kairo"* ]] && ok "AGENTS.md is DISCOVERED and FOLLOWED (omp -p identified as Kairo)" \
    || bad "🔴 AGENTS.md exists but omp -p did NOT identify as Kairo (got: '$IDENT') — discovery broken"
else
  warn "skipped the discovery probe (omp or AGENTS.md missing)"
fi

# Guardrails — prove the CONFIGURED state, not what we remember setting.
if command -v omp >/dev/null 2>&1; then
  MODE=$(omp config get tools.approvalMode 2>/dev/null)
  [[ "$MODE" == "write" || "$MODE" == "always-ask" ]] && ok "tools.approvalMode = $MODE (not yolo)" \
    || bad "🔴 tools.approvalMode = '$MODE' — if this is 'yolo', every tool call auto-approves, no guardrail at all"

  PATTERNS=$(omp config get bash.patterns 2>/dev/null)
  echo "$PATTERNS" | grep -q '"rm -rf"' && echo "$PATTERNS" | grep -q '"deny"' \
    && ok "bash.patterns denies rm -rf" \
    || bad "🔴 bash.patterns does NOT deny rm -rf — destructive commands are one Approve click away"

  MEM=$(omp config get memory.backend 2>/dev/null)
  [[ "$MEM" == "off" ]] && ok "memory.backend = off (single brain, not forked)" \
    || bad "🔴 memory.backend = '$MEM' — OMP may be building its OWN memory store, separate from \$CONTEXT_DIR"

  AL=$(omp config get autolearn.enabled 2>/dev/null)
  [[ "$AL" == "false" ]] && ok "autolearn.enabled = false" \
    || warn "autolearn.enabled = '$AL' — OMP may silently capture its own 'lessons' outside \$CONTEXT_DIR"
else
  warn "skipped guardrail config checks (omp not on PATH)"
fi

# The delegate mechanism — prove the OPERATION, not just that run-agent.sh exists.
# Real round trip against the REAL tasks.yaml (same "it's cheap and self-cleans"
# reasoning the primary healthcheck uses for its real Gmail call) — never deletes,
# always ends in done:, and is the ONE check that actually proves OMP can write
# memory at all, not just that AGENTS.md correctly describes how it would.
# NOTE: no outer `timeout` wrapper here on purpose. run-agent.sh already has its own
# internal timeout (GUARD 2, default 600s) — that IS the choke point; a second, shorter
# competing timeout around it would race against its own guard, kill the parent script
# while an orphaned grandchild claude process keeps running detached (still holding the
# lock), and misreport a real-but-slow success as a failure. Trust the one guard that's
# actually designed for this instead of adding a second, uncoordinated one.
if [[ -x "$SCRIPT_DIR/run-agent.sh" ]] && [[ -f "$REPO_DIR/.env" ]]; then
  TAG="omp-hc-$(date +%s)"
  # A single slow (~190s) rc=1 failure now and then is an observed characteristic of
  # this multi-step delegated call (2026-08-24 — likely brushing --max-turns 25 on a
  # longer exploration path), not proof the mechanism is broken — run-agent.sh already
  # treats FAST failures this way (auth-blip retry); this extends the same "distinguish
  # a flake from a real break" judgment to a slower failure mode. One bounded retry,
  # same MAX_ATTEMPTS=2 shape as run-agent.sh's own guard — not unlimited.
  ADD_OUT=""
  for attempt in 1 2; do
    ADD_OUT=$(cd "$AGENT_DIR" && AGENT_ALLOWED_TOOLS="Read,Edit,Write,Bash(python3 agent-machinery/scripts/render-tasks.py:*)" \
      "$SCRIPT_DIR/run-agent.sh" omp-memory-write \
      "Add a task to tasks.yaml: title='$TAG (OMP healthcheck round-trip, safe to ignore)', domain=other, urgency=green, due=null. Then run: python3 $SCRIPT_DIR/render-tasks.py. Reply with ONLY the assigned task ID (e.g. T150)." 2>/dev/null | tail -1 | grep -oE 'T[0-9]+')
    [[ -n "$ADD_OUT" ]] && grep -q "id: $ADD_OUT" "$CTX/tasks.yaml" 2>/dev/null && break
    [[ "$attempt" -eq 1 ]] && warn "delegate write attempt 1 failed — retrying once before treating this as a real failure"
  done
  if [[ -n "$ADD_OUT" ]] && grep -q "id: $ADD_OUT" "$CTX/tasks.yaml" 2>/dev/null; then
    ok "delegate write round-trip: $ADD_OUT added and VERIFIED in tasks.yaml (not just self-reported)"
    cd "$AGENT_DIR" && AGENT_ALLOWED_TOOLS="Read,Edit,Write,Bash(python3 agent-machinery/scripts/render-tasks.py:*)" \
      "$SCRIPT_DIR/run-agent.sh" omp-memory-write \
      "Move task $ADD_OUT to done: in tasks.yaml, done_date=today, trim notes to 'OMP healthcheck - confirmed working.' Then run: python3 $SCRIPT_DIR/render-tasks.py." >/dev/null 2>&1
    grep -A1 "id: $ADD_OUT" "$CTX/tasks.yaml" | grep -q "done_date" \
      && ok "delegate cleanup confirmed: $ADD_OUT moved to done: (not left dangling open)" \
      || warn "$ADD_OUT added but cleanup to done: could not be verified — check tasks.yaml manually"
  else
    bad "🔴 delegate write round-trip FAILED — OMP cannot actually write memory, despite what AGENTS.md claims"
  fi
else
  warn "skipped the delegate round-trip (run-agent.sh missing/not executable, or .env missing)"
fi

# ── 2. DURABILITY ─────────────────────────────────────────────────────────────
hdr "2. DURABILITY — will the OMP seat still be usable after a reboot?"
# OMP is not a daemon — there's no persistent process expected to survive a reboot,
# unlike Paseo. "Durability" here means: will a FRESH shell after reboot still be
# able to launch it, without Roman having to remember a manual PATH fix.
# Test the BEHAVIOR, not the text — a healthy-looking grep on a variable-based PATH
# line (export PATH="$BUN_INSTALL/bin:$PATH") can look wrong and still work fine, or
# look right and still be broken. Actually source .bashrc in a fresh shell and check.
if bash -c 'source ~/.bashrc >/dev/null 2>&1; command -v omp' >/dev/null 2>&1; then
  ok "a fresh shell sourcing .bashrc resolves omp on PATH (survives reboot)"
else
  bad "a fresh shell sourcing .bashrc does NOT resolve omp — after a reboot, a new shell won't find it"
fi

# ── 3. RECOVERABILITY ─────────────────────────────────────────────────────────
hdr "3. RECOVERABILITY — does the OMP setup survive the SERVER dying?"

if git -C "$AGENT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ok "$AGENT_DIR is a git repo — AGENTS.md rides its push/backup"
else
  warn "$AGENT_DIR is NOT a git repo — AGENTS.md (and the pre-existing top-level CLAUDE.md) have NO backup. If the server dies, both are gone. Pre-existing gap, not introduced by OMP."
fi

warn "~/.omp/ (guardrail config.yml, model routing, auth) is entirely outside any tracked repo — if the server dies, this must be manually rebuilt (re-run omp config set, re-auth providers). Cheap to rebuild, unlike lost memory data, but worth knowing before it happens."

# ── 4. BOUNDEDNESS ────────────────────────────────────────────────────────────
hdr "4. BOUNDEDNESS — can the OMP seat run away?"

# OMP's own approval-mode + bash.patterns are already verified under LIVENESS above
# (checked there since they're also what makes the seat usable at all — not
# duplicated here). What's OMP-specific: it depends ENTIRELY on run-agent.sh for
# every memory write, so that script's own guards are a hard dependency.
[[ -x "$SCRIPT_DIR/run-agent.sh" ]] \
  && ok "run-agent.sh present + executable — OMP's memory writes inherit its lock/timeout/circuit-breaker (see healthcheck.sh for those guards directly, not duplicated here)" \
  || bad "🔴 run-agent.sh missing or not executable — OMP CANNOT write memory at all"

# The circuit breaker is shared by job name — if omp-memory-write gets called a lot
# (including by this healthcheck's own round-trip above), it could trip. Surface the
# current count so it's never a silent mid-workday surprise.
CFILE="$HOME/.agent-logs/state/omp-memory-write.$(date +%F).count"
if [[ -f "$CFILE" ]]; then
  C=$(cat "$CFILE" 2>/dev/null || echo 0)
  CAP="${AGENT_MAX_RUNS_PER_DAY:-12}"
  [[ "$C" -lt $((CAP - 2)) ]] && ok "omp-memory-write run count today: $C/$CAP (healthy headroom)" \
    || warn "omp-memory-write run count today: $C/$CAP — close to the circuit breaker; the next few delegated writes may get refused"
else
  ok "omp-memory-write has no runs recorded yet today"
fi

# ── 5. PUBLISHABILITY ─────────────────────────────────────────────────────────
hdr "5. PUBLISHABILITY — is AGENTS.md safe to have on disk / eventually push?"

if [[ -f "$AGENT_DIR/AGENTS.md" && -x "$SCRIPT_DIR/pii-scan.sh" ]]; then
  # Scan an isolated scratch copy, not the whole agent/ tree — same "prove it on a
  # scratch copy" discipline as the bus round-trip and tasks.md re-render checks.
  SCRATCH=$(mktemp -d)
  cp "$AGENT_DIR/AGENTS.md" "$SCRATCH/"
  HITS=$("$SCRIPT_DIR/pii-scan.sh" "$SCRATCH" 2>/dev/null || true)
  rm -rf "$SCRATCH"
  [[ -z "$HITS" ]] && ok "AGENTS.md has no emails/IPs" || bad "🔴 PII IN AGENTS.md: $HITS"
else
  warn "skipped PII scan (AGENTS.md or pii-scan.sh missing)"
fi

echo
echo "═════════════════════════════════════════════"
printf "  PASS %d   WARN %d   FAIL %d\n" "$PASS" "$WARN" "$FAIL"
if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then echo "  ✅ Kairo-on-OMP is healthy on all five properties."
elif [[ $FAIL -eq 0 ]]; then                echo "  🟡 Working, with $WARN warning(s). Nothing is broken."
else                                        echo "  ❌ $FAIL FAILURE(S). Do not trust the OMP seat until fixed."
fi
echo "═════════════════════════════════════════════"

exit $(( FAIL > 0 ? 1 : 0 ))
