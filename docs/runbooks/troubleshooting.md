# Troubleshooting

## Own VM: make vm-up or the tunnel fails

With `external-vm.conf`, `make vm-up` prints the first thing that is wrong (SSH, sudo, Debian 13, size, address).
Fix it on the VM ([what it needs](../install.md#the-vm)) and run it again.

- `could not open the SSH tunnel` / `could not listen on host 443/80`: another process holds port 443, 80, 6443,
  18443 or 18000. Usually the Lima VM: `limactl stop k8s`. Check with `lsof -nP -iTCP:443 -sTCP:LISTEN`.
- Linux: `Permission denied` on 443/80 means `net.ipv4.ip_unprivileged_port_start` is above 80: `make deps` sets it.
- `curl https://llm.local` hangs or is refused after the laptop slept: `make tunnel-stop`, then `make tunnel`.
- Back on Lima, `make doctor` says `own-VM tunnel ... IN USE`: a tunnel from `external-vm.conf` still holds 443/80/6443.
  `make tunnel-stop` (works without the conf) or `make vm-up` stops it.
- `make verify` check 7: `no scheduled pull` → `make tunnel` (starts the pull loop); `no host copy ... younger than
  3600s` → read `.cache/backups-pull.log` (VM unreachable over SSH?).
- `the VM cannot reach deb.debian.org` (end of `make vm-up`), or apt/image pulls fail in `make provision`: with
  `egress=host`, read `$TMPDIR/indev-k8s-ext-<uid>.egress.log`. A `DENY <host>` for a source you trust (a new CDN):
  add it to `scripts/egress-allowlist.txt` (reloaded at once) and run `make provision` again. `could not open the egress
  tunnel`: the VM's sshd must allow forwarding (`AllowTcpForwarding yes`). With `egress=proxy`, check `proxy=`.
  The forwarder logs to `$TMPDIR/indev-k8s-ext-<uid>.fwd.log`.

## Lost admin.conf

**Symptom:** `make provision` fails in the `kubeadm` role: "`/etc/kubernetes/admin.conf` is missing but a control
plane exists".

**Cause:** the file is gone from the node. The role will not run `kubeadm init` or `reset`, because that would wipe
etcd (B-029).

**Fix:** recreate it on the node, then provision again (this copies it to `out/admin.conf`):

```bash
limactl shell k8s -- sudo kubeadm init phase kubeconfig admin --config /etc/kubernetes/kubeadm-config.yaml
make provision TAGS=kubeadm
kubectl --kubeconfig out/admin.conf get nodes
```

If the etcd data is gone too, rebuild with `make vm-reset`. This destroys the cluster.

## All routes return 404

**Symptom:** every Ingress returns 404, or `kubectl logs -n traefik deployment/traefik` shows `forbidden`.

**Cause:** Traefik needs a Role in every namespace it watches (`ingress_traefik_watched_namespaces`). A deleted
watched namespace, or a new Ingress namespace missing from the list, breaks **all** routes (B-038).

**Fix:** add any new Ingress namespace to the list first ([ADR 0003](../decisions/0003-traefik-ingress.md)). Then
re-apply; this recreates the namespaces, Roles and bindings:

```bash
make provision TAGS=ingress_traefik
make verify REQ=4 STRICT=1
```

## Model missing or corrupt

**Symptom:** the llm pod is in `Init:Error` (the `verify-model` hash check failed), or `Pending` after its volume
claim was deleted.

**Cause:** the model file on the volume is missing or damaged.

**Fix:** provision again. It downloads the model only when the file is missing or its hash is wrong
([ADR 0008](../decisions/0008-model-caching.md)).

```bash
kubectl --kubeconfig out/admin.conf get pods -n llm
make provision TAGS=llm_app
make verify REQ=9 STRICT=1
```

If the download Job fails, the playbook fails. Read the Job's logs within 1 hour (then it is deleted):

```bash
kubectl --kubeconfig out/admin.conf logs -n llm -l component=model-fetch
```

## make smoke: Could not resolve host llm.local

**Cause:** the Mac has no `/etc/hosts` line. macOS sends `.local` names to mDNS first.

**Fix:**

```bash
scripts/hosts-entry.sh --apply
make smoke
```

## Every request to llm.local or grafana.local takes 5 s

**Cause:** `/etc/hosts` has only the `127.0.0.1` line (from before B-059). macOS sends the IPv6 lookup of a `.local`
name to mDNS and waits 5 s. Check: `curl -so /dev/null -w '%{time_namelookup}\n' --cacert certs/ca.crt https://llm.local/health`.

**Fix:** `scripts/hosts-entry.sh --apply` replaces the line with the `127.0.0.1` and `::1` pair; `make doctor` reports it.

## Fresh clone fails in pki: cert without key

**Symptom:** `make provision` asks "Restore the key or create a new CA?", or (no terminal, or `ansible-playbook`
run directly) fails: "`certs/ca.crt` exists but `.secrets/ca.key` does not".

**Cause:** the CA key is never committed, so a fresh clone has only the certificate (B-037).

**Fix:** either put the original key back in `.secrets/ca.key` (mode 0600), or answer `n` (same as `rm certs/ca.crt`)
for a new local CA. Commit the new `certs/ca.crt` only if it replaces the CA for everyone ([CA rotation](ca-rotation.md)).

## kubeadm stops on the cluster PKI host copy

**Symptom:** `make provision` fails in `kubeadm`: "`.secrets/kubeadm-pki` lacks some of ..." or "The node's cluster
CAs or SA keys differ from ...".

**Cause:** the host copy of the cluster CAs and ServiceAccount keys is incomplete, or the running cluster was built with
other ones ([ADR 0006](../decisions/0006-etcd-backups-outside-cluster.md#restore-on-a-rebuilt-vm)).

**Fix:** restore the missing files from your own copy; or rebuild with `make vm-reset` so the VM uses the host copy;
or move `.secrets/kubeadm-pki` away so the next run saves the node's PKI instead (old snapshots then need the
pod restart and token steps that B-050 describes).

## check_6 fails right after a restart

**Symptom:** `make verify REQ=6` fails on rollout or target checks after a provision, a node reboot or a Prometheus
restart.

**Cause:** pods are not Ready yet, or some targets have not been scraped once.
After a VM stop/start, `rules unhealthy: …increase30d` with `duplicate sample for timestamp` can also show for a few
minutes (seen 2026-11-23, cleared within 7 minutes).

**Fix:** wait, then run it again:

```bash
kubectl --kubeconfig out/admin.conf get pods -n monitoring
kubectl --kubeconfig out/admin.conf get pods -n node-exporter
make verify REQ=6 STRICT=1
```

If it keeps failing, read the failing line. `targets not UP` names the job and URL. etcd, scheduler and
controller-manager need the `kubeadm` role's metrics settings ([control plane notes](../architecture.md#control-plane-notes)).
`check_6` needs `jq` on the Mac (`make deps` installs it).
