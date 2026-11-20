# 0011 — Read-only operator identity

Status: Accepted · Date: 2026-11-19

## Context
Requirement 8a: a read-only operator role and a kubeconfig for it. The operator must not read Secrets.

## Decision
Role `hardening` gives the operator a **client certificate** and binds a read-only ClusterRole to its **group**.

## Details
- **Certificate**: name `operator`, group `indev:operators`. Signed through the Kubernetes certificate API
  (CSR, signer `kubernetes.io/kube-apiserver-client`), valid 180 days. The EC P-256 key is made on the Mac
  (`.secrets/operator.key`) and never enters the cluster.
- **Reissued** on provision when it is missing, has the wrong name, the key or CA changed, or it expires within 30 days.
- **Binding**: ClusterRole `operator-readonly` is bound to the group, not the user, so a new certificate needs no
  RBAC change.
- **Rules**: only `get`, `list`, `watch`, on an explicit list of resources. No Secrets, `pods/exec`, `attach`,
  `portforward`, `proxy`, `serviceaccounts/token`, impersonate, escalate, bind or CSR approval.
  `pods/log` is allowed, like the built-in `view` role (logs may hold app data). Reads also cover RBAC objects, CRDs,
  webhook configs, CSRs, and cert-manager and Prometheus-operator objects.
- **Files**: certificate in `.secrets/operator.crt`; it is also reissued after a VM rebuild (new cluster CA).
- **Why not the built-in `view` role**: `view` grows when any chart adds a role labelled for it. An explicit list
  can't grow silently. `check_8a` asserts the exact rules.
- **Calico caveat**: because of Calico's `calico-tiered-policy-passthrough` binding, `auth can-i` says yes for
  `projectcalico.org` policies. Real requests still fail, because the operator can't read tiers. Never grant tiers;
  `check_8a` asserts this with a real dry-run create. So the operator can't read Calico policies, only standard ones (`kubectl get networkpolicy`).

## Alternatives
| Option | Why not |
|---|---|
| ServiceAccount token | Long-lived bearer token in the kubeconfig; the account lives in the cluster it protects |
| `kubeadm kubeconfig user` | Signs with the CA key on the node, past the API and its audit log; harder to renew from Ansible |
| OIDC | Right for teams, but needs an identity provider and API server flags |

## Consequences
- Certificates can't be revoked (no CRL). To revoke, remove the binding: [runbook](../runbooks/operator-kubeconfig.md#revoke).
- No expiry alert. Renewal happens on provision, and `check_8a` fails within 30 days of expiry.
- The key is not rotated on reissue.
- Accepted Low risks: namespaced grants to broad groups are not checked; a failed run can leave a CSR object;
  the `auth can-i --list` check fails open.
