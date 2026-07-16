#!/usr/bin/env bash
# voice-prompt.sh — answer a spoken query sent from the phone over SSH.
#
# ══════════════════════════════════════════════════════════════════════════════
# THE HANDS-FREE VOICE PATH (no Paseo, no talk-back, no open ports beyond SSH).
#
#   "Hey Siri, <phrase>" → phone dictates your words → SSH to the server → THIS runs
#   the query through Cairo → the answer pushes back to your phone via ntfy.
#
# SECURITY — this is wired as a FORCED COMMAND in authorized_keys (see
# authorize-phone-key.sh), which is what makes it safe to expose over SSH:
#   • The phone's key can ONLY run this script. It cannot get a shell, run arbitrary
#     commands, forward ports, or open a PTY. So even if the phone key leaks, the worst
#     an attacker can do is send Cairo a query — and the ANSWER goes to ROMAN's phone,
#     not theirs. No shell, no exfiltration.
#   • The query arrives in $SSH_ORIGINAL_COMMAND (whatever the phone "ran"), and is
#     treated as plain TEXT — never executed.
#   • run-agent.sh bounds it (timeout, turn cap, circuit breaker), so a flood of queries
#     can't run away.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The dictated query. From the forced command it's in $SSH_ORIGINAL_COMMAND; fall back to
# args for local testing. Bound the length and strip control bytes — it's untrusted-shaped.
QUERY="${SSH_ORIGINAL_COMMAND:-$*}"
QUERY="$(printf '%s' "$QUERY" | tr -d '\000-\010\013\014\016-\037' | head -c 1500)"
if [[ -z "${QUERY// /}" ]]; then
  "$SCRIPT_DIR/notify.sh" "🎤 Cairo" "I got an empty voice query — try again." >/dev/null 2>&1 || true
  echo "empty query"; exit 0
fi

# Read-mostly, plus task capture. NO email SEND, NO shell for the agent. Output only ever
# goes to Roman's phone, so a leaked key cannot exfiltrate — it can only ping Roman.
export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,Edit,Write,\
mcp__claude_ai_Gmail__search_threads,mcp__claude_ai_Gmail__get_thread,\
mcp__claude_ai_Google_Calendar__list_events,mcp__claude_ai_Google_Calendar__search_events"
export AGENT_MAX_TURNS=20
export AGENT_TIMEOUT_SEC=180
export PUSH_OUTPUT=1   # run-agent pushes the answer to the phone via ntfy

"$SCRIPT_DIR/run-agent.sh" voice-prompt \
"Roman sent you this BY VOICE from his phone (transcribed, so a word or two may be garbled —
decode proper nouns from context; 'Con'/'Cairo' is you, 'Pet Match' is PEPMatch):

    \"$QUERY\"

Do it, or answer it, then reply in UNDER 380 CHARACTERS — your reply becomes a single phone
notification, so be brief and direct, plain text, no markdown, no preamble.

- If it's something to remember / a task: add it to tasks.md with a new ID, confirm in one line.
- If it's a question about his day, schedule, tasks, or mail: answer from the context files +
  Gmail/Calendar. Lead with the answer.
- Email is DRAFT-ONLY and you have no send tool here — if he asks to email someone, say you'll
  draft it next time he's at a session, don't attempt to send.
- If you genuinely can't tell what he meant, give your best guess of the answer AND ask him to
  confirm — don't just say 'I didn't understand.'"
