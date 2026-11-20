# Cost settings

Goal: use the expensive models and deep reasoning only where judgment matters.
The source of truth is the frontmatter in `.claude/agents/*.md` and `.claude/skills/*/SKILL.md`; keep this page in sync.

## Agents

| Agent | Model | Effort | Why |
|---|---|---|---|
| `ansible-engineer` | sonnet | high | Writes the code. Lint, idempotency, strict verify and Opus reviews catch its mistakes. The caller may pass `model: opus` for a hard role |
| `k8s-verifier` | haiku | low | Runs `verify.sh` and collects evidence; no judgment needed |
| `docs-writer` | sonnet | low | Copies facts from the code into the docs |
| `sre-reviewer` | opus | high | Judgment: finds what the checks miss |
| `security-reviewer` | opus | high | Security; fixed so it does not depend on the session model |

## Skills

Skills set no model; they run in the main session.

| Skill | Effort |
|---|---|
| `provision`, `vm-lifecycle`, `verify-requirement`, `bug`, `new-role` | low |
| `pin-version`, `split-commits` | medium |
| `milestone`, `review-loop`, `fix-next-bug` | session default (they orchestrate) |

## Review scope

Reviewers look at the diff since the last SRE review (hash in `TODO.md`) plus uncommitted changes, and the code
around it. They apply only the checklist items the diff touches. A whole-repo review runs only at M10, or when asked
with `full`. The extra lenient `make verify` run in SRE testing was dropped; the strict run stays.

## Less context per session

- Turned off for this project in `.claude/settings.json`: the `engineering@inline` plugin (10 generic skills and
  8 MCP servers that overlap the project agents), and the user-level `mastic-reviewer` agent (another project).
- `attribution` is empty, so the harness doesn't add AI trailers that the `commit-msg` hook would reject.
- Agents don't re-read `CLAUDE.md` (it is already loaded) and read only the parts of `TODO.md` and `bugs.md` they need.
- The bug format lives only in the `bug` skill. Agent and skill descriptions are short (they load every session).
  Every agent report has a line limit.

**Kept on purpose:** each agent's short `tools:` list (reviewers need Edit only for `bugs.md` and `TODO.md`); no project MCP servers
or language servers (`make lint` covers Ansible YAML); the YAML lint hook (silent when clean); max 2 review rounds.

## Trade-offs

- Haiku may collect thinner evidence; the strict verify still decides PASS or FAIL.
- Sonnet writes the first draft; Opus reviewers and the checks catch defects.
- Reviewing only the diff can miss an old bug elsewhere; M10 runs a `full` review.
- Plugin settings are per project; the plugin still works in other projects.
