# 0005 — Internal CA and automatic certificate renewal

Status: Proposed (accepted when implemented) · Date: 2026-11-17

## Context
Requirement 4: certificates from an internal CA we create, renewed automatically. The CA certificate is a deliverable in the git repo, and the reviewer's `curl --cacert ca.crt` must keep working if the VM is rebuilt.

## Decision
- Ansible creates the root CA **on the host** with `community.crypto` (EC P-256, 10-year validity, `basicConstraints CA:TRUE, pathlen:0`). Key in `.secrets/ca.key` (gitignored, mode 0600), certificate in `certs/ca.crt` (committed). Generated once, reused on every run.
- The key pair is loaded into the cluster as a Secret in `cert-manager`, backing a `ClusterIssuer` of type `ca`.
- Leaf certificates are `Certificate` resources with `duration` and `renewBefore`; cert-manager renews them automatically. A short-lived test certificate demonstrates renewal in `scripts/verify.sh`.

## Alternatives considered
- **CA created inside the cluster** (cert-manager self-signed issuer → CA): a VM rebuild creates a new CA and the committed `ca.crt` stops matching.
- **Intermediate CA in cluster, root offline**: better practice for production; noted as an improvement, adds a step for little value here.

## Consequences
- Stable trust anchor across rebuilds; rotation procedure in `docs/runbooks/ca-rotation.md`.
- The CA key exists on the host and in a cluster Secret; access to the `cert-manager` namespace secrets is effectively CA access.
