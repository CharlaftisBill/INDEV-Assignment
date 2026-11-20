# Rotate the CA and certificates

Design: [ADR 0005](../decisions/0005-internal-ca-and-renewal.md).

## Leaf certificates

Nothing to do. cert-manager renews each certificate 30 days before it expires (they last 90 days).
Traefik picks up the new one without a restart. To see them:

```bash
kubectl --kubeconfig out/admin.conf get certificates -A
```

## Replace the root CA

Do this only if the CA key is lost or leaked. Afterwards every client must trust the new `certs/ca.crt`.

1. Delete both files. If only one is gone, the role refuses to run (B-037).
   ```bash
   rm .secrets/ca.key certs/ca.crt
   ```
2. Make a new CA. It gets the same name limits, and Secret `internal-ca-key-pair` is updated.
   ```bash
   make provision TAGS=pki
   make verify REQ=4 STRICT=1
   ```
3. Commit the new certificate. It is a deliverable.
   ```bash
   git add certs/ca.crt && git commit
   ```
4. Re-issue the existing certificates so they chain to the new CA. Delete the TLS Secret of each `Certificate`;
   cert-manager makes a new one.
   ```bash
   kubectl --kubeconfig out/admin.conf get certificates -A
   kubectl --kubeconfig out/admin.conf delete secret <name> -n <namespace>
   ```

## Notes

- The name limits (only `*.local`, no IPs) come from `pki_ca_permitted_names` and `pki_ca_excluded_names` in
  `ansible/roles/pki/defaults/main.yml`. Change them there before you rotate, if needed.
- Remove the old CA from any trust store you added it to. `curl --cacert` needs no cleanup.
- A fresh clone has `certs/ca.crt` but no key: see [troubleshooting](troubleshooting.md#fresh-clone-fails-in-pki-cert-without-key).
