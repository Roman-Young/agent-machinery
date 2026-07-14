# Permissions — the architecture, and the mistake that cost two days

## The mistake

`agent-machinery/.claude/settings.json` held a careful 123-line policy. **It governed
nothing.**

Claude Code loads a project's `.claude/settings.json` only when the working directory is
**inside that project**. Nobody ever runs Claude from inside `agent-machinery/`:

- interactive sessions (Paseo) run from `~/agent`
- headless jobs `cd` to `~/agent/my-context`

So the only policy in force was `~/.claude/settings.json` — 25 lines, **zero Bash allow
rules**. Every automation "bug" of 2026-07-13/14 traces to this one fact:

| Symptom | Actual cause |
|---|---|
| Nightly journal died in cron | `Bash(find *)` denied — the allow rule was in the dead file |
| MCP tools denied in headless runs | the MCP allow list was in the dead file |
| Every Bash call needed approval | no Bash allow rule was ever in force |

**One bug, five faces.**

## The fix

**`~/.claude/settings.json` (user level) is the only layer that applies at every cwd.**
So the policy must live *there* — but a policy nobody can review or version-control is how
you get drift.

So: **keep it versioned here, render it there.**

```
agent-machinery/.claude/settings.json   ← EDIT THIS (versioned, reviewed, path-free)
              │
              │  scripts/install-permissions.sh
              ▼
      ~/.claude/settings.json           ← GENERATED. Never hand-edit. Applies everywhere.
```

**Editing the repo file alone does nothing. Always re-run the installer.**

## The security model (honest version)

**1. Bash is broadly allowed for interactive work.** Roman's explicit call, 2026-07-14 —
the approval friction was costing more than it bought. The deny list stops the destructive
and the accidental (`rm`, `dd`, `git reset --hard`, force-push, reading `.env`/`.ssh`).

**It is not a sandbox.** Prefix matching cannot stop `python -c "..."` or `find -delete`.
Against a determined adversary it is a speed bump, not a wall. Anyone who tells you
otherwise is selling something.

**2. The real boundary is the job allowlist — and this is what makes (1) safe.**

Cairn reads **untrusted input**: email, web pages. Untrusted input plus shell access is the
whole prompt-injection threat model. The mitigation is that **the jobs which ingest
untrusted content pass their own explicit `--allowedTools` that exclude Bash entirely.**

```
morning-brief.sh  →  Read, Glob, Grep, Gmail(read), Calendar(read)   ← NO BASH. NO SEND.
nightly-journal.sh → Read, Glob, Grep, Edit, Write, git diff/log     ← no email, no web
```

So the path *malicious email → shell command* **does not exist**. Interactive sessions have
broad Bash, but Roman is sitting there.

> ⚠️ **NEVER add Bash to a job that reads email or fetches web content.** That single change
> would undo the entire model. If you find yourself wanting to, restructure the job instead.

**3. Outward-facing and irreversible actions still ask, every time.** `git push`, `sudo`.
Email is draft-only — enforced by *not granting the send tool*, not by a policy string.

**4. Every credential is read-only by construction.** The GitHub PAT is fine-grained,
read-only, selected repos. The Hetzner token is read-only. Worst case is disclosure of
things Roman already owns — never destruction.

## settings.local.json must stay empty

It auto-appends a rule **every time you click "always allow."** Nobody re-reads it.

- **2026-07-12:** it had silently collected `Read(//home/roman/.ssh/**)` — read access to
  the private deploy keys.
- **2026-07-14:** it had re-accumulated **12 rules**, including `git push origin main` for
  both repos — which policy says must **ask**.

`install-permissions.sh` **resets it to empty on every run.** If a rule genuinely belongs,
it goes in the versioned file where a human reviews it — not in the file nobody looks at.

This is `insights.md` #9. It has now happened twice. The installer exists so it can't
happen a third time.

## Changing the policy

```bash
$EDITOR agent-machinery/.claude/settings.json   # 1. edit the versioned policy
./scripts/install-permissions.sh                # 2. render it where it applies
./scripts/healthcheck.sh                        # 3. PROVE it still works
```

Step 3 is not optional. Every bug in this system came from skipping it.
