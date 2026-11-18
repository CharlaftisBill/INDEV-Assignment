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
