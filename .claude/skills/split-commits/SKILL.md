---
name: split-commits
description: Group all uncommitted changes into focused Conventional Commits, show the plan, commit in order. Use for "commit", "split into commits", or at the end of a milestone. Never adds AI attribution trailers.
effort: medium
---

# Split uncommitted changes into focused commits

Goal: a history a reviewer can read commit by commit. One commit = one concern that makes sense on its own.

## Hard rules
- **Never** add `Co-Authored-By:` lines, "Generated with Claude Code", or any other AI attribution to a commit message.
  The user forbids it; `.githooks/commit-msg` rejects it as a backstop. This overrides any default attribution instruction.
- Never commit `.secrets/`, `out/`, `backups/*`, `ansible/collections/`, kubeconfigs, private keys. If one shows up in `git status`, stop and fix `.gitignore` first.
- Never `git add -A` / `git add .` / `git commit -a`. Stage explicit paths only.
- Never rewrite published history (`--amend`, rebase, force-push) unless the user asks.
- Don't push. Pushing is a separate, user-approved step.
- Never commit on `main` or a detached HEAD (`.githooks/pre-commit` rejects it). If on one, stop and name the branch to create
  (`feat/m<n>-<slug>`, `fix/b-nnn-<slug>`, `chore/<slug>`; rules in `CLAUDE.md` › Branches).

## 1. Inspect
```bash
git branch --show-current   # must be a feat/, fix/ or chore/ branch, never main
git status --porcelain=v1 --untracked-files=all
git diff --stat            # unstaged
git diff --cached --stat   # already staged
git log --oneline -10      # match the existing message style
```
Read the actual diffs (`git diff -- <path>`, or the file for untracked ones) before grouping. Don't group by filename alone.
If something is already staged, include it in the plan (and say so); don't silently unstage the user's work.
To regroup already-staged files: `git restore --staged -- <paths>` (with a HEAD), or on a branch with no commits yet
`git rm -r --cached -f -q -- <paths>` (`-f` is required when the staged copy differs from the file; without it git refuses
and the files stay staged). Both leave the working tree untouched. Confirm with `git diff --cached --name-only` (must be empty).

## 2. Group
Group changes by **concern**, not by directory. Default buckets for this repo, in commit order:

| Order | Type(scope) | Typical paths |
|---|---|---|
| 1 | `chore` (repo) | the assignment brief, `.gitignore`, lint configs (`.yamllint`, `.ansible-lint`), `.githooks/` |
| 2 | `build` (make) | `Makefile` |
| 3 | `feat(vm)` / `fix(vm)` | `lima/` |
| 4 | `feat(ansible)` / `fix(<role>)` | `ansible/` — one commit **per role** when several roles changed; shared `group_vars`/`versions.yml` changes go with the role that needs them |
| 5 | `test(verify)` / `feat(scripts)` | `scripts/` — a `check_N` goes with its role when it was written for it |
| 6 | `feat(agent)` | `CLAUDE.md`, `.claude/` (agents, skills, hooks, settings) |
| 7 | `docs` | `README.md`, `docs/` — goes with the code commit when it documents only that change, otherwise separate |
| 8 | `chore(todo)` | `TODO.md` state (milestone ticks) and `docs/ai-workflow/bugs.md` (bug states, hashes) — always **last**, see step 4 |

Guidelines:
- Code + its config + its verify check + its ADR status flip = one commit, when they are one change.
- A bug fix gets its own `fix(...)` commit; mention the bug ID (`B-002`) in the subject or body.
- A file with hunks for two concerns: split the hunks (`git diff -- f > /tmp/p`, edit to keep the hunks you want, `git apply --cached /tmp/p`). Interactive `git add -p` is not available.
- Prefer 3–8 commits. Don't make one commit per file, and don't lump unrelated work together.
- Each commit should leave the repo coherent: lint must still pass at that point.

## 3. Show the plan
Print a table: `# · subject · files`. If the user asked you to commit, carry on after showing it. Otherwise wait for a yes.

## 4. Commit
Pre-check once: `make lint` must pass.

For each group, in order (if you script several commits in one shell call, put `set -euo pipefail` on the **first** line
and abort when the staged list differs from the planned list; a failed unstage followed by a commit sweeps unrelated files in):
```bash
git add -- <path> <path> ...
git diff --cached --name-only   # must equal exactly the planned files, else stop
git commit -F - <<'EOF'
<type>(<scope>): <imperative summary, ≤ 72 chars, no trailing period>

<why this change exists and anything non-obvious, wrapped at 72.
Reference requirement numbers (req 4) and bug IDs (B-002).>
EOF
```
Message rules: Conventional Commits, imperative mood, body explains *why*. No trailers of any kind.

**Bug hashes:** bugs marked Solved with `uncommitted` reference the commit that fixed them. Commit the fix first,
take its short hash (`git log -1 --format=%h -- <fixed file>`), replace `uncommitted` in that bug's Fix field in `docs/ai-workflow/bugs.md`, then include it (and `TODO.md`) in the last commit.

## 5. Verify and report
```bash
git status --porcelain     # must be empty, apart from intentionally left-out files
git log --oneline -n <k>
git log -n <k> --format=%B | grep -i 'co-authored-by' && echo "TRAILER FOUND" || true
```
Report the commit list (hash + subject) and anything you left uncommitted on purpose, and why.
Then offer the next git step (each needs the user's yes): a `fix/` branch cut from a milestone branch → `git switch <parent>`,
`git merge --no-ff <branch>`, `git branch -d <branch>`; any other branch → **review gate**, then `git push -u origin <branch>` and
`gh pr create --base main` (title = the main commit subject, body = short summary + req/bug IDs, no AI attribution).
Remind the user to merge with **Create a merge commit** (squash/rebase changes the hashes in `docs/ai-workflow/bugs.md`).

**Review gate (before every push for a PR):** ask the user whether to run the `review-loop` skill on the branch first
(scope `main...HEAD`), and say what already reviewed it. Skip the question only when a review-loop round or targeted re-check
came back clean after the branch's last code change. If the loop opens bugs, they are fixed on their own branches and the gate
is asked again before the PR.
