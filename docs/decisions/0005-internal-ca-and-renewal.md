# 0005 — Internal CA and automatic certificate renewal

Status: Accepted · Date: 2026-11-19

## Context
Requirement 4: TLS certificates from our own CA, renewed automatically. The CA certificate is committed to git,
and `curl --cacert certs/ca.crt` must keep working after the VM is rebuilt.

## Decision
Ansible creates the root CA **on the Mac**, once, and reuses it on every run (`ansible/roles/pki/tasks/ca.yml`).
cert-manager signs and renews all leaf certificates with it.

## Details
- **CA**: CN `INDEV internal CA`, EC P-256, valid 10 years, `CA:TRUE, pathlen:0`. Key in `.secrets/ca.key` (mode 0600, gitignored).
  Certificate in `certs/ca.crt` (committed).
- **Name limits** (critical, B-035): the CA may sign only `*.local` names, and no IP addresses. A leaked key can't
  sign for real domains. The limits are set only when a CA is created; changing them needs a new CA.
- **Fresh clone** (B-037): `certs/ca.crt` without `.secrets/ca.key` stops the run instead of making a new key.
  The role also checks that key and certificate belong together.
- **In the cluster**: the key pair goes into Secret `internal-ca-key-pair` in `cert-manager`. ClusterIssuer
  `internal-ca` uses it.
- **cert-manager**: namespace `restricted`. Its `startupapicheck` Job is off; the role waits for the Deployments and
  retries the ClusterIssuer instead. The `acmesolver` image is pinned but unused (no ACME).
- **Leaf certificates**: valid 90 days (2160h), renewed 30 days (720h) before expiry (`group_vars/all/main.yml`).
  `check_4` proves renewal with a 1-hour certificate: it renews, and Traefik serves the new one without a restart.

## Alternatives
| Option | Why not |
|---|---|
| CA made inside the cluster | A VM rebuild makes a new CA; the committed `ca.crt` stops matching |
| Offline root + intermediate CA in the cluster | Better for production; an extra step with little value here |

## Consequences
- The trust anchor stays the same across rebuilds. Rotation: [runbook](../runbooks/ca-rotation.md).
- The CA key is on the Mac and in a cluster Secret. Whoever can read Secrets in `cert-manager` holds the CA.
