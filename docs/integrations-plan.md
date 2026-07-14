# Integrations plan — Canvas and multi-account Gmail

Written 2026-07-13. Companion to `canvas-access.md` (which has the Canvas research).

---

## ⚠️ Read this first: the headless problem

**This affects both integrations and it is the biggest open risk in the whole system.**

The Gmail, Google Calendar, Drive, and Granola connectors are **claude.ai connectors** —
they were authorized interactively, through an OAuth flow in a browser, tied to the
claude.ai account.

The **morning brief is a headless run** (`claude -p`, fired by a systemd timer, no
human, no browser). **Interactively-authenticated connectors may not be available in a
headless run.** If they aren't, then the morning brief — whose entire job is "triage
email, surface deadlines" — will fire, find no Gmail and no Calendar, and either fail
or, much worse, produce a cheerful brief that silently omits everything that matters.

**This has not been tested, because the morning brief doesn't exist yet.** It must be
tested *before* the brief is trusted, not after.

**The test** (do this before building the brief):

```bash
cd /home/roman/agent
claude -p "List the names of every MCP tool you can currently call. Then try to \
search my Gmail for messages from the last 3 days and report how many you found. \
If you cannot reach Gmail, say so explicitly."
```

Run it from a plain non-interactive shell — no TTY, the way the timer will.

- **If it can reach Gmail** → claude.ai connectors survive headless. Proceed; the
  simple options below are fine.
- **If it cannot** → the connectors are interactive-only, and every automation that
  needs email or calendar must use **server-side MCP** (Option C below). This is the
  fork in the road for the whole automation layer.

Either way, **fail loudly**: the brief script must check that it actually got Gmail and
Calendar, and push an ntfy alert if it didn't. A brief that silently omits your inbox is
worse than no brief, because you'll trust it. (Same failure family as
`insights.md` #6 — verify the actual capability, not a proxy for it.)

---

## 1. Canvas

**Bottom line: already solved, not yet done. ~5 minutes.** UCSD blocks the Canvas MCP
*and* blocks students from minting API tokens — neither matters, because the iCal feed
needs no token and can't be blocked.

### The path (dates)

1. Canvas → **Calendar** → sidebar → **Calendar Feed** → copy the `.ics` URL.
   **Treat this URL as a secret** — it's an unauthenticated link to your whole schedule.
2. Google Calendar → **Other calendars → + → From URL** → paste it.
3. Done. Cairn reads Canvas deadlines through the **Google Calendar connector it already
   has.** No new auth, no scraping, no browser automation.
4. Optionally add to `.env` for scripts: `CANVAS_ICS_URL="https://canvas.ucsd.edu/feeds/calendars/user_....ics"`

Auto-updates. Covers ~366 days / up to 1000 items.

### What the feed does NOT give you, and the fix

| Gap | Fix |
|---|---|
| **Student To-Do items** are excluded from the feed. | Nothing automatic. Minor. |
| **Syllabus text, course pages, assignment descriptions, rubrics, lecture slides.** The feed carries *dates*, not *content*. | The ~5-min-per-quarter tax: drop each syllabus into `courses/<term>/<course>/syllabus.md` with its stakes line. Everything else (practice questions, readings) goes in via **Google Drive**, which is the file-ingestion channel. |
| **Grades.** | Not available. Ask Roman when it matters. |

**This is the honest ceiling of the Canvas integration: Cairn will know every *deadline*
automatically, and will know *content* only for what gets dropped in.** That's a good
trade — the deadlines are the part that slips, and they're the part that's automatable.

### Fallback (only if the feed dies)
Headless browser automation (Playwright) logging in as Roman. Fragile — breaks on HTML
changes, must survive SSO/2FA. Not needed. Don't build it speculatively.

---

## 2. The five inboxes (updated 2026-07-13 — this replaces the earlier two-account plan)

**Roman has five email accounts. Cairn reads one.**

