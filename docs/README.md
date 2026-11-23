# Documentation

## I want to …

| … | Read |
|---|---|
| set up my Mac, or remove everything | [Install and uninstall](install.md) |
| use a Debian 13 VM I already have | [Your own VM](install.md#your-own-debian-13-vm-over-ssh-instead-of-lima) |
| run the usual commands, use kubectl, open Grafana | [Daily use](usage.md) |
| see how the pieces fit together | [Architecture](architecture.md) |
| know which version of something runs | [Versions](versions.md) |
| see how each requirement is built and checked | [Requirements](requirements-matrix.md) |
| know why something was chosen | [Decisions](#decisions) |
| know how we read unclear parts of the assignment, and which risks we accept | [Assumptions](assumptions.md) |
| fix or operate something | [Runbooks](#runbooks) |
| see how Claude Code built this | [AI workflow](ai-workflow/README.md) |
| see every bug found and how it was fixed | [Bugs](ai-workflow/bugs.md) |

## Decisions

Architecture Decision Records (ADRs): one choice each, with the options we rejected.

| # | Decision |
|---|---|
| [0001](decisions/0001-lima-vm.md) | Lima for the VM |
| [0002](decisions/0002-calico-cni.md) | Calico as network plugin |
| [0003](decisions/0003-traefik-ingress.md) | Traefik as ingress controller |
| [0004](decisions/0004-local-path-storage.md) | local-path-provisioner as default StorageClass |
| [0005](decisions/0005-internal-ca-and-renewal.md) | Our own CA, renewed by cert-manager |
| [0006](decisions/0006-etcd-backups-outside-cluster.md) | etcd snapshots stored on the Mac |
| [0007](decisions/0007-pod-security-restricted.md) | Pod Security `restricted` for apps |
| [0008](decisions/0008-model-caching.md) | Keeping the model across restarts |
| [0009](decisions/0009-agent-permissions-guardrail.md) | Agent permissions are a guardrail |
| [0010](decisions/0010-monitoring-stack.md) | Monitoring with kube-prometheus-stack |
| [0011](decisions/0011-operator-identity.md) | Read-only operator identity |
| [0012](decisions/0012-host-toolchain.md) | Pinned host tools inside the repo |

## Runbooks

Step-by-step tasks.

| Runbook | When |
|---|---|
| [Troubleshooting](runbooks/troubleshooting.md) | Something is broken |
| [Restore etcd](runbooks/etcd-restore.md) | Check backups, or go back to a snapshot |
| [Rotate the CA](runbooks/ca-rotation.md) | The CA key is lost or leaked |
| [Operator kubeconfig](runbooks/operator-kubeconfig.md) | Use, renew or revoke read-only access |
| [Grafana](runbooks/grafana.md) | Log in, change the password |
| [Alert demo](runbooks/alert-demo.md) | Fire a real node and etcd alert |
| [Prometheus memory](runbooks/prometheus-memory.md) | "Too many samples", or Prometheus runs out of memory |

## Repository layout

```
ansible/            playbook (site.yml), roles, inventory, pinned versions
lima/k8s.yaml       VM definition
external-vm.conf.example   copy to external-vm.conf to use your own VM over SSH instead of Lima
scripts/            verify.sh (requirement checks), host-tools.sh (doctor/deps/uninstall), hosts-entry.sh,
                    external.sh + loopback-forward.py + egress-proxy.py, egress-allowlist.txt
                    (own VM: SSH, tunnels, air-gapped downloads, backups-pull)
certs/ca.crt        our CA certificate (the key is never committed)
docs/               these docs
backups/            etcd snapshots from the VM (gitignored)
out/                generated kubeconfigs (gitignored)
.claude/            agents, skills, hooks and permissions for Claude Code
.githooks/          git hooks (commit-msg, pre-commit)
CLAUDE.md           project rules for the agent
TODO.md             milestones and backlog
k8s-single-node-assignment.md   the assignment
```
