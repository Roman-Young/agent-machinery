#!/usr/bin/env bash
# kairo-term.sh — THE TERMINAL SEAT: one persistent, reconnectable Kairo session.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHAT IT IS
#   A tmux session (on its own private tmux socket, so it never collides with any other
#   tmux you run) that holds Kairo's interactive harness, started in the workspace root
#   so the identity files load. Disconnect — close the laptop, lose signal on the phone —
#   and the session keeps running. Reconnect from anywhere and you land back in it.
#
#   From a laptop / VS Code Remote-SSH terminal:   ssh -t <server> <this-script>
#   From a phone (Blink, Termius, …):              mosh <server> -- <this-script>
#
# WHY A LAUNCHER AND NOT JUST "run the harness"
#   1. Persistence. A bare TUI dies with the SSH connection; tmux is what makes a phone
#      reconnect land in the SAME conversation.
#   2. The harness is a SWITCH, not a migration. KAIRO_HARNESS=claude|omp picks which TUI
#      runs in the seat. Everything around it (tmux, notifications, the workspace, the
#      memory) is identical, so trying a harness costs nothing and backing out is one env var.
#   3. A guard that can't be forgotten (see omp_guard below).
#
# USAGE
#   kairo-term.sh            attach to the seat (creates it if missing)
#   kairo-term.sh new [name] open another parallel chat as a new tmux window
#   kairo-term.sh ls         list the seat's windows
#   kairo-term.sh check      run the preflight checks only, start nothing
#
# ENV
#   KAIRO_HARNESS         claude (default) | omp
#   KAIRO_OMP_PROFILE     omp profile to run in (default: kairo; "default" = omp's default
#                         profile). Profiles isolate auth, sessions and settings.
#   (Any KAIRO_* setting can also live in ~/.config/kairo/seat.env — the owner's standing
#    choices, kept out of this public repo. Explicit env vars override it.)
#   KAIRO_OMP_APPROVAL    omp approval mode pinned via CLI (default: write; stricter: always-ask)
#   KAIRO_HOME            workspace root that holds CLAUDE.md / AGENTS.md
#                         (default: the parent of this repo)
#   KAIRO_TMUX_SOCKET     tmux -L socket name (default: kairo)
#   KAIRO_TMUX_SESSION    tmux session name (default: kairo)
#   KAIRO_ALLOW_SUBSCRIPTION_OAUTH=1   skip omp_guard. Read omp_guard's comment first.
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# Launched remotely (`mosh host -- kairo-term.sh`, `ssh -t host …`) this runs WITHOUT the
# interactive shell setup, so user-installed tools aren't on PATH (omp lives in ~/.npm-global/bin
# and needs bun from ~/.bun/bin). Don't depend on the login shell — add the usual user tool dirs.
for d in "$HOME/.npm-global/bin" "$HOME/.bun/bin" "$HOME/.local/bin" "$HOME/.cargo/bin"; do
  if [[ -d "$d" && ":$PATH:" != *":$d:"* ]]; then PATH="$d:$PATH"; fi
done
export PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# Owner's standing choices (harness, profile, the subscription-guard decision) live OUTSIDE this
# public repo, in a personal file. Explicit env vars still win over it.
SEAT_ENV="${KAIRO_SEAT_ENV:-$HOME/.config/kairo/seat.env}"
if [[ -f "$SEAT_ENV" ]]; then
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^KAIRO_[A-Z_]+$ ]] || continue          # only KAIRO_* keys; no code execution
    if [[ -z "${!k:-}" ]]; then export "$k=$v"; fi
  done < <(grep -E '^[[:space:]]*KAIRO_[A-Z_]+=' "$SEAT_ENV" | sed 's/^[[:space:]]*//')
fi
KAIRO_HOME="${KAIRO_HOME:-$(dirname "$REPO_DIR")}"
SOCK="${KAIRO_TMUX_SOCKET:-kairo}"
SESSION="${KAIRO_TMUX_SESSION:-kairo}"
CONF="$REPO_DIR/config/tmux-kairo.conf"
HARNESS="${KAIRO_HARNESS:-claude}"
OMP_PROFILE_NAME="${KAIRO_OMP_PROFILE:-kairo}"

die()  { echo "kairo-term: $*" >&2; exit 1; }
warn() { echo "kairo-term: $*" >&2; }
tm()   { tmux -L "$SOCK" -f "$CONF" "$@"; }

# ── Preflight ────────────────────────────────────────────────────────────────────
preflight() {
  command -v tmux >/dev/null || die "tmux is not installed."
  [[ -f "$CONF" ]] || die "missing tmux config: $CONF"
  # The identity lives in files in the workspace root. Start anywhere else and the harness
  # comes up as a generic assistant — fail here instead of letting that happen silently.
  case "$HARNESS" in
    claude)
      command -v claude >/dev/null || die "claude (Claude Code) is not on PATH."
      [[ -f "$KAIRO_HOME/CLAUDE.md" ]] \
        || die "no CLAUDE.md in $KAIRO_HOME — Kairo's identity would not load. Set KAIRO_HOME."
      ;;
    omp)
      command -v omp >/dev/null || die "omp is not on PATH."
      [[ -f "$KAIRO_HOME/AGENTS.md" ]] \
        || die "no AGENTS.md in $KAIRO_HOME — under omp that file IS the seat's identity (it shadows CLAUDE.md)."
      omp_guard
      ;;
    *) die "KAIRO_HARNESS must be 'claude' or 'omp' (got '$HARNESS')." ;;
  esac
}

