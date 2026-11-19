# Rotate the internal CA and leaf certificates

Design: [ADR 0005](../decisions/0005-internal-ca-and-renewal.md).

## Leaf certificates

Automatic: cert-manager renews each `Certificate` 720h before its 2160h expiry; Traefik picks up the new Secret without a restart. Check:

```bash
kubectl --kubeconfig out/admin.conf get certificates -A
```

## Replace the root CA

Only when the CA key is lost or leaked. Every client must trust the new `certs/ca.crt`.

```bash
rm .secrets/ca.key certs/ca.crt            # both, or the role refuses (B-037)
make provision TAGS=pki                    # new key + cert (same name constraints), updates Secret internal-ca-key-pair
make verify REQ=4 STRICT=1
git add certs/ca.crt && git commit         # the new certificate is the deliverable
```

Then re-issue existing leaves so they chain to the new CA: delete each TLS Secret named by a `Certificate` and cert-manager recreates it.

```bash
kubectl --kubeconfig out/admin.conf get certificates -A
kubectl --kubeconfig out/admin.conf delete secret <name> -n <namespace>
```

Notes:
- Name constraints (permitted `DNS:local`, no IPs) carry over: they come from `pki_ca_permitted_names`/`pki_ca_excluded_names` in `ansible/roles/pki/defaults/main.yml`. Change them there before rotating if needed.
- Remove the old CA from any trust store (`curl --cacert certs/ca.crt` needs no cleanup).
- A fresh clone has `certs/ca.crt` but no key: see [troubleshooting](troubleshooting.md#fresh-clone-fails-in-pki-cert-without-key).
