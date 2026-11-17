# Requirements matrix

Each requirement from the assignment, where it is implemented, and how it is verified.
`scripts/verify.sh <id>` runs the checks for one requirement ID (`3` and `8` expand to their parts; add `--strict` to make SKIP fail). Status mirrors [TODO.md](../TODO.md).

| # | Requirement | Implementation | Verification (`scripts/verify.sh`) | Milestone | Status |
|---|---|---|---|---|---|
| 1 | OS prep, containerd, pinned packages | `ansible/roles/os_prep/`, `ansible/roles/containerd/` | `check_1`: containerd active, SystemdCgroup, swap off, sysctls, `apt-mark showhold` | M1 | Planned |
| 2 | kubeadm, single node runs control plane + workloads | `ansible/roles/kubeadm/` | `check_2`: node Ready, no NoSchedule taint, kube-system healthy | M2 | Planned |
| 3a | CNI installed and healthy | `ansible/roles/cni_calico/` | `check_3a`: Calico ready, pods get IPs from the pod CIDR | M3 | Planned |
| 3b | App pods accept only the traffic they need | NetworkPolicies in `ansible/roles/llm_app/` | `check_3b`: default-deny, blocked vs allowed test traffic | M9 | Planned |
| 4 | Ingress + internal CA TLS, auto renewal | `ansible/roles/pki/`, `ansible/roles/ingress_traefik/` | `check_4`: ClusterIssuer Ready, chain verifies against `certs/ca.crt`, renewal observed | M5 | Planned |
| 5 | Default StorageClass | `ansible/roles/storage/` | `check_5`: one default SC, test PVC binds | M4 | Planned |
| 6 | Prometheus + Grafana, node + etcd alerts | `ansible/roles/monitoring/` | `check_6`: components up, rules loaded, etcd target UP, alert firing in Alertmanager | M6 | Planned |
| 7 | Scheduled etcd snapshots outside the cluster | `ansible/roles/etcd_backup/` | `check_7`: timer active, fresh snapshot in `./backups`, `etcdutl snapshot status` OK | M7 | Planned |
| 8a | Read-only operator role + kubeconfig | `ansible/roles/hardening/` | `check_8a`: `auth can-i` matrix for the operator user | M8 | Planned |
| 8b | App workloads not root / not privileged | PSA config in `ansible/roles/kubeadm/`, ns labels in `ansible/roles/llm_app/` | `check_8b`: root and privileged test pods rejected in app ns | M2 (admission config), M9 (namespace labels) | Planned |
| 8c | Every API request recorded | audit policy in `ansible/roles/kubeadm/` | `check_8c`: audit log grows on a request, policy has no `None` rules | M2 | Planned |
| 9 | llama.cpp + Qwen2.5-0.5B Q4 over TLS, no re-download on restart | `ansible/roles/llm_app/` | `check_9`: completion over TLS; pod restart without re-download | M9 | Planned |
