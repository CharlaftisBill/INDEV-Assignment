# 0006 — etcd snapshots stored on the host

Status: Accepted · Date: 2026-11-17

## Context
Requirement 7: scheduled etcd snapshots, stored outside the cluster. On a single node, anything on the VM disk is lost with the VM.

## Decision
Role `etcd_backup`. A systemd timer on the node (not a Kubernetes CronJob, so backups run when the API or scheduler is unhealthy):

- Every 30 min (`etcd_backup_schedule`), `Persistent=true`. The oneshot unit has `RequiresMountsFor=/mnt/host-backups`, the Lima virtiofs mount of `./backups` on the Mac.
- `etcdctl snapshot save` with kubeadm's `healthcheck-client` cert, checked with `etcdutl snapshot status`, written to a temp name and renamed (no partial file under the final name). Count-based pruning keeps 48.
- etcdctl/etcdutl v3.6.6 (same as kubeadm's etcd 3.6.6-0), sha256 pinned in `versions.yml`.
- Metrics through the node-exporter textfile collector; PrometheusRule `EtcdBackupStale` fires when the metric is absent or older than 3600 s for 5 min.
- B-010: snapshots must never land on the VM disk. The role asserts the directory is a virtiofs mountpoint, the unit requires the mount, and the script refuses to write otherwise. `check_7` compares host and node listings.

## Alternatives considered
- **CronJob with hostPath**: depends on a healthy cluster; still on the VM disk unless combined with the mount.
- **MinIO / S3 on the host**: closer to production, but adds a host service for no extra guarantee here.

## Consequences
- Snapshots survive `make vm-reset`; restore: [runbook](../runbooks/etcd-restore.md).
- Snapshots contain Secrets in plain form; `./backups` is gitignored and sensitive.
- Accepted Lows (not logged): unarchived binaries owned by uid 1000; a killed run can leave a `.part`/`.tmp` file (the script deletes leftovers older than 60 min, not the trap); `KEEP` not validated; stale threshold fixed, not derived from the schedule; retention by count only (48 snapshots, about 1.8 GB on the Mac).
