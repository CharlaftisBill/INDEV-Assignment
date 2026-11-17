---
name: milestone
description: Run one milestone of the INDEV Kubernetes assignment end to end (M1-M10 in TODO.md) - implement with ansible-engineer, provision, verify with k8s-verifier, security review where relevant, docs with docs-writer, update TODO.md, propose a commit. Use when the user says "do M3", "next milestone", "implement the monitoring requirement", or similar.
---

# Milestone workflow

Argument: a milestone ID (`M5`) or "next". If "next", take the first unchecked milestone in `TODO.md`.

## 0. Load state
- Read `TODO.md`: the milestone line, the Status line, and every **Open** bug tagged with this milestone.
- Read the matching rows in `docs/requirements-matrix.md`.
- Check the VM is running: `limactl list`. If not, use the `vm-lifecycle` skill (`make vm-up`).
- Update the Status line in `TODO.md` to this milestone.

## 1. Implement
Delegate to the **ansible-engineer** agent with: the milestone ID, the requirement number(s), the role(s) involved,
the Open bugs for this milestone, and the definition of done from `CLAUDE.md`.
It returns after lint, provision and idempotency pass.

## 2. Verify
Delegate to the **k8s-verifier** agent with the requirement number(s).
- If it opened bugs → send them back to **ansible-engineer**, then verify again. Max 3 loops; after that stop and ask the user.

## 3. Security review (milestones touching req 3, 4, 8, 9 → M3, M5, M8, M9, M10)
Delegate to the **security-reviewer** agent scoped to this milestone. Critical/High/Medium findings are Open bugs → back to step 1.

## 4. Document
Delegate to the **docs-writer** agent: milestone ID, what was built, versions pinned, bug IDs found and solved.

## 5. Close
- Refuse to close if any bug for this milestone is still **Open**. Report them and stop.
- Tick the milestone in `TODO.md`, update Status (`Current milestone` → next one, `Last verified` → today + verify score).
- Commit with the `split-commits` skill (focused Conventional Commits, e.g. one `feat(<role>)` per role, `fix(...)` per bug,
  `docs`, then `chore(todo)` last with the bug hashes filled in). Mention the milestone and requirement numbers in the bodies.
  Commit only when the user approves. No AI attribution trailers.
