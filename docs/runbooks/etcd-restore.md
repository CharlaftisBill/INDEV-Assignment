# Restore etcd from a snapshot

Design: [ADR 0006](../decisions/0006-etcd-backups-outside-cluster.md).

Snapshots are `etcd-snapshot-<UTC>.db` files in `./backups` on the Mac (`/mnt/host-backups` in the VM).
They contain every Secret: never open, print or share them.

Tested 2026-11-20 on the same VM and on a rebuilt VM. These steps follow kubeadm's layout: etcd runs as a static pod from
`/etc/kubernetes/manifests/etcd.yaml` and keeps its data in `/var/lib/etcd`.

## Check the backups

```bash
ls -l backups/                                                  # on the Mac
limactl shell k8s systemctl list-timers etcd-backup.timer       # when the next one runs
limactl shell k8s sudo systemctl start etcd-backup.service      # take one now
limactl shell k8s journalctl -u etcd-backup.service -n 20 --no-pager
```

Alert `EtcdBackupStale` means no good snapshot for over an hour. Read the journal, and check that
`findmnt /mnt/host-backups` shows `virtiofs` (vz) or `9p` (QEMU).

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
   sudo crictl ps -q --name 'etcd|kube-apiserver'   # repeat until the output is empty
   ```
3. Keep the old data and restore into a fresh folder. Pass the member flags from the moved manifest;
   without them the member comes back with peer URL `http://localhost:2380`:
   ```bash
   sudo mv /var/lib/etcd /var/lib/etcd.old
   E=/root/manifests-off/etcd.yaml
   NAME="$(sudo sed -n 's/^ *- --name=//p' "$E")"; PEER="$(sudo sed -n 's/^ *- --initial-advertise-peer-urls=//p' "$E")"; CLUSTER="$(sudo sed -n 's/^ *- --initial-cluster=//p' "$E")"
   sudo etcdutl snapshot restore "$SNAP" --data-dir /var/lib/etcd --name "$NAME" --initial-cluster "$CLUSTER" --initial-advertise-peer-urls "$PEER"
   ```
   Expected: member `k8s-node`, peer `https://192.168.5.15:2380`.
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
   On a rebuilt VM, do the [extra steps](#restore-on-a-rebuilt-vm) first; until then this check can fail.

Objects made after the snapshot are gone, and workloads go back to the snapshot's state.
In the drill, the control plane stopped about 32 s after the manifests moved, and the API was back about 48 s after
they returned.
When all is well, delete the old data: `sudo rm -rf /var/lib/etcd.old`.

## Restore on a rebuilt VM

`make vm-reset` keeps `./backups` and `.secrets/` (so the CA stays the same). Then:

```bash
make vm-up
make provision     # new cluster with a new etcd; takes a first snapshot
```

Now run the same-VM steps above with the old snapshot. Node name and IP are fixed in `group_vars`, so they match.
Tested 2026-11-20: the API was back 5 s after the manifests returned, and objects made after the snapshot were gone.
Then do these extra steps, in this order.

The rebuilt VM has a new kubeadm CA and ServiceAccount key (only the ingress CA is kept across rebuilds). Keeping
both across rebuilds would avoid steps 2 and 3. That is not done.

1. **Fix local-path volume permissions.** Restored PVs point at old `pvc-<uid>` folders. Kubelet recreates them as
   root `0755`, so non-root Prometheus crashloops with "permission denied" and the model cannot be fetched.
   Their data is gone (it was on the old disk): Prometheus starts with empty history, and the model is fetched in step 4.
   ```bash
   kubectl --kubeconfig out/admin.conf get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="local-path")]}{.spec.hostPath.path}{"\n"}{end}'
   limactl shell k8s sudo find <path> -type d -exec chmod 0777 {} +   # each path, subPath dirs too; 0777 is what local-path-provisioner sets
   ```
2. **Restart all pods.** Running pods keep the old CA. kube-proxy then fails with
   "x509: certificate signed by unknown authority", so Service IPs are not programmed (cert-manager webhook and
   Calico API time out).
   ```bash
   kubectl --kubeconfig out/admin.conf delete pods --all -A --wait=false
   kubectl --kubeconfig out/admin.conf get pods -A     # wait until all are Ready (about 30 s)
   ```
3. **Reissue legacy token Secrets.** Their tokens are signed by the old key, so Prometheus scrapes get 401.
   Today only `monitoring/kps-prometheus-token` exists.
   ```bash
   kubectl --kubeconfig out/admin.conf get secrets -A --field-selector type=kubernetes.io/service-account-token -o name
   kubectl --kubeconfig out/admin.conf patch secret <name> -n <ns> --type=json -p '[{"op":"remove","path":"/data/token"}]'
   ```
   kube-controller-manager then issues a new token.
   **Warning:** never `describe` or `get -o yaml` these Secrets. `describe` prints the token in clear text (B-051).
4. **Re-apply and verify.** `make provision` fetches the model again (`llm_app` changed=4). Then:
   ```bash
   make verify STRICT=1     # all 12 IDs PASS in the drill
   ```
5. Optional: the new cluster's own PV folders are now unused. They are the folders under
   `/opt/local-path-provisioner` that the `get pv` command in step 1 does **not** list. Delete only those.

## Notes

- A restored etcd gets a new member ID and cluster ID. That is fine on one node.
- Only the newest 48 snapshots are kept. To keep one longer, copy it out of `backups/`.
