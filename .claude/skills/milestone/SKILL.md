---
name: milestone
description: Run one milestone (M1-M10 in TODO.md) end to end - implement, provision, verify, review-loop, docs, close, propose commits. Use for "do M3", "next milestone", "implement the monitoring requirement".
---

# Milestone workflow

Argument: a milestone ID (`M5`) or "next". If "next", take the first unchecked milestone in `TODO.md`.

## 0. Load state
- Read `TODO.md` (the milestone line, the Status line) and, in `docs/ai-workflow/bugs.md`, every **Open** bug for this milestone or an earlier one (in scope; later ones are deferred).
- Read the matching rows in `docs/requirements-matrix.md`.
- Check the VM is running: `limactl list`. If not, use the `vm-lifecycle` skill (`make vm-up`).
- Branch: `git switch main && git pull --ff-only`, then `git switch -c feat/m<n>-<slug>` (slug from the milestone line,
  e.g. `feat/m1-os-prep-containerd`). If the previous milestone's PR isn't merged yet, stop and ask. Resume on the branch if it exists.
- Update the Status line in `TODO.md` to this milestone.

## 1. Implement
Delegate to the **ansible-engineer** agent with: the milestone ID, the requirement number(s), the role(s) involved,
the in-scope Open bugs (this milestone or earlier, stuck ones included), and the definition of done from `CLAUDE.md`.
It returns after lint, provision and idempotency pass.

## 2. Verify
Delegate to the **k8s-verifier** agent with the requirement IDs this milestone delivers (as listed on its line in `TODO.md`,
including sub-IDs such as `8c`) in **strict** mode: `make verify REQ=<id> STRICT=1` for each ID in the set. A SKIP is a failure here.
- If it opened bugs → fix each with **fix-next-bug** (own `fix/b-nnn-*` branch, merged back into this one), then verify again. Max 3 loops; after that stop and ask the user.

## 3. Review until clean
Run the **review-loop** skill scoped to this milestone (`M<n>`). The **sre-reviewer** agent reviews the changes and tests the
infrastructure; for milestones touching req 3, 4, 8, 9 (M3, M5, M8, M9, M10) the **security-reviewer** runs alongside it.
Their findings are fixed one by one with **fix-next-bug** and re-reviewed until a round finds nothing new, **at most 2 review rounds**; then stop and ask the user.
Reviews are diff-scoped (this milestone's changes). At M10 run it with `full` (whole-repo review) and `disruptive` (ask the user first): reboot, kubelet restart, etcd restore drill, `make e2e`.

## 4. Document
Delegate to the **docs-writer** agent: milestone ID, what was built, versions pinned, bug IDs found and solved.

## 5. Close
- Refuse to close while any bug for this milestone **or an earlier one** is Open, **including** bugs marked `[stuck rN]` (stuck only means the automatic loop gave up; it still needs a fix or an explicit decision from the user). Deferred bugs for later milestones don't block. Report the blocking bugs and stop.
- Run the final gate **after** the review-loop fixes, right before ticking: bare `make idempotency` (whole playbook, `changed=0`),
  then `make verify REQ=<id> STRICT=1` for each ID in this milestone's IDs plus those of all ticked milestones. Refuse to tick unless all pass (no FAIL, no SKIP); a regression in an earlier milestone blocks too.
- Tick the milestone in `TODO.md`, update Status (`Current milestone` → next one, `Last verified` → today + the result of those final runs).
- Commit with the `split-commits` skill (focused Conventional Commits, e.g. one `feat(<role>)` per role, `fix(...)` per bug,
  `docs`, then `chore(todo)` last with the bug hashes filled in). Mention the milestone and requirement numbers in the bodies.
  Commit only when the user approves. No AI attribution trailers.
- Push and open the PR to `main` (review gate, push and PR each ask; see `split-commits` step 5; step 3's clean loop usually covers it). Stop there: the next milestone starts only after
  the user has merged it (with a merge commit).
