# Email setup — forward 5 inboxes into 1, without getting spammed

Goal: everything lands in `romanyoung9981@gmail.com` (the inbox Cairn reads), but the
**inbox stays clean** — forwarded mail files itself into labels instead of piling up.

---

## 🔴 Read this first — the trap

The naive version is: *forward everything in, and auto-archive it all into a label.*
**Do not do that yet.** Here's why.

Roman's actual problem is that **he misses important UCSD mail** — the housing bill and a
drop deadline both sat unread. If he now forwards UCSD mail in and **auto-archives all of
it out of sight**, and the morning brief that was supposed to surface it **does not exist
yet** (no timers are installed — nothing is scheduled), then he has made the problem
strictly **worse**: the mail is now hidden *and* nobody is reading it.

**Auto-archive is only safe once something is reading the archive.** Until the morning
brief runs, the archive is a black hole.

**The fix: a two-filter design.** One filter quietly buckets the noise. A second filter
catches the stuff that actually matters and **keeps it in the inbox, starred**. That way
the inbox gets quiet but nothing important disappears — with or without the brief.

---

## Step 1 — Turn on forwarding (at each source account)

### `r5young@ucsd.edu` → primary
1. Sign in at **mail.ucsd.edu**.
2. ⚙️ → **See all settings** → **Forwarding and POP/IMAP**.
3. **Add a forwarding address** → `romanyoung9981@gmail.com`.
4. Google sends a confirmation code to the primary — open it, confirm.
5. Back in settings: select **"Forward a copy of incoming mail to…"**.
6. Set the dropdown to **"keep UCSD's copy in the Inbox"** (so nothing is lost if the
   forward ever breaks).
7. **Save Changes** ← easy to forget; the page doesn't save on its own.

### `romankryoung@gmail.com` → primary
Same steps, in that account's Gmail settings. Forward to `romanyoung9981@gmail.com`.

### `ryoung@lji.org` and `ryoung@salk.edu`
🛑 **NOT YET.** These are institutional research accounts. Ask Salk IT and LJI IT whether
auto-forwarding to a personal address is permitted **before** touching them. See
`integrations-plan.md` — three independent reasons this could be a problem, including
routing unpublished research into a personal account.

---

## Step 2 — The filters (in the primary Gmail)

Do these in the primary account: ⚙️ → **See all settings** → **Filters and Blocked
Addresses** → **Create a new filter**.

Gmail applies **every** matching filter, so the two below are written to be mutually
exclusive — one archives, the other doesn't, and they can never both match.

### Filter A — the safety net (do this one FIRST)

**Keeps the important stuff visible.** Paste into the **"Has the words"** box:

```
to:(r5young@ucsd.edu) AND (from:(dmarrama@lji.org OR dumar@salk.edu OR itam@salk.edu OR EAnsaldo@scripps.edu OR dramanan@ucsd.edu) OR subject:(bill OR billing OR payment OR tuition OR housing OR deadline OR registration OR enroll OR enrollment OR "action required" OR hold OR financial OR refund OR "past due"))
```

**Actions:**
- ✅ **Apply the label:** `UCSD` *(create it)*
- ✅ **Star it**
- ✅ **Never send it to Spam**
- ❌ **Do NOT** check "Skip the Inbox"

→ Result: bills, housing, deadlines, registration, and any real human land **in the inbox,
starred**. These are the ones that have burned him.

### Filter B — the quiet bucket

**Everything else from UCSD gets filed away.** Paste into **"Has the words"**:

```
to:(r5young@ucsd.edu) AND NOT (from:(dmarrama@lji.org OR dumar@salk.edu OR itam@salk.edu OR EAnsaldo@scripps.edu OR dramanan@ucsd.edu) OR subject:(bill OR billing OR payment OR tuition OR housing OR deadline OR registration OR enroll OR enrollment OR "action required" OR hold OR financial OR refund OR "past due"))
```

**Actions:**
- ✅ **Apply the label:** `UCSD`
- ✅ **Skip the Inbox (Archive it)**
- ✅ **Never send it to Spam**

→ Result: campus announcements, club blasts, newsletters — all filed under `UCSD`,
**never touching the inbox**. Cairn still reads them; Roman never sees them unless he
clicks the label.

### Filter C — second personal Gmail

**"Has the words":**
```
to:(romankryoung@gmail.com)
```
**Actions:** ✅ Apply label `personal-2` · ✅ **Skip the Inbox** · ✅ Never send to Spam

→ Safe to archive wholesale — it's a secondary personal account, low stakes. If something
important turns out to live there, add it to Filter A's sender list.

---

## Step 3 — Tell Cairn the label names

Cairn then triages `label:UCSD` and `label:personal-2` explicitly, and can say honestly
*"I read your personal and school mail"* — rather than the false *"I triaged your inbox."*

---

## Tuning it later

- **Too much still hitting the inbox?** Add the noisy sender to Filter B's exclusion list
  — or just narrow Filter A's keyword list.
- **Something important got archived?** Add that sender or keyword to Filter A. **Tell
  Cairn**, so it goes in `insights.md` and the filter stops leaking.
- **Once the morning brief is live** (T16 → T19 → T20), the safety net matters less,
  because something is actively reading the archive every day. Until then, keep it.

## The rule this encodes

> **Never hide mail from yourself faster than you build something that reads it.**

Auto-archiving is a promise that *someone else* is watching the pile. Right now, nobody
is — there are no timers installed. So the safety net stays until the brief is real.
