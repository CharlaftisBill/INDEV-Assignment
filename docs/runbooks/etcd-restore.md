# Restore etcd from a snapshot

Design: [ADR 0006](../decisions/0006-etcd-backups-outside-cluster.md).

Snapshots are `etcd-snapshot-<UTC>.db` files in `./backups` on the Mac (`/mnt/host-backups` in the VM).
With your own VM (`external-vm.conf`) they are in `/var/backups/etcd` on the VM (the host pulls them into
`./backups/external`): use `make vm-shell` instead of `limactl shell k8s`, and that folder instead of `/mnt/host-backups`.
They contain every Secret: never open, print or share them.

Tested on the same VM (2026-11-20) and on a rebuilt VM with kept PKI (2026-11-21). Same VM again on 2026-11-21
with the bump flags: watchers re-listed within about 10 s (B-054). These steps follow kubeadm's
layout: etcd runs as a static pod from
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
   sudo etcdutl snapshot restore "$SNAP" --data-dir /var/lib/etcd --name "$NAME" --initial-cluster "$CLUSTER" --initial-advertise-peer-urls "$PEER" --bump-revision 1000000000 --mark-compacted
   ```
   Expected: member `k8s-node`, peer `https://192.168.5.15:2380`.
   The bump flags are needed because revisions must move forward past anything clients have seen, and marking them
   compacted makes every watcher (kube-proxy, CoreDNS, Calico, cert-manager) re-list. Without them, watchers keep a
   stale watch and miss deletions: kube-proxy kept rules for a deleted Service for over 5 min (B-054).
4. Start the control plane again, then restart kubelet once the API answers. The restart makes kubelet re-sync pods
   at once, so it stops pods the snapshot does not have (B-053):
   ```bash
   sudo mv /root/manifests-off/*.yaml /etc/kubernetes/manifests/
   for i in $(seq 60); do sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /readyz >/dev/null 2>&1 && break; sleep 2; done
   sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /readyz && sudo systemctl restart kubelet   # no "ok": check etcd first
   ```
5. Check from the Mac:
   ```bash
   kubectl --kubeconfig out/admin.conf get nodes
   kubectl --kubeconfig out/admin.conf get pods -A
   make verify REQ=2 STRICT=1
   ```
   Wait 15 min before `make verify REQ=4`: Traefik may log one "forbidden" while the API server loads RBAC (B-054).
   On a rebuilt VM, do the [extra steps](#restore-on-a-rebuilt-vm) first; until then this check can fail.

Objects made after the snapshot are gone, and workloads go back to the snapshot's state.
In the drill, the control plane stopped about 32 s after the manifests moved, and the API was back about 48 s after
they returned.
When all is well, delete the old data: `sudo rm -rf /var/lib/etcd.old`.

## Restore on a rebuilt VM

`make vm-reset` keeps `./backups` and `.secrets/`. So the rebuilt VM gets the same ingress CA and the same kubeadm
CAs and ServiceAccount keys (`.secrets/kubeadm-pki/`, [ADR 0006](../decisions/0006-etcd-backups-outside-cluster.md#restore-on-a-rebuilt-vm)).
Running pods and legacy token Secrets in the snapshot stay valid, so you do not delete all pods by hand or reissue
tokens. Kubelet still recreates the snapshot's pods itself. Then:

```bash
make vm-up
make provision     # new cluster with a new etcd; takes a first snapshot
```

Now run the same-VM steps above with the old snapshot. Node name and IP are fixed in `group_vars`, so they match.
Tested 2026-11-21 (snapshot from the VM of the first `make e2e`, restored after a second one; same CA fingerprint):
the API was back 2 s after the manifests returned with the old cluster's objects, kubelet ran the snapshot's pods 3 s
after its restart, no x509 or token errors, and the legacy token Secret worked unchanged.
Then do these extra steps, in this order.

1. **Fix local-path volume permissions.** Restored PVs point at old `pvc-<uid>` folders. Kubelet recreates them as
   root `0755`, so non-root Prometheus crashloops with "permission denied" and the model cannot be fetched.
   Their data is gone (it was on the old disk): Prometheus starts with empty history, and the model is fetched in step 2.
   ```bash
   kubectl --kubeconfig out/admin.conf get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="local-path")]}{.spec.hostPath.path}{"\n"}{end}'
   limactl shell k8s sudo find <path> -type d -exec chmod 0777 {} +   # each path, subPath dirs too; 0777 is what local-path-provisioner sets
   ```
2. **Re-apply and verify.** `make provision` fetches the model again (`llm_app` changed). Then:
   ```bash
   make verify STRICT=1     # all 12 IDs PASS in the drill
   ```
3. Optional: the new cluster's own PV folders are now unused. They are the folders under
   `/opt/local-path-provisioner` that the `get pv` command in step 1 does **not** list. Delete only those.

**If `.secrets/kubeadm-pki/` was lost** (or the snapshot predates it), the VM has new CAs. Before step 2, also restart
all pods (`kubectl --kubeconfig out/admin.conf delete pods --all -A --wait=false`; running pods keep the old CA and
kube-proxy fails with x509) and remove `data.token` from each legacy token Secret so kube-controller-manager issues a
new one (`--field-selector type=kubernetes.io/service-account-token -o name` lists them; `patch secret <name> -n <ns>
--type=json -p '[{"op":"remove","path":"/data/token"}]'`). Never `describe` or `get -o yaml` these Secrets (B-051).

## Notes

- A restored etcd gets a new member ID and cluster ID. That is fine on one node.
- Only the newest 48 snapshots are kept. To keep one longer, copy it out of `backups/`.
