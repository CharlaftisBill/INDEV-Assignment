# Restore etcd from a snapshot

Design: [ADR 0006](../decisions/0006-etcd-backups-outside-cluster.md).

Snapshots are `etcd-snapshot-<UTC>.db` files in `./backups` on the Mac (`/mnt/host-backups` in the VM).
They contain every Secret: never open, print or share them.

The full restore test is planned for M10. These steps follow kubeadm's layout: etcd runs as a static pod from
`/etc/kubernetes/manifests/etcd.yaml` and keeps its data in `/var/lib/etcd`.

## Check the backups

```bash
ls -l backups/                                                  # on the Mac
limactl shell k8s systemctl list-timers etcd-backup.timer       # when the next one runs
limactl shell k8s sudo systemctl start etcd-backup.service      # take one now
limactl shell k8s journalctl -u etcd-backup.service -n 20 --no-pager
```

Alert `EtcdBackupStale` means no good snapshot for over an hour. Read the journal, and check that
`findmnt /mnt/host-backups` shows `virtiofs`.

## Restore on the same VM

1. Open a shell in the VM, pick a snapshot and check it:
   ```bash
   limactl shell k8s
   SNAP=/mnt/host-backups/etcd-snapshot-<UTC>.db
   sudo etcdutl snapshot status "$SNAP" --write-out=table
   ```
2. Stop etcd and the API server. kubelet stops a static pod when its file is moved away:
   ```bash
   sudo mkdir -p /root/manifests-off
   sudo mv /etc/kubernetes/manifests/*.yaml /root/manifests-off/
   sudo crictl ps | grep -E 'etcd|kube-apiserver' || echo stopped   # repeat until "stopped"
   ```
3. Keep the old data and restore into a fresh folder:
   ```bash
   sudo mv /var/lib/etcd /var/lib/etcd.old
   sudo etcdutl snapshot restore "$SNAP" --data-dir /var/lib/etcd
   ```
4. Start the control plane again:
   ```bash
   sudo mv /root/manifests-off/*.yaml /etc/kubernetes/manifests/
   ```
5. Check from the Mac:
   ```bash
   kubectl --kubeconfig out/admin.conf get nodes
   kubectl --kubeconfig out/admin.conf get pods -A
   make verify REQ=2 STRICT=1
   ```

Objects made after the snapshot are gone, and workloads go back to the snapshot's state.
When all is well, delete the old data: `sudo rm -rf /var/lib/etcd.old`.

## Restore on a rebuilt VM

`make vm-reset` keeps `./backups` and `.secrets/` (so the CA stays the same). Then:

```bash
make vm-up
make provision     # new cluster with a new etcd; takes a first snapshot
```

Now run the same-VM steps above with the old snapshot. Node name and IP are fixed in `group_vars`, so they match.

**Not tested yet** (planned for M10): the rebuilt node has new kubeadm certificates, so ServiceAccount tokens from
the old cluster may need to be issued again.

## Notes

- A restored etcd gets a new member ID and cluster ID. That is fine on one node.
- Only the newest 48 snapshots are kept. To keep one longer, copy it out of `backups/`.
