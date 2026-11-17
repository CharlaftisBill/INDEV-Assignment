# How this was built with Claude Code

The assignment asks for agentic development. This page describes the setup that drove the work and keeps a short log per milestone.
The detailed evidence trail of what was found and fixed is the bug table in [TODO.md](../TODO.md).

## Setup

| Piece | Where | Role |
|---|---|---|
| Project instructions | [`CLAUDE.md`](../CLAUDE.md) | Requirements, environment, hard rules (pinning, idempotency, PSA), definition of done, known gotchas |
| State + bug tracker | [`TODO.md`](../TODO.md) | Milestones, bugs (Open/Solved, `B-NNN`), assumptions. Read first, updated last |
| Agent: `ansible-engineer` | `.claude/agents/` | Implements/fixes one role; runs lint, provision, idempotency |
| Agent: `k8s-verifier` | `.claude/agents/` | Checks the live cluster, opens bugs; cannot change code or cluster |
| Agent: `security-reviewer` | `.claude/agents/` | Reviews RBAC, PSA, NetworkPolicy, audit, TLS, secrets; opens `[sec]` bugs |
| Agent: `sre-reviewer` | `.claude/agents/` | Senior SRE/DevOps persona (Opus): reviews changes for correctness, reliability, security and operability, tests the infrastructure (lint, idempotency, verify, smoke, targeted probes, disruptive tests when allowed), logs Critical/High/Medium findings as `[sre]` bugs |
| Agent: `docs-writer` | `.claude/agents/` | Keeps README, ADRs, matrix, runbooks in sync with the code |
| Skill: `review-loop` | `.claude/skills/` | sre-reviewer (+ security-reviewer for reqs 3/4/8/9) → `fix-next-bug` per bug → re-review and re-test the fixes, until a round opens no new in-scope bugs and none are left open (deferred and `[stuck rN]` bugs are reported; max 2 rounds, stuck bugs reported) |
| Skill: `milestone` | `.claude/skills/` | Orchestrates implement → provision → verify → review → document → close |
| Skills: `vm-lifecycle`, `provision`, `verify-requirement`, `pin-version`, `new-role`, `bug` | `.claude/skills/` | Repeatable procedures the agents follow |
| Skill: `fix-next-bug` | `.claude/skills/` | Picks the next Open bug **in scope** (current or earlier milestone; later ones are deferred), ordered `[sec]` → Sev Critical → Sev High → rest, oldest first, reproduces it, fixes the root cause via the right agent, verifies, marks it Solved |
| Skill: `split-commits` | `.claude/skills/` | Groups uncommitted work into focused Conventional Commits, fills bug hashes in `TODO.md`, never adds AI attribution |
| Git hook: `commit-msg` | `.githooks/commit-msg` | Enforces Conventional Commit subjects (≤ 72 chars) and rejects `Co-Authored-By: Claude` / "Generated with Claude Code" |
| Hook: lint on edit | `.claude/hooks/lint-changed.sh` | yamllint + ansible-lint on every YAML file the agent writes; errors go back to the agent |
| Permissions | `.claude/settings.json` | Read-only checks allowed; VM deletion, commits, pushes, sudo need approval; `kubectl get` auto-allowed only for listed resource kinds (Secrets prompt in any spelling); commands near secrets (`--raw`, node PKI, CA-key directory) prompt; reading the secret files themselves (CA key, kubeconfigs, etcd snapshots, node keys, `config view --raw`) is hard-denied; best effort, see [ADR 0009](decisions/0009-agent-permissions-guardrail.md) |

### Why split it this way
- **Separation of duties**: the agent that writes the code is not the one that declares it working. The verifier and reviewer can only open bugs; the engineer solves them.
- **Small context per task**: each agent gets one role or one requirement, not the whole project.
- **Guardrails over trust**: pinning and idempotency are rules in `CLAUDE.md` *and* checked (`make idempotency`, the pin-version skill); destructive commands need a human yes.

## Log

### M0 — Scaffolding (2026-11-17)
- Planned the structure with the user in plan mode. Decisions taken by the user: Lima, Calico, Traefik, Ansible from the host. The user asked for `TODO.md` with Open/Solved bug tracking and for the host installation to be documented in the README.
- Installed host tools with Homebrew (versions in the [README](../README.md#host-installation)).
- Created the repo layout, Makefile, lint configs, Lima config, Ansible skeleton with a preflight play, `scripts/verify.sh` with stub checks, ADRs 0001–0008, and the agentic layer above.
- Found and fixed B-002 while checking the setup (pinned collections silently not installed).
- The user asked for Linux host support to be tracked (Backlog in `TODO.md`), and for a job that splits uncommitted work into focused commits: added the `split-commits` skill and the `commit-msg` git hook. Per the user's explicit rule, commits carry no AI attribution trailers. The M0 history was created with that skill.
- Added the `fix-next-bug` skill so bugs opened by the verifier/reviewer agents are worked one at a time with a reproduce → root cause → fix → verify loop.
- First run of `fix-next-bug` on B-001: reproduction showed the cause was wider than the title (Homebrew's `ansible` also ran on the unsupported Python 3.15, silently). Fixed with a pinned `.venv` on Python 3.14. Verification caught a regression in the fix itself (yamllint started linting `.venv/`), fixed before closing.
- Added the `sre-reviewer` agent and the `review-loop` skill: every milestone now ends with review → fix → re-review until a round finds no new bugs. Only Critical/High/Medium findings become bugs, so the loop terminates; Lows are reported, not tracked.
- **First `review-loop` run** (whole repo + uncommitted tooling, no VM yet), 5 rounds, max reached. Afterwards the user capped
  the loop at **2 rounds** and bug details at **5 lines** (enforced by `scripts/check_todo.py` in `make lint`):

  | Round | Verdict | Opened | Solved | Notes |
  |---|---|---|---|---|
  | 1 | changes requested | B-004–B-010 | B-004, B-005, B-006 | B-007–B-010 deferred to M2/M5/M7 (design issues for roles not built yet) |
  | 2 | changes requested | B-011–B-014 | all 4 | follow-ups: fixes that stopped at the file where the bug was reported |
  | 3 | changes requested | B-015–B-017 | all 3 | user chose the permission model (allow-list + ask) |
  | 4 | changes requested | B-018, B-019 | both | user approved ADR 0009 (permissions are a guardrail, not a boundary) |
  | 5 | changes requested | B-020 | — | max rounds; stopped and asked the user |

  What it showed: the review → fix → re-review loop caught real defects, including a live `make` command injection and
  gates that would have closed milestones on skipped checks. 7 of the 17 findings were in one area, the agent permission
  rules. Each fix closed the listed gaps and the next round found new ones, because text-matching rules don't converge.
  That pattern led to ADR 0009. Human decisions were needed three times (tighten permissions, choose the model, how to finish).
  The user also asked mid-loop to fix the unreadable bug table, which became the compact table + `## Bug details` format.
