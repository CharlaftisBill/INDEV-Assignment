# 0004 — local-path-provisioner as default StorageClass

Status: Accepted · Date: 2026-11-17

## Context
Requirement 5 needs a default StorageClass. There is one node and no external storage.

## Decision
Rancher local-path-provisioner v0.0.37, StorageClass `local-path` annotated `storageclass.kubernetes.io/is-default-class: "true"`, `volumeBindingMode: WaitForFirstConsumer`, `reclaimPolicy: Delete`, data under `/opt/local-path-provisioner` on the VM disk.

- **Install**: role `storage` applies its own templates mirroring upstream `deploy/local-path-storage.yaml` (no published Helm repo). Upstream `--debug` is dropped.
- **Pins**: provisioner and busybox (helper pod, `check_5` test pod) by tag@digest in `versions.yml`.
- **Provisioner hardening**: uid 65534, no privilege escalation, drop ALL, `RuntimeDefault` seccomp, read-only root FS, resource requests.
- **Namespace** `local-path-storage`: PSA enforce/audit/warn `privileged`, because helper pods mount hostPath.
- **Helper pod**: runs as root with read-only root FS, `RuntimeDefault`, no privilege escalation, drops every default capability except `DAC_OVERRIDE`. v0.0.37 rejects `capabilities.add` unless `--allow-unsafe-helper-pod-template`; that flag stays off (the first draft used `add` and crash-looped the provisioner, B-032).
- **Why `DAC_OVERRIDE`**: SRE review test showed teardown deletes files owned by non-root users; with all capabilities dropped it fails even on default-umask files, and `FOWNER` does not help.
- **Checks**: the role waits for rollout completion (B-033) and asserts exactly one default class (GA and beta annotations). `check_5` in `scripts/verify.sh`.

## Alternatives considered
- **OpenEBS LocalPV / Longhorn**: replication and snapshots add nothing on a single node and cost RAM.
- **Static hostPath PVs**: no dynamic provisioning.

## Consequences
- Simple and light. Data lives and dies with the VM disk; the model cache (0008) survives pod restarts but not `make vm-reset`. PVs are not on the Mac mount.
- Helper pods keep root and `DAC_OVERRIDE` in a `privileged` platform namespace; app namespaces stay `restricted`.
- local-path does not enforce PVC size: M6 must set Prometheus `retentionSize` itself.
- `reclaimPolicy: Delete`: deleting a PVC deletes its data.