| # | Address | What | Cairn sees it | Forward it in? |
|---|---|---|---|---|
| 1 | `romanyoung9981@gmail.com` | Primary personal | ✅ **the connected one** | — (destination) |
| 2 | `romankryoung@gmail.com` | Second personal | ❌ | ✅ **yes — trivial, do it** |
| 3 | `r5young@ucsd.edu` | School | ❌ | ✅ **yes — highest value** |
| 4 | `ryoung@lji.org` | **Work — LJI** | ❌ | 🛑 **STOP. Policy check first.** |
| 5 | `ryoung@salk.edu` | **Work — Salk** (Outlook/Exchange) | ❌ | 🛑 **STOP. Policy check first.** |

**The uncomfortable fact:** the senders Roman misses most — **Dan, Danish, Ivy, Eduard** —
almost certainly write to inboxes **4 and 5**, which are exactly the two Cairn must not
naively slurp. The easy 80% of this integration does not cover the mail that matters most.

### 🛑 Why the work inboxes are not a forwarding problem

Do **not** set up auto-forwarding from `lji.org` or `salk.edu` until Roman has checked
their acceptable-use policies. Three separate reasons, any one of which is disqualifying:

1. **It may simply be against policy.** Research institutions commonly prohibit
   auto-forwarding institutional mail to personal accounts. Salk and LJI both handle
   sensitive research; an IT policy violation is a real professional risk, and "my AI
   agent needed to read it" is not a defense anyone will accept.
2. **It would route unpublished research into a personal Gmail.** The PEPMatch manuscript,
   maintainer review threads, unreviewed Salk data. Roman already has a standing rule to
   keep unpublished method details out of anything public-facing — this is the same rule,
   and forwarding would quietly break it.
3. **Blast radius.** Cairn reads untrusted input (email, web pages) while holding shell
   access on a server. Piping his employers' mail through that is a materially bigger
   security surface than piping his student mail through it.

**What to do instead — in order:**

- **Ask.** Salk IT and LJI IT: *"is auto-forwarding to a personal address permitted?"*
  One email each. The answer decides everything.
- **If forwarding is prohibited** (assume it is until told otherwise): leave the work
  inboxes out of Cairn. Roman forwards *individual* important threads by hand when he
  wants help with one. Lower coverage, zero risk, no policy exposure. **This is a fine
  outcome** — it is not a failure of the system.
- **If it's permitted**, still don't forward the whole inbox. Forward **only from named
  senders** (Dan, Danish, Ivy, Eduard, Deepshika) via a server-side rule. Narrow beats
  broad. Never forward anything with attachments containing unpublished data.

**Salk is Outlook/Exchange**, so its rules live in Outlook (Settings → Mail → Forwarding,
or an inbox Rule), not Gmail. Same policy question applies regardless of the mail system.

### ✅ Do these two now — they're safe and they cover the failure that already burned him

**#3 UCSD → primary Gmail.** This is the one that matters most and carries no policy
problem: it's his own student mail, and **the housing bill and the drop deadline both sat
unread in it.**

**#2 second personal Gmail → primary Gmail.** Gmail-to-Gmail, trivial, no downside.

Label each on arrival so Cairn can triage by source (`UCSD`, `personal-2`). Then Cairn can
honestly say *"I've triaged your personal and school mail"* — which is a true statement,
unlike "I've triaged your inbox."

### The mechanics — forward into the one Cairn already reads

**On mail.ucsd.edu:** ⚙️ → *See all settings* → **Forwarding and POP/IMAP** → *Add a
forwarding address* → `romanyoung9981@gmail.com` → confirm the code Google sends →
select **"Forward a copy of incoming mail to…"**, and set it to **keep UCSD's copy in
the Inbox**.

**On `romankryoung@gmail.com`** (second personal): same thing — ⚙️ → **Forwarding and
POP/IMAP** → forward to `romanyoung9981@gmail.com`.

**On the primary Gmail** (`romanyoung9981@gmail.com`), label each source so Cairn can
triage by origin: ⚙️ → *See all settings* → **Filters and Blocked Addresses** → *Create a
new filter* → **To:** `r5young@ucsd.edu` → *Create filter* → ✅ **Apply the label** → new
label **`UCSD`** → ✅ **Never send it to Spam**. Repeat with **To:** `romankryoung@gmail.com`
→ label **`personal-2`**.

