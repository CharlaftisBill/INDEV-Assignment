# Issue, use and revoke the operator kubeconfig

Read-only access, no Secrets. Design: [ADR 0011](../decisions/0011-operator-identity.md).

## Use
`make provision TAGS=hardening` writes `out/operator.conf` (0600, server `https://127.0.0.1:6443`).

```bash
kubectl --kubeconfig out/operator.conf get pods -A
kubectl --kubeconfig out/operator.conf auth can-i get secrets -A   # no
```

A VM rebuild needs nothing extra: provisioning reissues the cert automatically.

## Renew
Only on re-provision. The cert lasts 180 days and is reissued when missing, wrong subject, key/CA changed or within 30 days of expiry. There is no expiry alert, and `check_8a` fails inside the 30-day window.

```bash
make provision TAGS=hardening
make verify REQ=8a STRICT=1
```

## Revoke
x509 has no CRL; a cert stays valid until expiry, so remove what it is authorised by.

1. Cut access now (emergency; stops every cert in the group):
   ```bash
   kubectl --kubeconfig out/admin.conf delete clusterrolebinding operator-readonly
   ```
2. Rename the group: `hardening_operator_group` in `ansible/roles/hardening/defaults/main.yml`. Without this, step 4 re-binds the old group and the leaked cert works again.
3. Drop the host credentials (a plain reissue keeps the key):
   ```bash
   rm .secrets/operator.key .secrets/operator.crt out/operator.conf
   ```
4. Issue a new key and cert and bind the new group:
   ```bash
   make provision TAGS=hardening
   make verify REQ=8a STRICT=1
   ```
