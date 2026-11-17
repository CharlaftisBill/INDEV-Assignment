# 0008 — Model caching for llama.cpp

Status: Proposed (accepted when implemented) · Date: 2026-11-17

## Context
Requirement 9: a pod restart must not download the model again. Application pods should have no egress (requirement 3).

## Decision
- The model (Qwen2.5-0.5B-Instruct, GGUF Q4, pinned URL + sha256) lives on a PVC from the default StorageClass.
- A separate one-shot Job downloads it only if the file is missing or its checksum does not match. Only this Job's pods get egress (DNS + 443).
- The llama.cpp Deployment mounts the PVC read-only, runs as non-root, has no egress, and only starts serving once the file is present.

## Alternatives considered
- **initContainer download**: would need egress on the serving pod; runs on every pod start (even if it skips the download).
- **Bake the model into an image**: needs a registry and a build step; image pulls are not the point of the exercise.
- **hostPath cache**: violates PSA `restricted`.

## Consequences
- Restarting or deleting the pod reuses the PVC; the Job is not rerun. Verified in `check_9`.
- `make vm-reset` deletes the PVC, so the model is downloaded once per fresh VM.
