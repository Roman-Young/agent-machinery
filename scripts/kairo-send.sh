#!/usr/bin/env bash
# kairo-send.sh — deliver one finished message (or one action) into the terminal seat.
#
# The server half of the "compose locally, send on Enter" overlay. The Mac-side composer
# (scripts/mac/kairo-compose) collects a whole message with instant local typing, then makes
# ONE ssh call to this script with the message on stdin — one round trip per message instead
# of one per keystroke.
#
# SAFETY CHECKS before anything is typed into the seat (each one exists because a review or a
# test showed the failure — see docs/terminal-seat.md "Compose overlay"):
#   1. the harness (omp / claude) is actually running in the pane — if it exited, the pane is a
#      SHELL, and pasting + Enter would run the message as shell commands;
#   2. the harness UI is up (not still booting — a paste before it enables bracketed paste
#      turns every line into a separate submit);
#   3. no approval prompt is open — a paste + Enter would silently pick its default (Approve);
#   4. the pane is not in tmux copy-mode (scrolled back) — keys would be eaten by copy-mode and
#      the text would sit unsent in the input box;
#   5. any leftover draft in the input box is cleared first (Ctrl+C, spaced so two never land
#      within omp's 500 ms "press again to exit" window) — otherwise the message merges with it.
# Then: strip control characters (an embedded ESC[201~ would break out of the bracketed paste),
# and paste + Enter in ONE tmux command so the harness sees them in one input burst.
#
# USAGE
#   echo "message" | kairo-send.sh            check, clear leftovers, paste, Enter
#   echo "draft"   | kairo-send.sh --no-enter paste without submitting
#   kairo-send.sh --key Escape                one allow-listed key (Escape, Up, Down, Enter, …)
#   kairo-send.sh --approve | --deny          answer an open approval prompt (refused if none)
#   kairo-send.sh --status                    seat / harness / prompt state
# EXIT: 0 ok · 2 bad input · 3 no seat · 4 harness not running · 5 busy (lock) ·
#       6 approval prompt open · 7 harness UI not ready · 8 no approval prompt to answer
# ENV:  KAIRO_TMUX_SOCKET / KAIRO_TMUX_SESSION (defaults kairo / kairo, as in kairo-term.sh)
set -euo pipefail

SOCK="${KAIRO_TMUX_SOCKET:-kairo}"
SESSION="${KAIRO_TMUX_SESSION:-kairo}"
T="=${SESSION}:"                                   # exact session name, its current window/pane
RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}"
STAMP="$RUN_DIR/kairo-send.$(id -u).$SOCK.ctrlc"   # when we last sent Ctrl+C
tm()  { tmux -L "$SOCK" "$@"; }
die() { echo "kairo-send: $2" >&2; exit "$1"; }

tm has-session -t "=$SESSION" 2>/dev/null \
  || die 3 "the seat isn't running (no tmux session '$SESSION'). Open it with kairo-term.sh (on the Mac: kairo)."

# One send at a time: overlapping sends could interleave pastes and Enters.
exec 9>"$RUN_DIR/kairo-send.$(id -u).$SOCK.lock"
flock -w 10 9 || die 5 "another send is still in progress — try again."

screen()        { tm capture-pane -p -t "$T" | tail -n 30; }
harness_name()  {   # omp / claude running as a child of the pane's process, else empty
  local pid; pid="$(tm display -p -t "$T" '#{pane_pid}')"
  ps -o args= --ppid "$pid" 2>/dev/null \
    | grep -oE '(^|/)(omp|claude)( |$)' | head -1 | tr -d '/ ' || true
}
ui_ready() {        # the harness has drawn its input box
  case "$1" in
    omp)    screen | grep -q '╰─' ;;
    claude) screen | grep -qE '^[│|] *>|^ *> ' ;;
    *)      return 1 ;;
  esac
}
approval_open()   { local s; s="$(screen)"; grep -qw 'Approve' <<<"$s" && grep -qw 'Deny' <<<"$s"; }
leave_copy_mode() { [[ "$(tm display -p -t "$T" '#{pane_in_mode}')" == 1 ]] && tm send-keys -t "$T" -X cancel || true; }
ctrl_c_spaced()   {  # Ctrl+C clears the draft; two within 500 ms would EXIT omp — keep ≥ 0.7 s apart
  local now last gap; now="$(date +%s%N)"; last="$(cat "$STAMP" 2>/dev/null || echo 0)"
  gap=$(( (now - last) / 1000000 ))
  (( gap < 700 )) && sleep "$(awk "BEGIN{print (700-$gap)/1000}")"
  tm send-keys -t "$T" C-c
  date +%s%N > "$STAMP"
  sleep 0.1
}