Then tell Cairn the label names, and it triages `label:UCSD` explicitly.

- **Why this is right:** zero new auth, zero new attack surface, works headlessly *if
  the existing connector does*, and gives one inbox to triage instead of five. It
  directly fixes the failure that actually burned Roman — the housing bill and the drop
  deadline both sat unread in UCSD mail.
- **Cost:** Cairn can't *draft from* the UCSD address. Given the standing rule is
  **draft-only, never send**, and Roman sends manually anyway, this costs approximately
  nothing — he pastes the draft into whichever account he wants.
- **If UCSD blocks auto-forwarding** (some universities do): invert it. Personal Gmail →
  *Accounts and Import* → **Check mail from other accounts** (POP). Pulls UCSD mail in
  rather than pushing it out. Same end state.

### ⚠️ The honesty rule that comes with all this

Until every inbox is covered, **Cairn must never say "I triaged your inbox" or "nothing
important came in."** It must name *which* inboxes it read. Right now that is **one of
five**, and the four it can't see contain **every work email from Dan, Danish, Ivy, and
Eduard** — i.e. the senders Roman misses most.

Overstating coverage is the single most damaging thing this agent could do here, because
Roman would stop checking himself, and the mail he'd stop checking is the mail that
matters. Partial coverage stated honestly is useful. Partial coverage stated as total is
worse than nothing.

### Option B — Add a second account to the claude.ai Gmail connector

**Status: unverified, and I can't verify it from here.** claude.ai connectors are
managed in the claude.ai web UI, and this session can't run an OAuth flow. A claude.ai
Gmail connector authorizes *one* Google account; whether a second can be added alongside
it (vs. replacing it) is a question for the connector settings page.

**If you want this, go look:** claude.ai → Settings → Connectors → Gmail. If it offers
"add account," great. If re-authorizing would *replace* the existing account, **stop** —
that's a downgrade, not an upgrade.

Even if it works, it inherits the headless problem above. **Option A is strictly better
for the UCSD case.** Option B only earns its place if you need to *act as* a second
account, which the draft-only rule means you don't.

### Option C — Server-side Gmail MCP with per-account tokens

The real multi-account answer, and **the mandatory one if the headless test above fails.**

Run a Gmail MCP server on the Hetzner box, registered in a project `.mcp.json`, holding
OAuth refresh tokens for N Google accounts in the gitignored `.env`. Claude Code — both
interactive and headless — talks to it locally.

- **Pros:** true multi-account. Works headlessly. Independent of claude.ai. Scoped by
  *you* (grant read-only where possible).
- **Cons:** real setup work — Google Cloud project, OAuth client, consent screen,
  per-account refresh tokens, token rotation. This is a build, not a click.
- **Verdict: do NOT build this speculatively.** It's exactly the kind of infrastructure
  that has eaten three sessions (`insights.md` #1). Build it **only** when the headless
  test proves it's necessary, or when you genuinely need to act on a second account.
  Roman's own anti-goal: *every component earns its place via real pain.*

### Recommendation

1. **Run the headless test.** It's one command and it decides the architecture.
2. **Do Option A** (forwarding + label) regardless of the result. ~5 min, high value,
   fixes a failure that has already cost you.
3. **Only then** consider B or C, and only if the test or a real need forces it.

---

## Security notes

- The Canvas `.ics` URL is an **unauthenticated link to your schedule**. `.env` only,
  never a tracked file, never a chat transcript.
- Granting Cairn broader email access widens the blast radius of prompt injection:
  **it reads untrusted input (email, web pages) while holding shell access.** Keep email
  **read + draft only**. The `create_draft` permission stays ask-first. Never grant send.
- Prefer read-only scopes on anything new. (The Hetzner token decision — read-only —
  is the precedent: *an agent that reads email should not be able to destroy infra.*)
