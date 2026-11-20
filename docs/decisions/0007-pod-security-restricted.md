# 0007 — Pod Security `restricted` for app workloads

Status: Accepted (cluster defaults in M2, namespace labels in M9) · Date: 2026-11-17

## Context
Requirement 8: app workloads must not run as root or with extra privileges. Some platform parts (Calico,
node-exporter, Traefik on the host network) really need host access.

## Decision
Use Kubernetes' built-in Pod Security Admission (PSA).
- App namespaces (`app_namespaces`, today only `llm`) enforce, audit and warn at level `restricted`,
  pinned to the cluster version.
- Cluster default (`ansible/roles/kubeadm/files/admission-config.yaml`): enforce `baseline`, audit and warn
  `restricted`. Only `kube-system` is exempt. Platform namespaces that need host access (`tigera-operator`,
  `calico-system`, `local-path-storage`, `traefik`, `node-exporter`) are labelled `privileged` by their own roles.
- The `llm` labels pin the policy version (`pod_security_version`, now v1.35); bump it with the cluster's minor version.
- App manifests still set the full `restricted` security settings themselves, instead of trusting defaults.

## Alternatives
| Option | Why not |
|---|---|
| Kyverno, Gatekeeper | More flexible, but one more controller for what PSA already does |

## Consequences
- In app namespaces, root, privileged, host-folder, host-network and extra-capability pods are rejected on create.
- A new app namespace must be added to `app_namespaces`.
