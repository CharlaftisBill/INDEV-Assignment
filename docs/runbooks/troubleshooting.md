# Troubleshooting

## Lost admin.conf

Symptom: `make provision` fails in the `kubeadm` role with "`/etc/kubernetes/admin.conf` is missing but a control plane exists" (B-029). The role will not run `kubeadm init`/`reset`, which would wipe etcd.

Recreate it on the node, then re-provision (copies it to `out/admin.conf`):

```bash
limactl shell k8s -- sudo kubeadm init phase kubeconfig admin --config /etc/kubernetes/kubeadm-config.yaml
make provision TAGS=kubeadm
kubectl --kubeconfig out/admin.conf get nodes
```

If etcd data is also gone, rebuild instead: `make vm-reset` (destructive).

## Routes vanish / Traefik log shows forbidden

Symptom: every Ingress returns 404, or `kubectl logs -n traefik deployment/traefik` shows `forbidden` (B-038). Traefik needs a Role in every namespace of `ingress_traefik_watched_namespaces`; a deleted watched namespace or a new Ingress namespace missing from the list breaks all routes. Re-apply (recreates namespaces, Roles and bindings):

```bash
make provision TAGS=ingress_traefik
make verify REQ=4 STRICT=1
```

A new Ingress namespace must be added to `ingress_traefik_watched_namespaces` first ([ADR 0003](../decisions/0003-traefik-ingress.md)).

## Model missing or corrupt, llm pod Pending or Init:Error

Symptom: pod in `Init:Error` (`verify-model` sha256 mismatch), or `Pending` after the PVC was deleted. The model is re-fetched only when the file hash on the node is wrong or absent; re-provisioning does that ([ADR 0008](../decisions/0008-model-caching.md)):

```bash
kubectl --kubeconfig out/admin.conf get pods -n llm
make provision TAGS=llm_app
make verify REQ=9 STRICT=1
```

If the fetch Job fails, the play fails. Read its logs within 1h (the failed Job is then removed):

```bash
kubectl --kubeconfig out/admin.conf logs -n llm -l component=model-fetch
```

## make smoke: Could not resolve host llm.local

The Mac has no `/etc/hosts` entry (`.local` goes to mDNS first). Add it, then retry:

```bash
scripts/hosts-entry.sh --apply
make smoke
```

## Fresh clone fails in pki: cert without key

Symptom: `make provision` fails with "`certs/ca.crt` exists but `.secrets/ca.key` does not" (B-037). `ca.key` is never committed. Either restore the original key to `.secrets/ca.key` (mode 0600), or delete `certs/ca.crt` to create a new CA, then recommit `certs/ca.crt` ([rotation](ca-rotation.md)).
