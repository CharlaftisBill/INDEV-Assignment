# Operator kubeconfig: use, renew, revoke

The operator can read the cluster but not Secrets, and cannot change anything.
Design: [ADR 0011](../decisions/0011-operator-identity.md).

## Use

`make provision TAGS=hardening` writes `out/operator.conf` (mode 0600, server `https://127.0.0.1:6443`).

```bash
kubectl --kubeconfig out/operator.conf get pods -A
kubectl --kubeconfig out/operator.conf auth can-i get secrets -A   # answers "no"
```

After a VM rebuild, provisioning issues a new certificate. Nothing else to do.

## Renew

The certificate lasts 180 days. Provisioning renews it when it expires within 30 days (or is missing, has the wrong
name, or the key or CA changed). There is no expiry alert, but `check_8a` fails inside those 30 days.

```bash
make provision TAGS=hardening
make verify REQ=8a STRICT=1
```

## Revoke

Certificates can't be revoked: a certificate stays valid until it expires. So remove what it gives access to.

1. **Cut access now.** This stops every certificate in the group:
   ```bash
   kubectl --kubeconfig out/admin.conf delete clusterrolebinding operator-readonly
   ```
2. **Rename the group**: change `hardening_operator_group` in `ansible/roles/hardening/defaults/main.yml`.
   Without this, step 4 binds the old group again and the leaked certificate works again.
3. **Delete the files on the Mac.** A normal reissue keeps the old key.
   ```bash
   rm .secrets/operator.key .secrets/operator.crt out/operator.conf
   ```
4. **Issue a new key and certificate**, and bind the new group:
   ```bash
   make provision TAGS=hardening
   make verify REQ=8a STRICT=1
   ```
