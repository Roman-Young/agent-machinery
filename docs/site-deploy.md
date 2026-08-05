# Personal website — gated auto-deploy (roman-young.dev)

Lets Kairo prepare changes to the personal website and get them onto a **Vercel preview**;
**production only goes live on Roman's approval** (autonomy contract, 2026-08-04).

- **Repo:** `github.com/Roman-Young/personal-website` (Vite + React), cloned at
  `~/agent/codebases/personal-website`. Hosted on **Vercel**, domain `roman-young.dev`.
- **Scripts:** `scripts/site-deploy.sh` (the pipeline) + `scripts/git-credential-cairo-write.sh`
  (write-scoped credential helper, isolated to this one repo).

## Flow

```
Kairo edits files → site-deploy.sh open "<msg>" [slug]
    → build gate (npm run build; abort if broken)
    → branch kairo/<slug>, commit (no trailer), push, open PR
    → Vercel comments a PREVIEW url on the PR      ← nothing live yet
Roman reviews the preview URL → approves
    → site-deploy.sh merge <pr#>   → merge to main → Vercel PRODUCTION deploy
```

`site-deploy.sh status` lists open Kairo PRs awaiting review.

## One-time setup (Roman does these — Kairo cannot)

Kairo's existing `GITHUB_TOKEN` is **read-only by design** (it holds a shell while reading
untrusted email/web, so every token it carries is a prompt-injection blast radius). Pushing
needs a **separate, tightly-scoped write token** — that separation is the whole point.

### 1. Create a fine-grained PAT (least privilege)

github.com → Settings → Developer settings → **Fine-grained personal access tokens** →
Generate new token:

- **Resource owner:** Roman-Young
- **Repository access:** *Only select repositories* → **personal-website** (this one repo)
- **Permissions → Repository permissions:**
  - **Contents:** Read and write
  - **Pull requests:** Read and write
  - (Metadata: Read-only — auto. Nothing else.)
- **Expiration:** 90 days (rotate; a shorter-lived write token is safer).

Even if this token ever leaked, it can only touch this single public repo.

### 2. Put it in `.env` (never anywhere tracked)

Add to `~/agent/agent-machinery/.env`:

```
GITHUB_WRITE_TOKEN=<the fine-grained PAT>
```

### 3. Wire the write helper into the repo only

```bash
REPO="$HOME/agent/codebases/personal-website"
SCRIPTS="$HOME/agent/agent-machinery/scripts"
git -C "$REPO" config --local --replace-all credential.helper ""
git -C "$REPO" config --local --add credential.helper "$SCRIPTS/git-credential-cairo-write.sh"
```

The empty first value clears the inherited global (read-only) helper for this repo, so pushes
here use the write token and every other repo keeps using the read-only one.

### 4. First real end-to-end test (do NOT skip — "an unrun job is not a working job")

Once the token exists, Kairo runs ONE trivial change through the full path (branch → PR →
preview URL → merge) to prove push, PR, Vercel preview, and production deploy all actually
fire — before this is trusted for a real edit.

## Guardrails baked in

- **Build gate:** never pushes a site that doesn't compile.
- **No auto-merge:** `merge` is a separate, human-invoked command. Kairo never runs it unprompted.
- **No commit trailer:** commits carry no `Co-Authored-By`/"Generated with" line.
- **Two-writer safety:** warns if `origin/main` moved (Roman pushed from his Mac) before merge.
