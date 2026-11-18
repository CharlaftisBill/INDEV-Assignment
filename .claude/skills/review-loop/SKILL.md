---
name: review-loop
description: Review → fix → re-review loop (max 2 rounds). sre-reviewer (+ security-reviewer for reqs 3/4/8/9) reviews the diff and tests, fix-next-bug fixes each bug, then the fixes are re-reviewed. Use after a milestone or for "review and fix until clean".
---

# Review → fix → re-review until clean

Arguments (optional):
- scope: `uncommitted` | `<from>..HEAD` | `M<n>`. Default on a branch: `main...HEAD` + uncommitted; on `main` (legacy):
  since the `Last SRE review` hash in `TODO.md` + uncommitted.
  Reviewers read the diff and the code around it, not the whole repo.
- `full`: whole-repo review with the full checklists. Only at M10 or when the user asks.
- `disruptive`: allow disruptive tests (kubelet/containerd restart, pod deletion, VM reboot, etcd restore drill).
  Never assume this; if not given and the scope touches req 2, 6, 7 or 9, ask the user once at the start.
- `max-rounds=<n>`: **at most 2** (the user's limit; default 2). A lower value is allowed, never a higher one.

## 0. Baseline
- Read `TODO.md`. Note the HEAD hash, the in-scope Open bugs (part of this loop) and the deferred ones (later milestones; not worked here).
- Bugs that `fix-next-bug` has already given up on (their **Fix** column holds the marker `[stuck rN]`) are **skipped** by the loop and listed at the end.

## Each round (n = 1 … max-rounds)

### A. Review + test
Delegate to the **sre-reviewer** agent with:
- the scope (round 1: the argument/default; later rounds: `git diff` of everything changed since the previous round started,
  plus the bugs fixed in the previous round, so it re-tests those fixes and looks for regressions),
- whether disruptive tests are allowed, and `full` if given,
- for milestones touching req 3, 4, 8, 9: also delegate to **security-reviewer** with the same scope (and `full` if given), in parallel.

It returns a verdict and the IDs of the bugs it opened.

### B. Stop condition
Bugs are **in scope** when their milestone is the current one (Status line in `TODO.md`) or earlier; Open bugs for later
milestones are **deferred** (they concern code that doesn't exist yet and are picked up when their milestone starts).

Stop the loop when **both** hold:
- this round opened **no new in-scope** Critical/High/Medium bugs (new deferred bugs don't block the stop), and
- no in-scope Open bugs remain except stuck ones.

### C. Fix
While there are in-scope, Open, non-stuck bugs: run the **fix-next-bug** skill (one bug per call; it filters to in-scope bugs,
then orders `[sec]` → Sev Critical → Sev High → rest, oldest first).
- If `fix-next-bug` leaves a bug Open after its 3 attempts, put the marker `[stuck rN]` (N = round) in that bug's Fix column, add a one-line **Stuck:** bullet to its details entry, and move on.
- Don't batch fixes for several bugs into one change; each fix is verified on its own, on its own `fix/b-nnn-*` branch
  (fix-next-bug creates it and merges it back into the branch under review once the user approves the commit).

Then start the next round (back to A) to review and test the fixes.

### D. Guard rails
- Hitting `max-rounds` (2) without a clean round: stop, do **not** start a third review, summarize what keeps coming back (same area? same root cause?) and ask the user.
- A bug that is reopened as a regression twice → stop and ask the user; the fix approach is wrong.
- Never reset/destroy the VM, commit, merge or push inside the loop without the user saying so.

## End
Report a table per round: `round · review verdict · bugs opened · bugs solved · stuck`.
Then: final verify result (`make verify` score), remaining in-scope Open/stuck bugs, **deferred bugs by milestone**
(so they're visible, not forgotten), Low findings worth knowing.
Update the `TODO.md` Status line (`Last SRE review: <hash or working tree> <date> — clean` once clean).
Add one line to `docs/ai-workflow.md` for the current milestone: rounds, bugs found/fixed, anything notable.
Offer to commit with the `split-commits` skill (fix commits per bug, then `chore(todo)`). No AI attribution trailers.
