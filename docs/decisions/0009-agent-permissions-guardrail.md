# 0009 — Agent permissions are a guardrail, not a security boundary

Status: Accepted · Date: 2026-11-17

## Context
Claude Code works in this repo next to real secrets: the CA key (`.secrets/`), kubeconfigs (`out/`), and etcd
snapshots that hold every Kubernetes Secret (`backups/`). `.claude/settings.json` has allow, ask and deny rules,
so routine work needs no approval but reading a secret never happens silently.

Four review rounds (B-005, B-011, B-015, B-016, B-018, B-019) each closed the gaps found and then found new ones:
other spellings, mixed case, a repeated `--kubeconfig`, shell characters passed through `limactl shell` or `make`.
The rules match **command text**, and there is always another way to write the same command. A block-list never ends.

## Decision
Treat the rules as a **guardrail against accidents**, not as protection against a determined attacker.
Build them in layers that fail safe:

1. **Instructions**: `CLAUDE.md` says never read secrets; use `kubectl describe secret` to check one exists.
   This is the layer that really applies.
2. **Allow-list**: auto-approve only fixed, known-safe commands: listed `kubectl get <kind>`, exact `make` commands
   with no wildcard (`make verify`, `make provision TAGS=<role>`, `make verify REQ=<id> STRICT=1`), `make ping`,
   read-only node commands. Everything else asks.
   Exception (user's choice, 2026-11-18): `limactl`, `git` and `gh` are allowed broadly to cut prompts. Their
   destructive and outward subcommands still ask. So agents can run most root commands in the VM without asking;
   the VM can be rebuilt and holds no secret the Mac lacks.
3. **Ask** for anything near a secret: Secrets, `--raw`, identity flags, shell characters on a remote shell line,
   node PKI, the CA-key folder. A human sees the command.
4. **Deny** only printing the secret files themselves: CA key, kubeconfigs, snapshots, node keys, `config view --raw`.
5. **Check inputs where commands are built**: the Makefile rejects shell characters in variables you can set, marks
   internal ones `override` (B-019), accepts only listed variables, and runs a destructive target only alone (B-020).
   make expands `$(shell …)`, `--eval` and `-f` before reading the Makefile, so this layer can't stop those. That is
   why layer 2 approves exact commands only. Allowed targets still run repo code (`scripts/verify.sh`, roles), so
   changes to that code need human review.

A real boundary would be at the OS level: secrets the agent's user can't read (another account, a sandbox, or a
secrets manager). That is out of scope for a local, single-user project; it is an accepted risk.

## Consequences
- Reviewers rate a permission finding by how an agent could hit it in normal work:
  - **Medium or higher**: an auto-allowed command that prints a secret when used normally; a deny that blocks needed
    work; or a pre-approved command (like a `make` target) that can run anything.
  - **Low**: a bypass that needs a deliberately tricky command (repeated or reordered flags, encoding, odd quoting),
    or a prompt that could be avoided. Report it, don't log a bug.
- Some routine commands ask (short kind names, a flag before the kind in `kubectl get`). Accepted: put the kind right
  after `get`, or approve the prompt.
- New tools the agents use need new rules. Each bug's entry in `TODO.md` lists the cases that were tested.
