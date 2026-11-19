# 0005 — Internal CA and automatic certificate renewal

Status: Accepted · Date: 2026-11-19

## Context
Requirement 4: certificates from an internal CA we create, renewed automatically. The CA certificate is a deliverable in the git repo, and the reviewer's `curl --cacert ca.crt` must keep working if the VM is rebuilt.

## Decision
- Ansible creates the root CA **on the host** with `community.crypto` (EC P-256, 10-year validity, `basicConstraints CA:TRUE, pathlen:0`). Key in `.secrets/ca.key` (gitignored, mode 0600), certificate in `certs/ca.crt` (committed). Generated once, reused on every run (`ansible/roles/pki/tasks/ca.yml`).
- **Name constraints** (critical, B-035): permitted `DNS:local`, excluded all IPv4 and IPv6. A leaked CA key can only mint `*.local` names. They apply only when a CA is created; changing them needs a new CA.
- **Fresh clone** (B-037): `ca.crt` without `.secrets/ca.key` fails instead of creating an unrelated key; the key/cert public keys must match (assert).
- The key pair is loaded into Secret `internal-ca-key-pair` in `cert-manager`, backing ClusterIssuer `internal-ca` (type `ca`).
- Leaf certificates are `Certificate` resources; defaults `duration` 2160h, `renewBefore` 720h (`group_vars/all/main.yml`). `check_4` demonstrates renewal with a 1h certificate (`renewBefore` 59m45s, cert-manager's minimum duration): the revision increments and Traefik serves the new leaf without a restart.

## Alternatives considered
- **CA created inside the cluster** (cert-manager self-signed issuer → CA): a VM rebuild creates a new CA and the committed `ca.crt` stops matching.
- **Intermediate CA in cluster, root offline**: better practice for production; noted as an improvement, adds a step for little value here.

## Consequences
- Stable trust anchor across rebuilds; rotation procedure in `docs/runbooks/ca-rotation.md`.
- The CA key exists on the host and in a cluster Secret; access to the `cert-manager` namespace secrets is effectively CA access.
