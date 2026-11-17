# 0006 — etcd snapshots stored on the host

Status: Proposed (accepted when implemented) · Date: 2026-11-17

## Context
Requirement 7: scheduled etcd snapshots, stored outside the cluster. On a single node, anything on the VM disk is lost with the VM.

## Decision
A systemd timer on the node (not a Kubernetes CronJob, so backups still run when the API or scheduler is unhealthy) runs `etcdctl snapshot save` with the etcd client certificates, verifies it with `etcdutl snapshot status`, and writes it to `/mnt/host-backups`, a writable Lima mount of `./backups` on the Mac. Old snapshots are pruned by count. The script writes the last-success timestamp to the node-exporter textfile collector, and a Prometheus alert fires if backups go stale.

## Alternatives considered
- **CronJob with hostPath**: depends on the cluster being healthy; still on the VM disk unless combined with the mount.
- **MinIO / S3 on the host**: closer to production, but adds a service to run on the host for no extra guarantee here.

## Consequences
- Snapshots survive `make vm-reset`; restore procedure in `docs/runbooks/etcd-restore.md`.
- Snapshots contain Secrets in plain form; `./backups` is gitignored and should be treated as sensitive.
