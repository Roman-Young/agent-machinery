# Integrations — the two hard problems, and what we learned

Generic guidance. **Personal specifics (actual addresses, actual filter strings) live in the
private context repo, never here** — this repo is public.

---

## ⚠️ Problem 1: the headless connector trap

**This is the most dangerous failure mode in the whole system, and it is silent.**

Interactive connectors (Gmail, Calendar, Drive — anything OAuth'd through a browser) *do*
work in a headless `claude -p` run. **But the permission gate does not.**

In a non-interactive run, a tool that isn't on the allowlist is **denied with nobody to
ask** — and the model then reports **"0 threads found."** Not *"I was blocked."* Zero
threads. It looks exactly like an empty inbox.

So a morning brief can fire, silently see no email at all, and hand you a cheerful summary
that omits everything that matters. **That is worse than no brief, because you would trust
it and stop checking yourself.**

### The two things that fix it

**1. An explicit per-job allowlist.** Each job passes its own `--allowedTools`. Never rely
on ambient config.

```bash
export AGENT_ALLOWED_TOOLS="Read,Glob,Grep,\
mcp__<provider>_Gmail__search_threads,\
mcp__<provider>_Google_Calendar__list_events"
```

**2. A coverage assertion the SCRIPT checks — not the model.** Make the job declare what it
actually reached, then verify it:

```
Line 1 MUST be:  SOURCES: gmail=ok calendar=ok
Write FAIL if a call did not genuinely return data. Never write 'ok' to be agreeable.
```

```bash
grep -qi 'gmail=ok' <<<"$OUT" || { notify "⚠️ BRIEF DEGRADED"; exit 1; }
```

**The model asserting success is not evidence. The script checking the assertion is.**

---

## ⚠️ Problem 2: multiple inboxes, and the one you must not touch

Most people have several: personal, school, and one or more **work/institutional** accounts.
The agent can typically read *one*.

### The honesty rule (non-negotiable)

**Until every inbox is covered, the agent must never say "I triaged your inbox" or "nothing
important came in." It must name WHICH inbox it read.**

Overstating coverage is the most damaging thing an assistant like this can do: the owner
stops checking the inboxes it can't see, and those are usually the ones that matter.
**Partial coverage stated honestly is useful. Partial coverage stated as total is worse than
nothing.**

### Personal + school inboxes: forward them in

Forward into the one account the agent already reads, and **label on arrival** so it can
triage by source. Zero new auth, zero new attack surface.

**But do not blanket auto-archive them** — see below.

### 🛑 Institutional / work inboxes: STOP. Ask first.

**Do not auto-forward work email to a personal account.** Three independent reasons, any one
of which is disqualifying:

1. **It may simply be against policy.** Employers — especially research institutions,
   hospitals, and anywhere with an IRB — commonly *prohibit* auto-forwarding to personal
   accounts. *"My AI agent needed to read it"* is not a defense anyone will accept.
2. **It leaks confidential material.** Unpublished research, review threads, unreleased
   data — into a personal mailbox, permanently, by a rule nobody remembers setting.
3. **Blast radius.** The agent reads untrusted input (email, web pages) *while holding shell
   access*. Piping your employer's mail through that is a materially larger surface than
   your own student mail.

**Send one email to IT and ask. Assume the answer is no until they say otherwise.**

If it's prohibited: leave work mail out, and forward individual threads by hand when you
want help with one. Lower coverage, zero risk — **and that is a perfectly good outcome, not
a failure of the system.** If it's permitted: still don't forward the whole inbox — forward
only from named senders.

---

## The auto-archive trap

The obvious "keep my inbox clean" move is: forward everything in, auto-archive it all under
a label. **Do not do that until something is actually reading the archive.**

If the reason you're doing this is *"I miss important mail"*, then hiding that mail behind a
label while your brief **doesn't exist yet** makes it strictly worse: now it's invisible
*and* unread.

**The rule: never hide mail from yourself faster than you build something that reads it.**

The safe design is **two mutually-exclusive filters**, not one:
- **Filter A (safety net):** from the senders that matter, OR subject matching
  bills/deadlines/housing/etc → label it, **star it, KEEP IT IN THE INBOX.**
- **Filter B (quiet bucket):** everything else from that source (the exact negation of A) →
  label it, **skip the inbox.**

Newsletters vanish. The things that have actually burned you stay visible. When the brief is
live and trusted, tighten A.

---

## Calendar / LMS feeds

Most learning-management systems expose a personal **iCal feed** that needs no token and
cannot be blocked by IT — subscribe it into Google Calendar and the agent reads deadlines
through the calendar connector it already has. It carries **dates, not content**: syllabi and
assignment text still have to be dropped in by hand, once a term.

Treat the `.ics` URL as a secret: it's an unauthenticated link to your entire schedule.
