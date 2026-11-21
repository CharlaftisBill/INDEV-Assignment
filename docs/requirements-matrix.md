# Requirements

Each requirement from the assignment: where it is built and how it is checked.
Run one check with `make verify REQ=<id> STRICT=1` (`STRICT=1` turns SKIP into FAIL).
The checks are `check_<id>` in [`scripts/verify.sh`](../scripts/verify.sh); `3` and `8` run all their parts.
Status mirrors [TODO.md](../TODO.md). Final run (M10, 2026-11-20): `make e2e` from a destroyed VM, 313 PASS · 0 FAIL · 0 SKIP.
Disruptive tests (kubelet restart, containerd restart, pod deletion, VM reboot) passed, then all 12 IDs passed again.

| ID | Requirement | Role | Checks | Milestone | Status |
|---|---|---|---|---|---|
| [1](#1-os-and-container-runtime) | OS prep, containerd, pinned packages | `os_prep`, `containerd` | 19 | M1 | Done |
| [2](#2-kubeadm-single-node) | kubeadm, one node runs everything | `kubeadm` | 21 | M2 | Done |
| [3a](#3a-network-plugin) | CNI installed and healthy | `cni_calico` | 15 | M3 | Done |
| [3b](#3b-app-network-policy) | App pods accept only needed traffic | `llm_app` | 18 | M9 | Done |
| [4](#4-ingress-and-tls) | Ingress + internal CA, auto renewal | `pki`, `ingress_traefik` | 48 | M5 | Done |
| [5](#5-default-storageclass) | Default StorageClass | `storage` | 15 | M4 | Done |
| [6](#6-monitoring-and-alerts) | Prometheus + Grafana, node and etcd alerts | `monitoring` | 76 | M6 | Done |
| [7](#7-etcd-backups) | Scheduled etcd snapshots outside the cluster | `etcd_backup` | 23 | M7 | Done |
| [8a](#8a-read-only-operator) | Read-only operator role + kubeconfig | `hardening` | 35 | M8 | Done |
| [8b](#8b-no-root-app-pods) | App pods not root, not privileged | `kubeadm`, `llm_app` | 19 | M2, M9 | Done |
| [8c](#8c-audit-every-request) | Every API request recorded | `kubeadm` | 8 | M2 | Done |
| [9](#9-llm-app) | llama.cpp + Qwen2.5-0.5B over TLS, no re-download | `llm_app` | 17 | M9 | Done |

## 1. OS and container runtime

- **Built:** swap off (also after reboot); `overlay` and `br_netfilter` modules; 3 network sysctls; 9 base packages
  plus containerd and runc, pinned and held; containerd uses systemd cgroups. runc's known CVEs are accepted (B-026).
- **Checked:** all of the above, including persistence and `apt-mark showhold`. `make idempotency` passes.

## 2. kubeadm single node

- **Built:** Kubernetes packages from pkgs.k8s.io v1.35, pinned and held, signing key checked. `kubeadm init` from a
  config ([control plane notes](architecture.md#control-plane-notes)). Control-plane taint removed. `out/admin.conf`
  for the Mac. `init` never runs over an existing cluster (B-029, [runbook](runbooks/troubleshooting.md#lost-adminconf)).
  Cluster CAs and ServiceAccount keys are kept in `.secrets/kubeadm-pki/` and reused on a rebuilt VM.
- **Checked:** `/readyz` from the Mac over verified TLS; node CAs and SA public key match the host copy;
  one Ready node at the pinned version, no blocking taint;
  packages held; every kube-system pod healthy. After kubelet restart, containerd restart and VM reboot it stays healthy.

## 3a. Network plugin

- **Built:** Calico via the tigera-operator chart, images by digest, one IP pool `10.244.0.0/16`
  ([ADR 0002](decisions/0002-calico-cni.md)).
- **Checked:** Calico status Available; CNI config and IP pool; CoreDNS gets pod-network IPs; resource requests set;
  running images match `versions.yml`.

## 3b. App network policy

- **Built:** namespace `llm` denies all traffic in and out, then allows only what is needed
  ([who may talk to the app](architecture.md#who-may-talk-to-the-app)).
- **Checked:** the deny policies exist; test traffic that should be blocked is blocked, the rest passes. Traffic from
  the node itself is always allowed by Kubernetes, so the check tests other pods ([assumptions](assumptions.md)).

## 4. Ingress and TLS

- **Built:** our root CA, made on the Mac and limited to `*.local`; cert-manager signs with it
  ([ADR 0005](decisions/0005-internal-ca-and-renewal.md)). Traefik, non-root, on the host network
  ([ADR 0003](decisions/0003-traefik-ingress.md)).
- **Checked:** CA, key and name limits; cert-manager and Traefik pinned and hardened; Traefik can read Secrets only
  in its namespaces. From the Mac: the chain verifies against `certs/ca.crt`, HTTP redirects, and a 1-hour
  certificate renews by itself and is served.

## 5. Default StorageClass

- **Built:** local-path-provisioner; `local-path` is the default class ([ADR 0004](decisions/0004-local-path-storage.md)).
- **Checked:** `local-path` is the only default. A non-root test pod asks for a volume without naming a class, gets a
  `local-path` volume, writes and reads a file. After delete, the volume and its folder are gone.

## 6. Monitoring and alerts

- **Built:** kube-prometheus-stack, Grafana at `https://grafana.local`, default node and etcd alerts, Traefik alerts
  ([ADR 0010](decisions/0010-monitoring-stack.md)).
- **Checked** (needs `jq`): pods ready and pinned; memory budget and query limits; 19 targets up, etcd too;
  `Watchdog` in Alertmanager; `promtool` tests fire node, etcd and Traefik alerts.
  Real alerts: manual [demo](runbooks/alert-demo.md). Still passes after the disruptive tests.
  Accepted residual: unbounded `/series` calls by an admin ([assumptions](assumptions.md), B-043).

## 7. etcd backups

- **Built:** a systemd timer snapshots etcd every 30 minutes into `./backups` on the Mac
  ([ADR 0006](decisions/0006-etcd-backups-outside-cluster.md), [restore](runbooks/etcd-restore.md)).
- **Checked:** timer settings; the folder is the Mac mount; a valid snapshot exists; Mac and node see the same files;
  metrics fresh; `EtcdBackupStale` loaded. The mount type may be `virtiofs` (vz) or `9p` (QEMU).
  Restore tested by hand on the same VM and on a rebuilt VM (2026-11-20): see the [runbook](runbooks/etcd-restore.md).

## 8a. Read-only operator

- **Built:** ClusterRole `operator-readonly` (read only, no Secrets, no exec) for group `indev:operators`; client
  certificate in `out/operator.conf` ([ADR 0011](decisions/0011-operator-identity.md),
  [runbook](runbooks/operator-kubeconfig.md)).
- **Checked:** the exact role rules; `auth can-i` allows and denies; certificate subject and expiry.

## 8b. No-root app pods

- **Built:** cluster default Pod Security `baseline` (warn `restricted`); namespace `llm` enforces `restricted`
  ([ADR 0007](decisions/0007-pod-security-restricted.md)). The llama.cpp pod runs as user 10001, no privilege
  escalation, no capabilities, read-only root, no service account token.
- **Checked:** namespace labels; pod security settings; a root pod and a privileged pod are rejected in `llm`.

## 8c. Audit every request

- **Built:** `ansible/roles/kubeadm/files/audit-policy.yaml`: one catch-all `Metadata` rule, no `None` rules.
  Log `/var/log/kubernetes/audit/audit.log`, rotated (7 days, 5 files, 100 MB each).
- **Checked:** the policy (catch-all, no `None`, no Secret bodies); audit flags set; a unique request from the Mac
  shows up in the log.

## 9. LLM app

- **Built:** llama.cpp server (by digest) with the model on a 2 GiB volume. A Job downloads it only when the file is
  missing or its hash is wrong; an init container checks the hash before start. Ingress at `llm.local` with a
  certificate from our CA ([ADR 0008](decisions/0008-model-caching.md)).
- **Checked:** pinned image and model hash; a chat answer over TLS, verified with `certs/ca.crt`; a deleted pod comes
  back Ready without a new download. A llama.cpp restart passes only when its last termination reason is `Unknown`
  (node restart); a crash fails. `make smoke` is the acceptance curl.
  Recovery: [troubleshooting](runbooks/troubleshooting.md#model-missing-or-corrupt).
