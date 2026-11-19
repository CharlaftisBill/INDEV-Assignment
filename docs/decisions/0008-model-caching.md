# 0008 — Model caching for llama.cpp

Status: Accepted · Date: 2026-11-17

## Context
Requirement 9: a pod restart must not download the model again. Application pods should have no egress (requirement 3).

## Decision
- The model (Qwen2.5-0.5B-Instruct Q4_K_M, HF commit + sha256 pinned in `versions.yml`) lives on a 2Gi PVC from the default StorageClass.
- Ansible decides whether to fetch by hashing the file on the node (`stat` sha256 of the PV hostPath). Absent or wrong hash runs a one-shot Job (label `component=model-fetch`). Ansible polls it to Complete/Failed (fail-fast), deletes it, and restarts the server pods.
- Only the Job label gets egress: DNS + TCP 443 to public IPs (RFC1918, 169.254/16, 100.64/10 excluded). The server has no egress at all.
- The server mounts the PVC read-only; an init container `verify-model` checks the sha256 and fails closed (`Init:Error`).
- Recovery from a lost or corrupt model, or a failed fetch: re-run `make provision TAGS=llm_app` ([troubleshooting](../runbooks/troubleshooting.md#model-missing-or-corrupt-llm-pod-pending-or-init-error)).

## Alternatives considered
- **initContainer download**: needs egress on the serving pod; runs on every pod start (even if it skips the download).
- **Bake the model into an image**: needs a registry and a build step; image pulls are not the point of the exercise.
- **hostPath cache**: violates PSA `restricted`.
- **Annotation or marker as the fetch gate** (first version, B-045): can say "fetched" while the file is gone or corrupt. The file hash cannot.
- **Egress for the whole pod** (first version, B-044): the serving pod would keep outbound access forever.

## Consequences
- Restarting or deleting the pod reuses the PVC; no Job runs. Verified in `check_9`.
- `make vm-reset` deletes the PVC, so the model is downloaded once per fresh VM.
- Egress exists only while a fetch Job runs.
- Accepted Lows: anyone who can create pods in `llm` could copy the Job label to gain egress (admins and controllers only today); the pod delete after a re-fetch does not wait (theoretical rollout race); a failed Job and its logs are removed after 1h.
