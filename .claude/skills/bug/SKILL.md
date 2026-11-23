---
name: bug
description: Open, solve or list bugs in docs/ai-workflow/bugs.md (grouped by milestone, Open list on top, Open/Solved, B-NNN). The single definition of the bug format. Use when a check fails, a review finds an issue, a fix lands, or the user asks "what's open".
effort: low
---

# Bug tracker in `docs/ai-workflow/bugs.md`

One file, two parts that are updated **together**. `make lint` checks the format (`scripts/check_bugs.py`).

## 1. `## Open` (top of the file): one line per Open bug, in ID order
```
- B-043 (M10, Medium) [sre] Parallel `/api/v1/series` over all series OOMKills Prometheus (bypasses the query caps)
```
Format `- B-NNN (<milestone>, <Sev>) <title>`, the same values as the bug's entry. `None.` when there are no Open bugs.

## 2. Milestone sections: `## M<n> — <name>`, in milestone order, each bug in ID order
```markdown
## M6 — Monitoring

### B-042 · [sre] Concurrent heavy PromQL queries OOMKill Prometheus (no query sample or concurrency caps)
Sev: Medium · State: Solved · Found: 2026-11-19 · Solved: 2026-11-19 · Fix: 83e1d34
- **Report** (<who: sre round N / k8s-verifier / user / setup>): what was observed + the key evidence (one command or `file:line`).
- **Root cause:** one sentence.
- **Fix:** what changed, main files.
- **Verification:** the command(s) that prove it, and the result.
```
- **Section** = the milestone where the bug will be fixed (current milestone by default). Create the section if missing,
  named like the milestone line in `TODO.md`. Moving a bug to another milestone = moving its block.
- **Title**: the observed symptom, one line, **at most ~100 characters**; prefix `[sec]` (security finding) or
  `[sre]` (SRE review finding). Backticks for code; no HTML-like `<...>` text.
- **Meta line**, exactly this field order: `Sev: … · State: … · Found: <date>`, then `· Solved: <date>` and
  `· Fix: …` when they apply.
  - **Sev**: `Critical`, `High`, `Medium`, `Low` for review findings (Lows logged since 2026-11-23, user); `—` for bugs found otherwise.
  - **State**: exactly `Open` or `Solved`.
  - **Fix**: absent while Open; `uncommitted` or the short commit hash once Solved. An Open bug may carry `Fix: [stuck rN]` (see Rules).
- **Bullets**: at most 4, one line each, **~200 characters max** (lint: ≤ 220). Open bug: **Report** + **Direction**
  (the suggested fix). Solved bug: **Report** + **Root cause** + **Fix** + **Verification**.
- No sub-bullets, no pasted output. Full evidence belongs in the reviewer's report and the fix commit message.

## `bug open "<title>" [M<n>] [Sev]`
1. New ID = highest existing `B-NNN` + 1, zero-padded to 3 (`B-001` if none).
2. Check for a duplicate (same root cause, Open or Solved). If Open, add the new evidence to its entry instead.
   If Solved and it came back, open a new bug titled `... (regression of B-0NN)`.
3. Add the block at the end of its milestone section (meta: State `Open`, no Solved, no Fix; bullets **Report** + **Direction**),
   and its line to `## Open`.

## `bug solve B-NNN [<commit>]`
1. Only after the fix is verified: the relevant `make verify REQ=<id> STRICT=1` passes (no FAIL and no SKIP), or, for findings
   that no requirement check covers, the reproduction command from `fix-next-bug` now shows the expected result.
2. Meta line: `State: Solved`, add `Solved: <today>` and `Fix: uncommitted` (or the hash).
3. Replace **Direction** with **Root cause**, **Fix**, **Verification** (one line each). Keep the Report.
4. Remove its line from `## Open`.
5. When the commit lands (`split-commits`), replace `uncommitted` with the short hash.

## `bug list [open|all] [M<n>]`
Print the matching bugs (`## Open` is the open list), Open first. Summarize counts:
`Open in scope: X · Deferred: Y · Stuck: Z · Solved: N`.

To work on bugs (not just record them), use the `fix-next-bug` skill; it calls `bug solve` at the end.

## Rules
- States are exactly `Open` or `Solved`. No other states, no strikethrough, never delete a bug or reuse an ID.
- A milestone cannot be ticked while Open bugs exist for it or an earlier milestone, stuck ones included; later-milestone
  bugs are deferred and do not block (the `milestone` skill enforces this).
- `[stuck rN]` in **Fix** marks a bug `fix-next-bug` gave up on in review-loop round N; write it exactly like that
  (bracketed). Add a one-line **Stuck:** bullet (why); it still fits in 4 bullets.
- Out-of-scope issues still get an entry, in the section of the milestone where they will be fixed.
- Run `make lint` (or `.venv/bin/python3 scripts/check_bugs.py docs/ai-workflow/bugs.md`) after editing.
