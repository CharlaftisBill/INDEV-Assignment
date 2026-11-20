# 0006 — etcd snapshots stored on the Mac

Status: Accepted · Date: 2026-11-17

## Context
Requirement 7: scheduled etcd snapshots, stored outside the cluster. With one node, anything on the VM disk is
lost with the VM.

## Decision
Role `etcd_backup` installs a **systemd timer on the node**, not a Kubernetes CronJob. So backups still run when
the API server or scheduler is broken. Snapshots go to `/mnt/host-backups`, which is `./backups` on the Mac
(Lima virtiofs mount).

## Details
- Runs every 30 minutes (`etcd_backup_schedule`). `Persistent=true` catches up missed runs after a reboot.
- The unit needs the mount (`RequiresMountsFor`). The role checks it is a virtiofs or 9p mount, and the script refuses to
  write anywhere else. Snapshots must never land on the VM disk (B-010). `check_7` compares Mac and node listings.
- `etcdctl snapshot save` with kubeadm's `healthcheck-client` certificate, then `etcdutl snapshot status` to check
  it. Written under a temp name and renamed, so a half-written file never has the final name.
- Keeps the newest 48 snapshots. Files are mode 0600 and, through virtiofs, owned by the Mac user.
- The script is `/usr/local/sbin/etcd-backup`, run as root. The role takes one snapshot when none exists yet.
- etcdctl and etcdutl v3.6.6, the same version as kubeadm's etcd.
- Writes metrics (last success, size, count) for node-exporter's textfile collector. Alert `EtcdBackupStale` fires
  when the last success is older than an hour (2× the schedule) or the metric is missing, for 5 minutes.
- **Cross-role**: node-exporter had no textfile collector, so the `monitoring` role got one extra argument that reuses
  its existing read-only host mount. Nothing else in its security settings changed.
- Ansible's mount facts skip virtiofs, so the mount check uses `findmnt`. Accepted types are
  `etcd_backup_mount_fstypes: [virtiofs, 9p]` (vz on macOS, QEMU on Linux). Any other type, such as ext4, is refused.

## Alternatives
| Option | Why not |
|---|---|
| CronJob with hostPath | Needs a healthy cluster; still on the VM disk without the mount |
| MinIO or S3 on the Mac | Closer to production, but one more service for no extra safety here |

## Consequences
- Snapshots survive `make vm-reset`. Restore: [runbook](../runbooks/etcd-restore.md).
- Snapshots contain every Secret in plain form. `./backups` is gitignored; treat it as secret.
- Accepted Low risks: binaries owned by uid 1000; a killed run can leave a temp file (cleaned after 60 minutes);
  `KEEP` is not validated; the stale threshold is fixed, not derived from the schedule; retention by count only
  (48 snapshots, about 1.8 GB on the Mac).
