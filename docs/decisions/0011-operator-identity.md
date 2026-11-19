# 0011 — Read-only operator identity

Status: Accepted · Date: 2026-11-19

## Context
Requirement 8a: a read-only operator role and a kubeconfig for it. The operator must not read Secrets (etcd snapshots and the CA key are out of scope for them too).

## Decision
Role `hardening`:

- **Identity**: client certificate, CN=`operator`, O=`indev:operators`, signed through the CSR API (`kubernetes.io/kube-apiserver-client`, 180 days). The EC P-256 key is generated on the Mac (`.secrets/operator.key`) and never enters the cluster. Reissued when missing, wrong subject, key or CA changed, or within 30 days of expiry.
- **Binding**: ClusterRole `operator-readonly` bound to the group `indev:operators`, not the user, so a new cert needs no RBAC change.
- **Rules**: `get`/`list`/`watch` on an explicit resource list. No Secrets, `pods/exec`, `attach`, `portforward`, `proxy`, `serviceaccounts/token`, impersonate, escalate, bind or CSR approval. `pods/log` is allowed, as in `view`.
- **Explicit lists over the built-in `view` aggregate**: `view` aggregates any ClusterRole labelled for it, so a later chart can widen it silently. `check_8a` asserts the exact rules.
- **Calico caveat**: Calico's `calico-tiered-policy-passthrough` makes `auth can-i` answer yes on `projectcalico.org` policies, but real requests are Forbidden because the operator cannot `get` tiers. Never grant tiers read; `check_8a` asserts it. Calico policies are therefore not readable by the operator (`kubectl get networkpolicy` works).

## Alternatives considered
- **ServiceAccount token kubeconfig**: token Secret or long-lived TokenRequest; bearer token in the kubeconfig, and the SA lives in the cluster it protects.
- **`kubeadm kubeconfig user`**: signs with the CA key on the node, bypassing the API and its audit; harder to bound lifetime and renew from Ansible.
- **OIDC**: right for teams, but needs an IdP and apiserver flags; excessive for one node.

## Consequences
- x509 certificates cannot be revoked (no CRL). Revoking means removing the binding: [runbook](../runbooks/operator-kubeconfig.md#revoke).
- No expiry alert; renewal happens on re-provision, and `check_8a` fails inside the 30-day window.
- The key is not rotated on reissue.
- Accepted Lows (not logged): namespaced grants to broad groups are not checked; a failed run can leave a CSR object; `auth can-i --list` check fails open.
