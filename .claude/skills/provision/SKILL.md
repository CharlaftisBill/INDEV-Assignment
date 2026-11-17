---
name: provision
description: Run the Ansible playbook against the Lima VM (all roles or selected tags), then prove idempotency with a second run that must report changed=0, and summarize failures. Use after changing any role, or when the user asks to "apply", "provision", "run ansible" or "rerun the playbook".
---

# Provision + idempotency

1. Pre-checks
   - `make check` (syntax) and `make lint`. Fix lint errors first.
   - VM running (`limactl list`), collections installed (`ls ansible/collections/ansible_collections` — else `make collections`).
2. Apply
   - One role: `make provision TAGS=<role>`; several: `TAGS=a,b`; everything: `make provision`.
   - Extra flags through `ANSIBLE_ARGS`, e.g. `ANSIBLE_ARGS="--diff"`, `ANSIBLE_ARGS="-vv"`, `ANSIBLE_ARGS="--check --diff"`.
   - Long runs (helm installs, model download) can exceed 2 minutes: run them in the background and wait for completion.
3. Idempotency
   - `make idempotency TAGS=<same tags>` must end in `changed=0 unreachable=0 failed=0`.
   - If something reports `changed` on the second run, find the task (look for `changed:` lines) and fix it:
     missing `creates:`/`changed_when:`, templating that renders non-deterministically, `helm` values drift,
     `k8s` objects with server-defaulted fields in the manifest.
4. Report
   - Failed task name, host, the error message (trimmed), and the likely cause.
   - Recap line of both runs. Wall time if it is a slow role.
   - If the failure is a real defect (not a typo you fix right away), record it with the `bug` skill.
