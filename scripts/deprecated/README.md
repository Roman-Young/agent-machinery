# deprecated/

## mac-sync-install.sh — DO NOT RUN. Superseded 2026-07-14.

It **collided** with `cairo-on-mac-install.sh`: both wrote `~/.cairn/sync.sh` and both
registered the *same* launchd label (`dev.cairn.sync`), so whichever ran second silently
clobbered the first. Roman caught it by asking "so I run both of these?" — the answer was
no, and that was a bug, not a design.

Everything it did is now folded into **`cairo-on-mac-install.sh`**, which is the single Mac
installer and handles all three sync directions in one job.

Kept, not deleted — the archive rule. Do not resurrect it.
