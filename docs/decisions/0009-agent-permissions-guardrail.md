# 0009: Agent permissions are a guardrail, not a security boundary

Status: Accepted · Date: 2026-11-17

## Context
Claude Code works in this repo next to real secret material: the internal CA key (`.secrets/`), admin and operator
kubeconfigs (`out/`), and etcd snapshots that contain every Kubernetes Secret (`backups/`). `.claude/settings.json`
uses allow / ask / deny rules so routine work needs no approval while secret reads don't happen silently.

Four review rounds (B-005, B-011, B-015/B-016, B-018/B-019) each closed the listed gaps and then found new ones:
other spellings, mixed case, a repeated `--kubeconfig`, shell metacharacters passed through `limactl shell` or
`make` variables. Permission rules match **command text**; a shell, kubectl, git or make can always be told to do
the same thing with different text. Enumerating bad text does not converge.

## Decision
Treat the permission rules as a **guardrail against accidents**, not as a boundary against a determined adversary,
and build them in layers that fail safe:

1. **Instructions**: the Secrets rule in `CLAUDE.md` (never read secret material; use `kubectl describe secret`).
   This is what actually applies.
2. **Allow-list, not block-list**: auto-approve only fixed, known-safe command shapes (listed `kubectl get <kind>`,
   exact `make` commands with no `:*` wildcard (`make verify`, `make provision TAGS=<role>`, `make verify REQ=<id> STRICT=1`),
   `make ping`, read-only node commands). Anything else falls through to a prompt.
   Exception (user's choice, 2026-11-18): `limactl:*`, `git:*` and `gh:*` are allowed broadly to cut prompts, with ask
   rules for their destructive and outward-facing subcommands. This lets agents run most commands as root in the VM
   (`limactl shell k8s -- sudo …`) unprompted; the VM is rebuildable and holds no secret the host lacks.
3. **Ask** for secret-adjacent patterns (Secrets, `--raw`, identity flags, remote shell metacharacters, node PKI,
   the CA-key directory). A human sees the command.
4. **Deny** only for printing the secret files themselves (CA key, kubeconfigs, snapshots, node keys, `config view --raw`).
5. **Validate inputs where commands are built**: the Makefile rejects shell characters in user-settable variables and
   marks internal variables `override` (B-019), accepts only whitelisted command-line variables, and runs destructive
   targets only as the sole goal (B-020). make expands `VAR:=$(shell …)`, `--eval` and `-f` before the Makefile is read,
   so this layer can't stop those; that is why layer 2 pre-approves exact commands only. Allowed targets still run repo
   code (`scripts/verify.sh`, roles, `.venv`), so edits to that code are part of what a human reviews.

The real boundary for a hostile process would be OS-level: secrets not readable by the user the agent runs as
(e.g. a separate account, a sandbox, or a secrets manager). That is out of scope for a local, single-user assignment
and is recorded here as accepted residual risk.

## Consequences
- Reviewers rate findings in the permission rules by **how an agent could hit them in normal work**:
  - **Medium or higher**: an *auto-allowed* command shape that prints secret material when used the normal way, a deny
    that blocks necessary work, or a pre-approved command (e.g. a `make` target) that can run arbitrary commands.
  - **Low**: a bypass that needs a deliberately adversarial construction (repeated or reordered flags, encoded
    payloads, unusual quoting), or a prompt that could be avoided. Report it; don't log it as a bug.
- Some routine commands prompt (short kind names, `get -n x pods` with the kind after a flag). Accepted: put the kind
  right after `get`, or approve the prompt.
- Rules must be kept in sync with new tools the agents use; the permission simulator cases in each bug's details
  entry (`TODO.md`) show what was tested.
