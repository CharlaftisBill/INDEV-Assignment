# Grafana

Design: [ADR 0010](../decisions/0010-monitoring-stack.md). Helm release `kps` in namespace `monitoring`.

## Log in

1. Make sure the `/etc/hosts` line exists: `scripts/hosts-entry.sh --apply`.
2. Open `https://grafana.local`. The certificate is signed by `certs/ca.crt`.
3. User `admin`. The password is in `.secrets/grafana-admin-password` on the Mac (mode 0600, gitignored).

Never print the password into logs or chat. Copy it to the clipboard without showing it:

```bash
pbcopy < .secrets/grafana-admin-password
```

Check that the Secret exists (name only, no values):

```bash
kubectl --kubeconfig out/admin.conf get secrets -n monitoring -o name | grep grafana-admin
```

## Change the password

Delete the file and provision. A new password is made and the Secret updated. Then restart Grafana so it reads it:

```bash
rm .secrets/grafana-admin-password
make provision TAGS=monitoring
kubectl --kubeconfig out/admin.conf rollout restart deployment/kps-grafana -n monitoring
```

Grafana's own database is temporary (`emptyDir`). Nothing is lost on restart: dashboards come from ConfigMaps.
