# 0007 — Pod Security Admission `restricted` for application workloads

Status: Accepted (cluster defaults implemented in M2: `ansible/roles/kubeadm/files/admission-config.yaml`; namespace labels land in M9) · Date: 2026-11-17

## Context
Requirement 8: application workloads cannot run as root or with elevated privileges. Platform components (Calico, node-exporter, Traefik with hostNetwork) legitimately need host access.

## Decision
Use the built-in Pod Security Admission controller. Application namespaces (`app_namespaces`, currently `llm`) are labelled `enforce`, `audit` and `warn` = `restricted` (pinned to the cluster's version). The API server's `AdmissionConfiguration` sets cluster defaults of `enforce: baseline`, `audit/warn: restricted`, with platform namespaces exempt where they need it. App manifests set a full restricted `securityContext` explicitly rather than relying on defaults.

## Alternatives considered
- **Kyverno / Gatekeeper**: more flexible (e.g. require digests), but an extra controller for what PSA already enforces.

## Consequences
- Root, privileged, hostPath, host-network and added-capability pods are rejected in app namespaces at admission time.
- New application namespaces must be added to `app_namespaces`.