H="$(harness_name)"
case "${1:-}" in
  --status)
    echo "seat running: $(tm display -p -t "$T" '#{window_index}:#{window_name}') · harness: ${H:-NOT RUNNING (pane is a shell)}$( [[ -n "$H" ]] && ! ui_ready "$H" && echo ' (starting up)')$(approval_open && echo ' · APPROVAL PROMPT OPEN')$( [[ "$(tm display -p -t "$T" '#{pane_in_mode}')" == 1 ]] && echo ' · scrolled back (copy mode)')"
    exit 0 ;;
esac

[[ -n "$H" ]] || die 4 "the harness isn't running in the seat (the pane is a plain shell). Nothing was typed. Restart it: type 'omp' in the top pane, or run kairo-term.sh."
leave_copy_mode

case "${1:-}" in
  --approve|--deny)
    approval_open || die 8 "no approval prompt is open — nothing answered."
    if [[ "$1" == --approve ]]; then tm send-keys -t "$T" Enter        # "Approve" is the first, highlighted option
    else tm send-keys -t "$T" Down Enter; fi                            # move to "Deny", choose it
    exit 0 ;;
  --key)
    key="${2:?usage: kairo-send.sh --key <tmux key name, e.g. Escape>}"
    # Allow-list: keys a harness needs for interrupts, menus and pickers. Anything else is
    # refused rather than passed blindly into a shell-holding agent's terminal.
    case "$key" in
      Escape|Enter|Up|Down|Left|Right|Tab|BTab|Space|C-o|C-t|M-p|y|n|1|2|3|4|5|6|7|8|9) ;;
      *) die 2 "key '$key' not allowed" ;;
    esac
    tm send-keys -t "$T" "$key"
    exit 0 ;;
esac

ui_ready "$H"   || die 7 "$H is still starting up — try again in a few seconds."
approval_open   && die 6 "an approval prompt is open in the seat — answer it first (:approve / :deny, or in the top pane). Your message was NOT sent."

# Sanitize: remove ANSI CSI sequences, then all ASCII control chars except TAB and LF.
#  - ESC: an embedded ESC[201~ ends the bracketed paste early and turns the rest into typed
#    keystrokes (early submits, injected input) — verified by test, tmux does not filter it.
#  - CR: tmux maps LF→CR inside a paste, so CRLF text would gain blank lines.
#  - LC_ALL=C: byte-wise ranges; under a UTF-8 locale sed's [@-~] silently fails (verified).
msg="$(LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[ -/]*[@-~]//g' | LC_ALL=C tr -d '\000-\010\013-\037\177')"
[[ -n "${msg//[[:space:]]/}" ]] || die 2 "empty message, nothing sent"
# If the last token could open an autocomplete popup (@file, #ref, :emoji, /cmd) the Enter would
# accept the completion instead of submitting — a trailing space closes the token.
[[ "$msg" =~ (^|[[:space:]])[@#:/][^[:space:]]*$ ]] && msg="$msg "

ctrl_c_spaced                                       # clear any leftover draft
buf="kairo-$$"
printf '%s' "$msg" | tm load-buffer -b "$buf" -
if [[ "${1:-}" == "--no-enter" ]]; then
  tm paste-buffer -p -d -b "$buf" -t "$T"
else
  tm paste-buffer -p -d -b "$buf" -t "$T" \; send-keys -t "$T" Enter    # one burst
fi
