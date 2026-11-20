# Troubleshooting

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

## Fresh clone fails in pki: cert without key

**Symptom:** `make provision` fails: "`certs/ca.crt` exists but `.secrets/ca.key` does not".

**Cause:** the CA key is never committed, so a fresh clone has only the certificate (B-037).

**Fix:** either put the original key back in `.secrets/ca.key` (mode 0600), or delete `certs/ca.crt` to make a new CA
and commit the new `certs/ca.crt` ([CA rotation](ca-rotation.md)).

## check_6 fails right after a restart

**Symptom:** `make verify REQ=6` fails on rollout or target checks after a provision, a node reboot or a Prometheus
restart.

**Cause:** pods are not Ready yet, or some targets have not been scraped once.

**Fix:** wait, then run it again:

```bash
kubectl --kubeconfig out/admin.conf get pods -n monitoring
kubectl --kubeconfig out/admin.conf get pods -n node-exporter
make verify REQ=6 STRICT=1
```

If it keeps failing, read the failing line. `targets not UP` names the job and URL. etcd, scheduler and
controller-manager need the `kubeadm` role's metrics settings ([control plane notes](../architecture.md#control-plane-notes)).
`check_6` needs `jq` on the Mac (`make deps` installs it).
