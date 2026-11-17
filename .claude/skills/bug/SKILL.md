---
name: bug
description: Open, solve or list bugs in the TODO.md bug table with a consistent format (states are only Open or Solved, sequential B-NNN IDs). Use whenever a check fails, a review finds an issue, a defect is fixed, or the user asks "what's broken / what's open".
---

# Bug tracker in TODO.md

Table (section `## Bugs` in `TODO.md`), one row per bug, never deleted:
```
| ID | Title | State | Milestone | Found | Solved | Notes / fix commit |
```

## `bug open "<title>" [M<n>]`
1. Read the table. New ID = highest existing `B-NNN` + 1, zero-padded to 3 (`B-001` if empty).
2. Check for a duplicate (same symptom, still Open). If found, add the new evidence to its Notes instead.
3. Append: `| B-NNN | <symptom, concise> | Open | M<n> | <YYYY-MM-DD> | | <evidence pointer; suspected area> |`
   - Title describes the observed symptom ("Traefik not reachable on host :443"), not a guessed cause.
   - Security findings are prefixed `[sec]`.
   - Milestone defaults to the current one from the Status line.

## `bug solve B-NNN [<commit>]`
1. Only after the fix is verified (the relevant `make verify REQ=n` passes, or the reviewer finding is addressed).
2. Set State `Solved`, Solved date = today, Notes = `<short hash or "uncommitted"> — <one-line fix description>`.
3. When the commit lands, replace `uncommitted` with the short hash.

## `bug list [open|all] [M<n>]`
Print the matching rows, Open first. Summarize counts: `Open: X · Solved: Y`.

## Rules
- States are exactly `Open` or `Solved`. No other states, no strikethrough, no deleting.
- A milestone cannot be ticked while it has Open bugs (the `milestone` skill enforces this).
- Out-of-scope issues still get a row, with the milestone where they will be fixed.
