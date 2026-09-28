#!/usr/bin/env python3
"""sent_mail_candidates.py — deterministic selector for the sent-mail reconciler.

Picks OPEN tasks that are plausibly resolved by ROMAN SENDING AN EMAIL to a specific
person (a reply / thank-you / outreach), and extracts the recipient address(es) to
search for. This is the "trusted script builds the bounded list" half of the
trust-boundary pattern used by email-triage.sh + sheet_status_update.py: the LLM agent
that follows can ONLY check the addresses we vetted here, it can't invent targets, and
it never mutates tasks.yaml (a separate trusted step does that via taskctl.py).

WHY a selector and not "let the agent read tasks.yaml": bounds the agent's work,
keeps it deterministic which tasks are even eligible, and — critically — encodes IN CODE
the distinction between "resolved by sending an email" (reply/thank-you/outreach) and
"merely references an email address" (pay a bill whose notice came from no-reply@...).
An action task that happens to cite a sender is NOT email-resolvable and must not be
offered up for auto-close.

Output: one candidate per line, TAB-separated:  id \t title \t addr1,addr2 \t why
No candidates -> no output, exit 0. Never writes anything.

Public-repo safe: contains NO personal addresses. Owner's own addresses (to exclude as
search targets) come from the OWNER_EMAILS env var (set in the gitignored .env), never
hardcoded here.
"""
import os
import re
import sys
import yaml

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

# Addresses you never "reply to" — automated senders. A task sourced from one of these
# is resolved by DOING the thing (pay/submit), not by emailing back.
NOREPLY_RE = re.compile(
    r"(no[-_.]?reply|do[-_.]?not[-_.]?reply|donotreply|notifications?|mailer|"
    r"automated|postmaster|bounce|updates?@|alerts?@|jobs?-?noreply|invitations@)",
    re.I,
)

# Verbs that mean "resolved by Roman sending a message to a person."
OUTREACH_RE = re.compile(
    r"\b(repl(y|ies|ied)|respond|response|follow[-\s]?up|reach out|thank[-\s]?you|"
    r"thank |get back to|answer|email |e-mail|message |connect with|"
    r"send .* (?:email|note|message|thank))\b",
    re.I,
)

# Strong "do something, not email back" signals in a TITLE — exclude even if an address
# is present (the address is just the notice's sender).
ACTION_EXCLUDE_RE = re.compile(
    r"\b(pay|submit|upload|register|sign\b|signup|sign[-\s]?up|waiver|fee|bill|invoice|"
    r"cancel|renew|deposit|enroll|complete .* form|fill out|review/edit|book\b|purchase|"
    r"verify|account balance)\b",
    re.I,
)


def owner_emails():
    raw = os.environ.get("OWNER_EMAILS", "")
    return {a.strip().lower() for a in raw.split(",") if a.strip()}


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.environ.get("CONTEXT_DIR", "."), "tasks.yaml"
    )
    with open(path) as f:
        data = yaml.safe_load(f)

    own = owner_emails()
    out = []
    for t in data.get("tasks", []):
        if t.get("status") not in ("open", None):
            continue  # skip blocked/done
        title = t.get("title", "") or ""
        notes = t.get("notes", "") or ""
        blob = f"{title}\n{notes}"

        # Must look like an outreach/reply task...
        if not OUTREACH_RE.search(blob):
            continue
        # ...and NOT a do-something-else task that merely cites a sender.
        if ACTION_EXCLUDE_RE.search(title):
            continue

        addrs = []
        for a in EMAIL_RE.findall(blob):
            al = a.lower()
            if al in own:
                continue
            if NOREPLY_RE.search(al):
                continue
            if al not in addrs:
                addrs.append(al)
        if not addrs:
            continue  # no searchable human recipient -> can't verify deterministically

        why = "outreach/reply task with a human recipient address"
        out.append("\t".join([t["id"], title.replace("\t", " "), ",".join(addrs), why]))

    if out:
        print("\n".join(out))


if __name__ == "__main__":
    main()
