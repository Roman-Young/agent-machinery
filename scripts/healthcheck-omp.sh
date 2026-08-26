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

# Prove OMP can actually WRITE memory — via the fast path it now uses (taskctl.py),
# not the old delegate. History (2026-08-24): the delegate round-trip that used to live
# here was slow (~190s) and failed ~40% of the time (a full context-load agent doing a
# one-line edit, brushing --max-turns), which made this healthcheck itself slow and
# prone to false reds. taskctl is deterministic: sub-second, no LLM, no flake.
#
# We run add->done against a COPY of the real tasks.yaml (same "test on a scratch copy"
# discipline as the tasks.md re-render and bus round-trip checks above). This proves
# THREE things at once: taskctl works, the REAL tasks.yaml is valid + taskctl-compatible
# (we copied it), and — unlike the old delegate test — it pollutes the real done: list
# with ZERO junk entries and spends none of the delegate's circuit-breaker budget.
#
# NOTE: this does NOT round-trip the run-agent.sh delegate path (still used for judgment
# writes — log prose, approved skills). That path's guards are checked structurally under
# BOUNDEDNESS; a full LLM round-trip is too flaky to belong in a healthcheck. Flagged, not
# silently dropped.
_present() { python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])) or {}; ids=[t.get('id') for t in d.get(sys.argv[3],[])]; sys.exit(0 if sys.argv[2] in ids else 1)" "$1" "$2" "$3"; }
if [[ -x "$SCRIPT_DIR/taskctl.py" ]] && [[ -f "$CTX/tasks.yaml" ]]; then
  HCTMP=$(mktemp -d)
  cp "$CTX/tasks.yaml" "$HCTMP/tasks.yaml"
  NID=$(python3 "$SCRIPT_DIR/taskctl.py" add --title "healthcheck selftest (scratch copy, never the real list)" \
        --domain other --urgency green --notes "taskctl fast-path round-trip" --file "$HCTMP/tasks.yaml" 2>/dev/null)
  if [[ -n "$NID" ]] && _present "$HCTMP/tasks.yaml" "$NID" tasks; then
    if python3 "$SCRIPT_DIR/taskctl.py" done "$NID" --file "$HCTMP/tasks.yaml" >/dev/null 2>&1 \
       && _present "$HCTMP/tasks.yaml" "$NID" done && ! _present "$HCTMP/tasks.yaml" "$NID" tasks; then
      ok "taskctl write round-trip: add->done VERIFIED on a scratch copy of the real tasks.yaml ($NID) — fast path, no real-list pollution"
    else
      bad "🔴 taskctl 'done' failed — OMP's task-completion path is broken"
    fi
  else
    bad "🔴 taskctl 'add' failed — OMP cannot write tasks (the fast path AGENTS.md points at is broken)"
  fi
  rm -rf "$HCTMP"
else
  warn "skipped taskctl round-trip (taskctl.py or tasks.yaml missing)"
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
