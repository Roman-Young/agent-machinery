# Canvas access — SOLVED without a token

UCSD blocks the Canvas MCP **and** blocks students from minting their own API access
tokens. Neither matters. Use the calendar feed.

## The solution: Canvas iCal feed -> Google Calendar -> agent

Every Canvas user has a personal iCal feed. It contains events and assignments from all
your Canvas calendars, updates automatically, and covers future events up to 366 days
out (up to 1000 items). Standard student feature — no token, no developer key, no admin
approval, nothing the school can block.

**Setup (one time, ~5 minutes):**
1. Canvas -> **Calendar** -> sidebar -> **Calendar Feed** -> copy the unique .ics URL.
   (Treat this URL as a secret — it's an unauthenticated link to your schedule.)
2. Google Calendar -> **Other calendars -> + -> From URL** -> paste it.
3. Done. The agent reads Canvas deadlines through the **Google Calendar MCP connector
   it already has.** Zero new auth, zero scraping, no fragile browser automation.

If a script needs it directly, put it in agent.env (gitignored):
`CANVAS_ICS_URL="https://canvas.ucsd.edu/feeds/calendars/user_....ics"`

## What the feed does NOT include
- **Student To-Do items** are excluded.
- **Syllabus text / course pages.** The feed carries dates, not content.

## Handling syllabi (the 5-min-per-quarter tax)
Each quarter, drop each syllabus into `my-context/courses/<QUARTER>/<COURSE>.md`.
The agent then has structure (topics, grading weights, exam dates) alongside the
auto-updating deadlines. One small, infrequent manual step.

## Fallback (only if the feed is unavailable)
Headless browser automation (Playwright) logging in as you. Fragile — breaks on HTML
changes, must handle SSO/2FA. Not needed given the feed works.

## Status
Ready to set up any time. Highest-value phase-2 item: it permanently kills the
"manually re-enter deadlines every quarter" problem.
