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
| Agent permissions | allow-list + ask + narrow deny in `.claude/settings.json`, a guardrail, not a boundary | [0009](docs/decisions/0009-agent-permissions-guardrail.md) |
| Workload security | Pod Security Admission `restricted` for app namespaces | [0007](docs/decisions/0007-pod-security-restricted.md) |
| Monitoring | kube-prometheus-stack (Prometheus, Alertmanager, Grafana) | [architecture](docs/architecture.md) |
| Sample app | llama.cpp server + Qwen2.5-0.5B-Instruct Q4 GGUF, model cached on a PVC | [0008](docs/decisions/0008-model-caching.md) |

Exact versions: [`ansible/group_vars/all/versions.yml`](ansible/group_vars/all/versions.yml).

## Host installation

The host is an Apple Silicon Mac (arm64).

Steps that were run to prepare it:

**1. Prerequisites already present:** Homebrew, git, python3, kubectl, GitHub CLI (`gh`, used for PRs).

**2. Install Lima and Python 3.14 with Homebrew** (`make deps` does steps 2–4):

```bash
brew install lima python@3.14
```

**3. Create the pinned Python tooling and Ansible collections:**

```bash
make tools
```

This builds `.venv/` (gitignored) on Python 3.14 from [`requirements.txt`](requirements.txt) and installs the collections pinned in `ansible/requirements.yml` into `ansible/collections/` (gitignored). Every `make` target puts `.venv/bin` first on `PATH`, and so does the editor lint hook. Both steps re-run only when their requirements file changes.

| Tool | Version | Source | Used for |
|---|---|---|---|
| macOS | 26.6.2 | host OS | |
| Lima (`limactl`) | 2.3.0 | Homebrew | creates and runs the Debian 13 VM |
| Python | 3.14.5 | Homebrew `python@3.14` | runs the tools below |
| ansible-core | 2.21.6 | `.venv`, pinned | provisions the VM from the Mac over SSH |
| ansible-lint | 26.10.1 | `.venv`, pinned | lint (`make lint`, editor hook) |
| yamllint | 1.38.0 | `.venv`, pinned | lint (`make lint`, editor hook) |
| Collections | kubernetes.core 6.6.0, community.crypto 3.5.1, community.general 13.5.1, ansible.posix 2.2.2 | `ansible/collections`, pinned | Kubernetes, crypto and system modules |

Notes from the install:
- I first installed `ansible`, `ansible-lint` and `yamllint` with Homebrew. Homebrew builds them on Python 3.15, which ansible-core 2.21.6 does not support (ansible-lint warned about it; `ansible` runs on it silently). That's why the tools now come from a pinned venv on Python 3.14 (bug B-001 in [TODO.md](TODO.md)). The Homebrew copies can stay installed; the Makefile doesn't use them.
- A plain `ansible-galaxy collection install` reports "Nothing to do" when another Ansible on the machine already bundles the collections (Homebrew's does), and installs nothing into the project. `make collections` uses `--force` (B-002).
- Homebrew's Lima caveat mentions `lima-additional-guestagents`; it is only needed for non-native guest architectures (e.g. amd64 on Apple Silicon). Not needed here, the VM is arm64.

To use the pinned tools outside `make`, run `source .venv/bin/activate`.

Optional: `brew install shellcheck` adds shell-script linting to `make lint` (skipped when it isn't installed).

**Checked after install:** `limactl validate lima/k8s.yaml` OK, `make lint` clean (yamllint + ansible-lint `production` profile), `make check` OK.

**4. Enable the repo's git hooks:**

```bash
make hooks
```

This points git at `.githooks/`, whose `commit-msg` hook enforces Conventional Commit subjects and rejects AI attribution trailers, and whose `pre-commit` hook rejects commits on `main` ([git workflow](docs/ai-workflow.md#git-workflow)).

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
.githooks/          versioned git hooks (commit-msg, pre-commit)
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
