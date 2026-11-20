# Git workflow

Every milestone and every bug gets its own branch. Nothing is committed on `main`; the `pre-commit` hook blocks it.

| Work | Branch | Cut from | Lands by |
|---|---|---|---|
| Milestone | `feat/m<n>-<slug>` | `main` | PR to `main` |
| Bug in code already on `main` | `fix/b-nnn-<slug>` | `main` | PR to `main`; an open milestone branch then merges `main` |
| Bug in code only on a milestone branch | `fix/b-nnn-<slug>` | that milestone branch | `git merge --no-ff` into it |
| Other tooling or docs | `chore/<slug>` | `main` | PR to `main` |

## Rules

- Agents work on the current branch. Only the main session creates, merges and pushes branches (skills `milestone`,
  `fix-next-bug`, `split-commits`), and asks the user at each step.
- The user merges PRs with **Create a merge commit**. Squash or rebase would change the commit hashes that
  [bugs.md](bugs.md) records for solved bugs.
- Reviews look at the branch diff by default (`main...HEAD` plus uncommitted changes).
- **Review gate**: before every PR, the user is asked whether to run `review-loop` on the branch. It is skipped only
  when a clean review already covers the last change. Bugs it opens get their own branches and are merged back
  before the PR.
- Commits follow Conventional Commits and carry no AI attribution; the `commit-msg` hook checks both.
