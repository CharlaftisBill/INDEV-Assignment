---
name: bug
description: Open, solve or list bugs in TODO.md (index table + ≤5-line details entry, Open/Solved, B-NNN). The single definition of the bug format. Use when a check fails, a review finds an issue, a fix lands, or the user asks "what's open".
effort: low
---

# Bug tracker in TODO.md

Bugs live in two parts of `TODO.md`, and **both** are updated together.

## 1. Index table (section `## Bugs`): one short row per bug
```
| ID | Title | Sev | State | Milestone | Found | Solved | Fix |
|----|-------|-----|-------|-----------|-------|--------|-----|
| B-007 | [sre] Host kubeconfig at 127.0.0.1:6443 fails TLS (no loopback SAN) | Medium | Open | M2 | 2026-11-17 | | |
| B-012 | [sre] Milestone gate and `bug solve` accept SKIP | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | uncommitted |
```
Cell rules (the table must stay readable and render in any Markdown viewer):
- **Title**: the observed symptom, one line, **at most ~100 characters**; prefix `[sec]` (security finding) or `[sre]` (SRE review finding). Details go below, never in the table.
- **Sev**: `Critical`, `High`, `Medium` for review findings (Lows are never logged); `—` for bugs found otherwise.
- **State**: exactly `Open` or `Solved`.
- **Milestone**: `M<n>` where it will be fixed (current milestone by default).
- **Fix**: empty while Open; `uncommitted` or the short commit hash once Solved; may also hold the marker `[stuck rN]` (see Rules).
- No `|` characters, line breaks or HTML-like `<...>` text inside any cell. Use backticks for code.

## 2. Details (section `## Bug details`, after the table): one entry per bug, in ID order, **at most 5 lines**
```markdown
### B-NNN: <same title as the table>
- **Report** (<who: sre round N / k8s-verifier / user / setup>): what was observed + the key evidence (one command or `file:line`).
- **Direction:** the suggested fix. (Open bugs only; the fixer replaces it with the three bullets below)
- **Root cause:** one sentence. (added by the fixer)
- **Fix:** what changed, main files. (added by the fixer)
- **Verification:** the command(s) that prove it, and the result. (added by the fixer)
```
- Heading + at most 4 bullets, **one line each, ~200 characters max** (`make lint` checks: ≤ 5 lines, ≤ 220 chars per line).
  Open bug: Report + Direction. Solved bug: Report + Root cause + Fix + Verification.
- No sub-bullets, no pasted output. Full evidence belongs in the reviewer's report and the fix commit message, not here.

## `bug open "<title>" [M<n>] [Sev]`
1. Read the table. New ID = highest existing `B-NNN` + 1, zero-padded to 3 (`B-001` if empty).
2. Check for a duplicate (same root cause, Open or Solved). If Open, add the new evidence to its details entry instead.
   If Solved and it came back, open a new bug titled `... (regression of B-0NN)`.
3. Append the table row (State `Open`, Solved and Fix empty) and the details entry with the **Report** and **Direction** bullets.

## `bug solve B-NNN [<commit>]`
1. Only after the fix is verified: the relevant `make verify REQ=<id> STRICT=1` passes (no FAIL and no SKIP), or, for findings
   that no requirement check covers, the reproduction command from `fix-next-bug` now shows the expected result.
2. Table row: State `Solved`, Solved = today, Fix = `uncommitted` (or the hash).
3. Details entry: replace **Direction** with **Root cause**, **Fix**, **Verification** (one line each). Keep the Report.
4. When the commit lands (`split-commits`), replace `uncommitted` in the Fix column with the short hash.

## `bug list [open|all] [M<n>]`
Print the matching table rows, Open first. Summarize counts: `Open in scope: X · Deferred: Y · Stuck: Z · Solved: N`.

To work on bugs (not just record them), use the `fix-next-bug` skill; it calls `bug solve` at the end.

## Rules
- States are exactly `Open` or `Solved`. No other states, no strikethrough, no deleting rows or details entries.
- A milestone cannot be ticked while Open bugs exist for it or an earlier milestone, stuck ones included; later-milestone bugs are deferred and do not block (the `milestone` skill enforces this).
- `[stuck rN]` in the **Fix** column marks a bug `fix-next-bug` gave up on in review-loop round N; write it exactly like that (bracketed). Add a one-line **Stuck:** bullet (why) to its details entry; it still fits in 5 lines.
- Out-of-scope issues still get a row, with the milestone where they will be fixed.
- After editing, the table must still have the same number of `|` separators on every row (8 columns).
