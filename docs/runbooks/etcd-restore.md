# Restore etcd from a snapshot

Design: [ADR 0006](../decisions/0006-etcd-backups-outside-cluster.md). Snapshots are `etcd-snapshot-<UTC>.db` in `./backups` on the Mac (`/mnt/host-backups` in the VM). They contain every Secret: do not open, print or share them. The restore drill is deferred to M10; the steps below follow the kubeadm layout (static pod `/etc/kubernetes/manifests/etcd.yaml`, data `/var/lib/etcd`).

## Check backups

```bash
ls -l backups/                                   # on the Mac
limactl shell k8s systemctl list-timers etcd-backup.timer
limactl shell k8s sudo systemctl start etcd-backup.service   # take one now
limactl shell k8s journalctl -u etcd-backup.service -n 20 --no-pager
```

Alert `EtcdBackupStale` in Alertmanager means no verified snapshot for over an hour: check the journal and that `findmnt /mnt/host-backups` shows `virtiofs`.

## Restore on the same VM

```bash
limactl shell k8s
SNAP=/mnt/host-backups/etcd-snapshot-<UTC>.db      # pick one
sudo etcdutl snapshot status "$SNAP" --write-out=table   # integrity + revision

# Stop etcd and the apiserver: kubelet stops static pods whose manifest is gone
sudo mkdir -p /root/manifests-off
sudo mv /etc/kubernetes/manifests/*.yaml /root/manifests-off/
sudo crictl ps | grep -E 'etcd|kube-apiserver' || echo stopped   # repeat until stopped

# Keep the old data, restore into a fresh directory
sudo mv /var/lib/etcd /var/lib/etcd.old
sudo etcdutl snapshot restore "$SNAP" --data-dir /var/lib/etcd

# Start the control plane again
sudo mv /root/manifests-off/*.yaml /etc/kubernetes/manifests/
```

Verify from the Mac:

```bash
kubectl --kubeconfig out/admin.conf get nodes
kubectl --kubeconfig out/admin.conf get pods -A
make verify REQ=2 STRICT=1
```

Objects created after the snapshot are gone; workloads are reconciled to the snapshot state. When satisfied, `sudo rm -rf /var/lib/etcd.old`.

## Restore on a rebuilt VM

`make vm-reset` keeps `./backups` and `.secrets/` (same CA). Then:

```bash
make vm-up
make provision                      # new cluster, new etcd; takes a first snapshot
```

Run the same-VM steps above with the old snapshot. Node name and IP are fixed by `group_vars`, so they match. **Untested** (restore drill is M10): the rebuilt node has fresh kubeadm PKI, so ServiceAccount tokens from the old cluster may need re-issuing.

## Notes

- A restored etcd gets a new member ID and cluster ID: fine on a single node.
- Snapshots are pruned to the newest 48; copy one out of `backups/` to keep it.
