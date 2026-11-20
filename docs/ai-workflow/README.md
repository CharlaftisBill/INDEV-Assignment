# How this was built with Claude Code

The assignment asks for agent-driven development. This folder explains the setup.

- This page: the agents, skills and hooks, and why the work is split this way.
- [Git workflow](git-workflow.md): branches, PRs, the review gate.
- [Cost settings](cost.md): which model and effort each agent uses.
- [Log](log.md): what happened in each milestone.
- [Bugs](bugs.md): every bug found and fixed, by milestone.

Project state (milestones, backlog) is in [TODO.md](../../TODO.md).

## Rules and state

| File | Purpose |
|---|---|
| [`CLAUDE.md`](../../CLAUDE.md) | The agent's rulebook: requirements, environment, hard rules (pinning, idempotency, Pod Security), definition of done, known pitfalls |
| [`TODO.md`](../../TODO.md) | Milestones and backlog. Read first, updated last |
| `.claude/settings.json` | Which commands run without asking. See [ADR 0009](../decisions/0009-agent-permissions-guardrail.md) |

## Agents (`.claude/agents/`)

| Agent | Does | May change |
|---|---|---|
| `ansible-engineer` | Builds or fixes one role; runs lint, provision, idempotency | code |
| `k8s-verifier` | Checks the live cluster; opens bugs | [`bugs.md`](bugs.md) only |
| `sre-reviewer` | Reviews the diff and tests the system (lint, idempotency, verify, smoke, targeted and, when allowed, disruptive tests); logs Critical/High/Medium findings as `[sre]` bugs | [`bugs.md`](bugs.md) only |
| `security-reviewer` | Reviews RBAC, Pod Security, NetworkPolicy, audit, TLS, secrets; logs `[sec]` bugs | [`bugs.md`](bugs.md) only |
| `docs-writer` | Keeps README and `docs/` in line with the code | docs only |

## Skills (`.claude/skills/`)

| Skill | Does |
|---|---|
| `milestone` | Runs a milestone: build → provision → verify → review → document → close |
| `review-loop` | Reviewers find bugs → `fix-next-bug` fixes each → reviewers check the fixes. Stops when a round finds nothing new, or after 2 rounds |
| `fix-next-bug` | Takes the next Open bug of the current or an earlier milestone (`[sec]` first, then by severity, oldest first): reproduce → root cause → fix → verify → Solved |
| `split-commits` | Groups changes into small Conventional Commits; fills bug hashes in [`bugs.md`](bugs.md); never adds AI attribution |
| `vm-lifecycle`, `provision`, `verify-requirement`, `pin-version`, `new-role`, `bug` | Fixed procedures the agents follow |

## Hooks

| Hook | Does |
|---|---|
| `.githooks/commit-msg` | Requires Conventional Commit subjects (≤ 72 chars); rejects `Co-Authored-By: Claude` and "Generated with Claude Code" |
| `.githooks/pre-commit` | Rejects commits on `main` or a detached HEAD |
| `.claude/hooks/lint-changed.sh` | Runs yamllint and ansible-lint on every YAML file the agent edits; errors go back to the agent |

## Permissions in short

- Allowed without asking: read-only checks, exact `make` commands, `kubectl get` for listed kinds, and most of
  `limactl`, `git` and `gh`.
- Asks first: VM delete, commit, merge, push, PRs, sudo, Secrets in any form, and commands near secrets
  (`--raw`, node keys, the CA-key folder).
- Always denied: reading the secret files themselves (CA key, kubeconfigs, etcd snapshots, node keys, `config view --raw`).

It is a best-effort guardrail, not a security boundary: [ADR 0009](../decisions/0009-agent-permissions-guardrail.md).

## Why split it this way

- **Separation of duties**: the agent that writes the code is not the one that says it works. Verifiers and
  reviewers can only open bugs; the engineer fixes them.
- **Small context**: each agent gets one role or one requirement, not the whole project.
- **Guardrails over trust**: pinning and idempotency are rules in `CLAUDE.md` *and* are checked
  (`make idempotency`, the `pin-version` skill). Destructive commands need a human yes.
