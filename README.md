# INDEV assignment: single-node Kubernetes

A single-node Kubernetes cluster on a local Debian 13 VM, built with Ansible from a clean OS image,
ending in a llama.cpp server reachable over TLS from the host:

```bash
curl --cacert certs/ca.crt https://llm.local/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello"}]}'
```

> **Status:** scaffolding done (M0). Progress, open bugs and assumptions are tracked in [TODO.md](TODO.md).

## Stack

| Concern | Choice | Why (ADR) |
|---|---|---|
| VM | Lima (Apple Virtualization, arm64), Debian 13 | [0001](docs/decisions/0001-lima-vm.md) |
| Runtime / installer | containerd + kubeadm | assignment |
| CNI | Calico | [0002](docs/decisions/0002-calico-cni.md) |
| Ingress | Traefik (hostNetwork on 80/443) | [0003](docs/decisions/0003-traefik-ingress.md) |
| Storage | local-path-provisioner (default StorageClass) | [0004](docs/decisions/0004-local-path-storage.md) |
| TLS | internal root CA (host-generated) + cert-manager CA issuer | [0005](docs/decisions/0005-internal-ca-and-renewal.md) |
| Backups | etcd snapshots → `./backups` on the host via Lima mount | [0006](docs/decisions/0006-etcd-backups-outside-cluster.md) |
| Workload security | Pod Security Admission `restricted` for app namespaces | [0007](docs/decisions/0007-pod-security-restricted.md) |
| Monitoring | kube-prometheus-stack (Prometheus, Alertmanager, Grafana) | [architecture](docs/architecture.md) |
| Sample app | llama.cpp server + Qwen2.5-0.5B-Instruct Q4 GGUF, model cached on a PVC | [0008](docs/decisions/0008-model-caching.md) |

Exact versions: [`ansible/group_vars/all/versions.yml`](ansible/group_vars/all/versions.yml).

## Host installation

The host is an Apple Silicon Mac (arm64).

Steps that were run to prepare it:

**1. Prerequisites already present:** Homebrew, git, python3, kubectl.

**2. Install the host tools** (`make deps` does steps 2 and 3):

```bash
brew install lima ansible ansible-lint yamllint
```

| Tool | Version installed | Used for |
|---|---|---|
| Lima (`limactl`) | 2.3.0 | creates and runs the `Debian 13 VM` |
| Ansible (ansible-core) | 2.21.6 | provisions the VM from the Mac over SSH |
| ansible-lint | 26.10.1 | lint (`make lint`, editor hook) |
| yamllint | 1.38.0 | lint (`make lint`, editor hook) |
| macOS | 26.6.2 | host OS |

Notes from the install:
- Homebrew's Lima caveat mentions `lima-additional-guestagents`; it is only needed for non-native guest architectures (e.g. amd64 on Apple Silicon). Not needed here, the VM is arm64.
- ansible-lint warns that ansible-core 2.21.6 supports Python up to 3.14 while Homebrew built it on 3.15. Lint works; tracked as a bug in [TODO.md](TODO.md).

**3. Install the pinned Ansible collections** into `ansible/collections/` (gitignored):

```bash
make collections
```

Installed: kubernetes.core 6.6.0, community.crypto 3.5.1, community.general 13.5.1, ansible.posix 2.2.2 (pinned in `ansible/requirements.yml`).
Homebrew's `ansible` already bundles these collections, so a plain `ansible-galaxy collection install` reports "Nothing to do" and installs nothing into the project. `make collections` uses `--force` and only re-runs when `requirements.yml` changes. Inside `ansible/`, the project copy takes precedence.

Optional: `brew install shellcheck` adds shell-script linting to `make lint` (skipped when it isn't installed).

**Checked after install:** `limactl validate lima/k8s.yaml` OK, `make lint` clean (yamllint + ansible-lint `production` profile), `make check` OK.

**4. Enable the repo's git hooks** (`make deps` does this too):

```bash
make hooks
```

This points git at `.githooks/`, whose `commit-msg` hook enforces Conventional Commit subjects and rejects AI attribution trailers.

**5. Map the ingress hostnames to the VM's port-forward** (one time, needs sudo):

```bash
scripts/hosts-entry.sh --apply
```

This adds `127.0.0.1 llm.local grafana.local` to `/etc/hosts`.

## Quick start

```bash
make vm-up          # create + start the Debian 13 VM (4 CPU, 8 GiB, 40 GiB)
make provision      # run ansible/site.yml against it
make idempotency    # second run must report changed=0
make verify         # requirement checks (scripts/verify.sh)
make smoke          # the acceptance curl above
```

`make e2e` runs all of it from a freshly recreated VM. `make help` lists every target.

## Repository layout

```
ansible/            playbook (site.yml), roles, inventory, pinned versions
lima/k8s.yaml       VM definition
scripts/            verify.sh (requirement checks), hosts-entry.sh
certs/ca.crt        internal CA certificate (deliverable; the key is never committed)
docs/               architecture, requirements matrix, ADRs, runbooks, AI workflow
backups/            etcd snapshots from the VM (gitignored)
out/                generated kubeconfigs (gitignored)
.claude/            agents, skills, hooks and permissions used to build this with Claude Code
.githooks/          versioned git hooks (commit-msg)
CLAUDE.md           project instructions for the agent
TODO.md             milestones, bugs (Open/Solved), assumptions
k8s-single-node-assignment.pdf   the assignment brief
```

## Documentation

- [Architecture](docs/architecture.md)
- [Requirements matrix](docs/requirements-matrix.md): each requirement → implementation → how it is verified
- [Decisions (ADRs)](docs/decisions/)
- [Runbooks](docs/runbooks/): etcd restore, operator kubeconfig, CA rotation, troubleshooting
- [How this was built with Claude Code](docs/ai-workflow.md)
