# 0004 — local-path-provisioner as default StorageClass

Status: Proposed (accepted when implemented) · Date: 2026-11-17

## Context
Requirement 5 needs a default StorageClass. There is one node and no external storage.

## Decision
Rancher local-path-provisioner (pinned), StorageClass `local-path` annotated `storageclass.kubernetes.io/is-default-class: "true"`, `volumeBindingMode: WaitForFirstConsumer`, data under `/opt/local-path-provisioner` on the VM disk.

## Alternatives considered
- **OpenEBS LocalPV / Longhorn**: replication and snapshots add nothing on a single node and cost RAM.
- **Static hostPath PVs**: no dynamic provisioning.

## Consequences
- Simple and light. Data lives and dies with the VM disk; the model cache (0008) survives pod restarts but not `make vm-reset`.
