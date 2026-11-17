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
| Agent: `docs-writer` | `.claude/agents/` | Keeps README, ADRs, matrix, runbooks in sync with the code |
| Skill: `milestone` | `.claude/skills/` | Orchestrates implement → provision → verify → review → document → close |
| Skills: `vm-lifecycle`, `provision`, `verify-requirement`, `pin-version`, `new-role`, `bug` | `.claude/skills/` | Repeatable procedures the agents follow |
| Skill: `split-commits` | `.claude/skills/` | Groups uncommitted work into focused Conventional Commits, fills bug hashes in `TODO.md`, never adds AI attribution |
| Git hook: `commit-msg` | `.githooks/commit-msg` | Enforces Conventional Commit subjects (≤ 72 chars) and rejects `Co-Authored-By: Claude` / "Generated with Claude Code" |
| Hook: lint on edit | `.claude/hooks/lint-changed.sh` | yamllint + ansible-lint on every YAML file the agent writes; errors go back to the agent |
| Permissions | `.claude/settings.json` | Read-only checks allowed; VM deletion, commits, pushes, sudo need approval; `.secrets/` unreadable |

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
