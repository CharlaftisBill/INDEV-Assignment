---
name: fix-next-bug
description: Fix one Open bug from docs/ai-workflow/bugs.md (next in scope, or a given B-NNN) - reproduce, root cause, fix via the right agent, verify, mark Solved. Use for "fix the next bug", "fix B-004", or after a verify/review run opened bugs.
---

# Fix the next open bug

Argument (optional): a bug ID (`B-004`). Without it, select the next bug as below.
Works on **one** bug per run. Read the `TODO.md` Status line and the `## Open` list in `docs/ai-workflow/bugs.md` first.

## 1. Select
If a bug ID was given as argument, take it (if it is not Open, say so and stop) and skip the rest of this step.

Otherwise, from `docs/ai-workflow/bugs.md` (`## Open` list, then each bug's meta line):
1. **Filter first.** Keep Open bugs whose milestone is the **current** milestone (Status line) or an earlier one
   (compare the numbers: M0 < M1 < … < M10). Drop bugs whose **Fix** field contains the marker `[stuck` (the `review-loop` skill
   appends `[stuck rN]` to bugs this skill gave up on; match the bracketed marker, not the plain word, which bug
   descriptions may use).
   Open bugs for **later** milestones are **deferred**: they wait until their milestone becomes current, because the code they
   concern usually doesn't exist yet. Never pick them automatically.
2. **Then order** what is left: `[sec]` bugs → Sev `Critical` → Sev `High` → everything else; oldest ID first
   within each group.

If nothing is left: report "No open bugs in scope", with the counts `Open in scope: 0 · Deferred: N (IDs) · Stuck: N · Solved: N`, and stop.
To work a deferred bug early, the user names it explicitly (`fix-next-bug B-008`); then say it is ahead of its milestone and
stop instead if the fix needs a role that is not built yet.
Announce the pick in one line: `Fixing B-NNN (<milestone>): <title>`.

## 1b. Branch
Every bug gets its own branch `fix/b-nnn-<slug>` (e.g. `fix/b-020-make-allow-rules`). Pick the parent:
- the code to fix exists only on the current milestone branch (`feat/m<n>-*`) → branch from that branch;
- otherwise → `git switch main && git pull --ff-only` and branch from `main`.

Commit or stash nothing on your own: if the working tree has unrelated uncommitted changes, stop and ask.
`git switch -c fix/b-nnn-<slug>`. Note the parent; step 6 merges back into it.

## 2. Reproduce before touching anything
- Re-read the bug's entry in `docs/ai-workflow/bugs.md` (Report: evidence, suggested direction).
- Reproduce the symptom with a concrete command: the failing `make verify REQ=<id> STRICT=1` check, `make lint`, `make idempotency TAGS=<role>`,
  a `kubectl`/`limactl shell` inspection, or a small test case. Record the command and its output.
- If it no longer reproduces: don't mark it Solved on a guess. Find which change fixed it (`git log -S`, `git log -- <path>`);
  if you can name the commit, solve it with that hash and "no longer reproduces since <hash>"; otherwise update its one-line **Direction** with the finding,
  leave it Open, and ask the user.
- If the VM is needed and down, use the `vm-lifecycle` skill (`make vm-up`). Never reset/destroy the VM without asking.

## 3. Root cause
Find the cause, not just the symptom: read the role/template/script involved, compare with what the check expects,
and look for the same mistake elsewhere (grep). Write the cause in one sentence; it goes into the bug's entry (**Root cause**).

## 4. Fix (smallest change that removes the cause)
Route by where the cause lives:
| Cause in | Who fixes |
|---|---|
| `ansible/roles/**`, `group_vars`, `site.yml` | delegate to the **ansible-engineer** agent with the bug ID, reproduction command, root cause and the expected check |
| `docs/**`, `README.md` | delegate to the **docs-writer** agent |
| `scripts/`, `Makefile`, `lima/`, `.claude/`, `.githooks/`, lint configs | fix it directly |

Rules: stay inside the bug's scope (other problems you notice become new bugs via the `bug` skill, not part of this fix);
respect every hard rule in `CLAUDE.md` (pinning, idempotency, PSA, no secrets).

## 5. Verify
All of these must pass before the bug can be Solved:
- The reproduction command from step 2 now shows the expected result.
- `make lint`.
- If a role changed: `make provision TAGS=<role>` and `make idempotency TAGS=<role>` (`changed=0`), then `make verify REQ=<id> STRICT=1` for each ID in the IDs
  that role delivers (Requirement column of the role table in `docs/architecture.md`), limited to IDs whose
  milestone is ticked or current; the **k8s-verifier** agent can run this.
- If `scripts/verify.sh`, the Makefile or `.claude/` changed: `make verify REQ=<id> STRICT=1` for each ID in the ticked milestones still passes (skip if no ticked milestone has IDs yet)
  (a tooling fix must not turn a delivered check into a SKIP).
- If the bug is `[sec]`: ask the **security-reviewer** agent to re-check that specific finding.
- If the bug is `[sre]` and you are not running inside `review-loop` (which re-reviews every fix anyway): ask the
  **sre-reviewer** agent to re-check that specific finding.

If verification fails after 3 attempts: put what you learned in its one-line **Direction** (entry stays ≤ 5 lines), leave it **Open**, and stop with a summary.

## 6. Close
- Mark the bug Solved with the `bug` skill: meta line `State: Solved` + `Solved: <today>` + `Fix: uncommitted`, line removed from `## Open`; **Direction** replaced by one line each of **Root cause**, **Fix**, **Verification**.
- If the fix changes behaviour that is documented, make sure the docs were updated (docs-writer).
- Add one line to the current milestone's entry in `docs/ai-workflow/log.md` if the bug was found by an agent or hook
  (it's evidence of the workflow catching something).
- Report: bug ID, root cause, files changed, verification commands and results.
- Commit with the `split-commits` skill (`fix(<scope>): <summary> (B-NNN)`, then `chore(todo)` with the hash) when the user approves.
  No AI attribution trailers. Then land the branch (each step asks): parent is a milestone branch → `git switch <parent>`,
  `git merge --no-ff fix/b-nnn-<slug>`, `git branch -d fix/b-nnn-<slug>`; parent is `main` → review gate (`split-commits` step 5), push + `gh pr create --base main`,
  and stop until the user merges (a running milestone branch then merges `main`).
- If more bugs are Open, say which one is next; don't start it without being asked
  (inside the `review-loop` skill, the loop decides what runs next).