# ── The subscription guard ───────────────────────────────────────────────────────
# Anthropic's Consumer Terms forbid using Claude Free/Pro/Max OAuth tokens in any product
# other than Claude Code / Claude.ai, and Anthropic enforces it without notice (accounts
# were auto-banned in the Jan-2026 rollout). omp's Anthropic OAuth works by presenting
# itself as Claude Code. On a single-account setup, that subscription is usually what
# EVERY scheduled job runs on — so the blast radius of a flagged account is the whole
# system, not just this seat. The compliant ways to run Claude under omp are an API key
# (pay-per-token) or a cloud provider; other model vendors have their own terms.
#
# The check never reads a secret: `omp token <provider> --list` lists stored OAuth
# ACCOUNTS and exits non-zero when there are none (verified against omp 17.4.0).
omp_guard() {
  [[ "${KAIRO_ALLOW_SUBSCRIPTION_OAUTH:-}" == 1 ]] && {
    warn "WARNING: subscription-OAuth guard DISABLED by KAIRO_ALLOW_SUBSCRIPTION_OAUTH=1."
    return 0
  }
  [[ -z "${ANTHROPIC_OAUTH_TOKEN:-}" ]] \
    || die "ANTHROPIC_OAUTH_TOKEN is set in the environment — that is a subscription token. Unset it (use ANTHROPIC_API_KEY for Claude under omp)."
  if OMP_PROFILE="$OMP_PROFILE_NAME" omp token anthropic --list >/dev/null 2>&1; then
    die "omp profile '$OMP_PROFILE_NAME' has an Anthropic SUBSCRIPTION (OAuth) login stored.
  Using it outside Claude Code violates Anthropic's Consumer Terms and risks the account.
  Fix: run 'OMP_PROFILE=$OMP_PROFILE_NAME omp' → /logout anthropic, then authenticate with
  an API key instead. (Override, accepting that risk: KAIRO_ALLOW_SUBSCRIPTION_OAUTH=1.)"
  fi
}

# ── The command that runs inside each seat window ────────────────────────────────
# When the harness exits (/exit, crash) the window drops to a login shell instead of
# vanishing, so a phone reconnect never lands in a dead session with no way back.
harness_cmd() {
  local run
  case "$HARNESS" in
    claude) run="claude" ;;
    # --approval-mode on the command line pins the mode for the session: a config-file
    # edit (e.g. a prompt-injected model writing approvalMode: yolo) can't override it.
    # --continue: a restarted seat (server reboot, crash) resumes the last conversation in this
    #   folder instead of starting blank.
    # PI_CONFIG_FILES: seat-only settings overlay (read-only, per-process; never written to the
    #   owner's config). Same loader as --config, but verifiable: `PI_CONFIG_FILES=… omp config get`
    #   reflects it, while the `config` subcommand ignores a --config flag (checked on 18.4.4).
    omp)    run="PI_CONFIG_FILES=$(printf %q "$REPO_DIR/config/omp-seat-overlay.yml") OMP_PROFILE=$(printf %q "$OMP_PROFILE_NAME") omp --continue --approval-mode $(printf %q "${KAIRO_OMP_APPROVAL:-write}")" ;;
  esac
  printf '%s; echo; echo "[%s exited — you are in a shell. Run: %s  (or: kairo-term.sh new)]"; exec bash -l' \
    "$run" "$HARNESS" "$run"
}

# Markers every process in the seat inherits. The notification hook keys on KAIRO_SEAT so
# it can never fire for a headless `claude -p` job or a phone-app session.
seat_env() {
  printf -- '-e\0KAIRO_SEAT=1\0-e\0KAIRO_SEAT_SESSION=%s\0-e\0KAIRO_TMUX_SOCKET=%s\0-e\0KAIRO_HARNESS=%s\0' \
    "$SESSION" "$SOCK" "$HARNESS"
}

attach() {
  local -a envargs
  mapfile -d '' envargs < <(seat_env)
  # -A: attach if the session exists, create it otherwise. TMUX= lets this work from
  # inside another tmux (it nests rather than refusing).
  TMUX='' exec tmux -L "$SOCK" -f "$CONF" new-session -A -s "$SESSION" -n "${HARNESS}" \
    -c "$KAIRO_HOME" "${envargs[@]}" "$(harness_cmd)"
}

new_window() {
  local name="${1:-chat}"
  tm has-session -t "$SESSION" 2>/dev/null || die "no seat running yet — run 'kairo-term.sh' first."
  local -a envargs
  mapfile -d '' envargs < <(seat_env)
  tm new-window -t "$SESSION" -n "$name" -c "$KAIRO_HOME" "${envargs[@]}" "$(harness_cmd)"
  echo "opened window '$name' in seat '$SESSION' — switch with Ctrl-b w (or Ctrl-b n / p)."
}

case "${1:-attach}" in
  attach) preflight; attach ;;
  new)    preflight; new_window "${2:-chat}" ;;
  ls)     tm list-windows -t "$SESSION" -F '#I  #W  #{?window_active,(active),}  #{pane_current_command}' 2>/dev/null \
            || echo "no seat running." ;;
  check)  preflight; echo "kairo-term: preflight OK (harness=$HARNESS, home=$KAIRO_HOME, socket=$SOCK)." ;;
  -h|--help|help) sed -n '2,40p' "$0" ;;
  *) die "unknown command '$1' (attach | new [name] | ls | check | help)" ;;
esac
