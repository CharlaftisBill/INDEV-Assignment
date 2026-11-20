# 0004 — local-path-provisioner as default StorageClass

Status: Accepted · Date: 2026-11-17

## Context
Requirement 5 needs a default StorageClass. There is one node and no external storage.

## Decision
Rancher local-path-provisioner. StorageClass `local-path` is the default. Volumes are folders under
`/opt/local-path-provisioner` on the VM disk. `volumeBindingMode: WaitForFirstConsumer`, `reclaimPolicy: Delete`.

## Details
- **Install**: the `storage` role uses its own templates, copied from upstream `deploy/local-path-storage.yaml`
  (there is no Helm repo). Upstream's `--debug` flag is dropped.
- **Pins**: provisioner and busybox (helper pod, `check_5` test pod) by tag and digest.
- **Provisioner**: user 65534, no privilege escalation, no capabilities, `RuntimeDefault` seccomp, read-only root,
  resource requests.
- **Namespace** `local-path-storage` is `privileged`, because helper pods mount host folders.
- **Helper pod** (creates and deletes volume folders): root, read-only root, `RuntimeDefault`, no privilege
  escalation, drops every default capability except `DAC_OVERRIDE`.
  - It drops capabilities instead of adding them: v0.0.37 rejects `capabilities.add` unless an unsafe flag is on.
    The first version used `add` and crash-looped (B-032).
  - It keeps `DAC_OVERRIDE` because deleting files owned by other users fails without it (tested in review;
    `FOWNER` did not help).
- **Checks**: the role waits for the rollout (B-033) and asserts exactly one default class.

## Alternatives
| Option | Why not |
|---|---|
| OpenEBS LocalPV, Longhorn | Replication and snapshots add nothing on one node and cost RAM |
| Static hostPath volumes | No dynamic provisioning |

## Consequences
- Simple and light. Data lives on the VM disk, not on the Mac.
- The model cache ([ADR 0008](0008-model-caching.md)) survives pod restarts but not `make vm-reset`.
- local-path does not enforce volume sizes, so Prometheus sets its own size limit.
- Deleting a volume claim deletes its data.
- Helper pods keep root and `DAC_OVERRIDE`, but only in a platform namespace. App namespaces stay `restricted`.
