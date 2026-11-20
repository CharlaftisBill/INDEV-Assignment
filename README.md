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
| Ingress | Traefik (hostNetwork on 8443/8000; Lima maps Mac 443/80; trust anchor `certs/ca.crt`) | [0003](docs/decisions/0003-traefik-ingress.md) |
| Storage | local-path-provisioner (default StorageClass) | [0004](docs/decisions/0004-local-path-storage.md) |
| TLS | internal root CA (host-generated) + cert-manager CA issuer | [0005](docs/decisions/0005-internal-ca-and-renewal.md) |
| Backups | etcd snapshots → `./backups` on the host via Lima mount | [0006](docs/decisions/0006-etcd-backups-outside-cluster.md) |
| Host toolchain | only `make` needed: pinned, sha256-checked tools in `.tools/` (`make doctor` / `deps` / `uninstall`) | [0012](docs/decisions/0012-host-toolchain.md) |
| Agent permissions | allow-list + ask + narrow deny in `.claude/settings.json`, a guardrail, not a boundary | [0009](docs/decisions/0009-agent-permissions-guardrail.md) |
| Workload security | Pod Security Admission `restricted` for app namespaces | [0007](docs/decisions/0007-pod-security-restricted.md) |
| Monitoring | kube-prometheus-stack (Prometheus, Alertmanager, Grafana) | [0010](docs/decisions/0010-monitoring-stack.md) |
| Sample app | llama.cpp server + Qwen2.5-0.5B-Instruct Q4 GGUF, model cached on a PVC | [0008](docs/decisions/0008-model-caching.md) |

Exact versions: [`ansible/group_vars/all/versions.yml`](ansible/group_vars/all/versions.yml).

## Host installation

**Prerequisite: `make`** (plus base OS tools: `curl`, `tar`, `git`, `openssl`, `sudo`). On macOS, `xcode-select --install`
provides all of them. Tested on Apple Silicon macOS; Intel macOS is untested; Linux hosts still need the `lima/k8s.yaml` change in the [Backlog](TODO.md#backlog); Windows is out of scope.

```bash
make doctor   # read-only: each tool and host setting is OK, MISSING or WRONG VERSION, with the fix
make deps     # installs only what is missing; prints the plan first, asks before anything that needs sudo
```

`make deps` downloads pinned, sha256-checked binaries into `.tools/` (gitignored) and builds `.venv/` on that Python
([ADR 0012](docs/decisions/0012-host-toolchain.md)). Every `make` target puts `.tools/bin` and `.venv/bin` first on `PATH`;
copies installed elsewhere (Homebrew, distro) are ignored. A second `make deps` installs nothing.

| Tool | Version | Source | Used for |
|---|---|---|---|
| Python | 3.14.10 | `.tools`, python-build-standalone | runs the tools below |
| Lima (`limactl`) | 2.3.0 | `.tools`, release tarball | creates and runs the Debian 13 VM |
| kubectl | v1.35.10 | `.tools`, dl.k8s.io | `make verify`, cluster access (matches the cluster) |
| jq | 1.8.2 | `.tools`, GitHub release | `make verify` (checks 3b, 6, 9) |
| shellcheck | 0.11.0 | `.tools`, GitHub release | `make lint` |
| ansible-core / ansible-lint / yamllint | 2.21.6 / 26.10.1 / 1.38.0 | `.venv`, [`requirements.txt`](requirements.txt) | provisioning from the host over SSH, lint |
| Collections | kubernetes.core 6.6.0, community.crypto 3.5.1, community.general 13.5.1, ansible.posix 2.2.2 | `ansible/collections`, [`ansible/requirements.yml`](ansible/requirements.yml) | Kubernetes, crypto and system modules |

Versions and checksums: `host_*` keys in [`versions.yml`](ansible/group_vars/all/versions.yml). `gh` is optional (only for PRs) and not installed.

What `make deps` also does:
- **`/etc/hosts`** (sudo, asks first): adds `127.0.0.1 llm.local grafana.local # indev-k8s`, the same as
  `scripts/hosts-entry.sh --apply`. Grafana is then at `https://grafana.local` (user `admin`, password in
  `.secrets/grafana-admin-password`; see the [monitoring runbook](docs/runbooks/monitoring.md)).
- **Git hooks**: `git config core.hooksPath .githooks` (`commit-msg` enforces Conventional Commits and rejects AI
  attribution, `pre-commit` rejects commits on `main`; [git workflow](docs/ai-workflow.md#git-workflow)).
- **Linux only** (sudo, asks first, recorded in `.tools/system-manifest`): QEMU packages for Lima, and
  `net.ipv4.ip_unprivileged_port_start=80` so Lima can forward ports 443 and 80.

To use the pinned tools outside `make`: `export PATH=$PWD/.tools/bin:$PWD/.venv/bin:$PATH`.

History: until 2026-11-20 `make deps` used Homebrew (`lima`, `python@3.14`). Homebrew's Ansible runs on Python 3.15,
which ansible-core 2.21 doesn't support (B-001), and a plain `ansible-galaxy collection install` skips collections another
Ansible already bundles (B-002, hence `--force`). Homebrew copies can stay installed; make no longer uses them.

## Uninstall

```bash
make uninstall DRY_RUN=1   # list the steps only
make uninstall             # asks y/N before each step
```

It removes only what `make` created: the VM (`limactl delete`), the `/etc/hosts` line (`scripts/hosts-entry.sh --remove`),
what `.tools/system-manifest` lists (Linux packages and sysctl that `make deps` added), `.tools/`, `.venv/`, `.ansible/`,
`ansible/collections/`, `out/` (kubeconfigs), `backups/*` (etcd snapshots, keeps `.gitkeep`), and `core.hooksPath`.

- **Kept** unless `PURGE_SECRETS=1`: `.secrets/` (CA key). Without it the next provision creates a new CA, so the committed
  `certs/ca.crt` no longer matches and must be committed and trusted again (B-037).
- **Never touched**: tools you installed yourself (e.g. Homebrew `lima` / `python@3.14` from the old `make deps`: `brew
  uninstall lima python@3.14` if nothing else uses them), `~/.lima/_config` and Lima's image cache (shared with other Lima VMs).

## Quick start

```bash
make deps           # host tools (see Host installation)
make vm-up          # create + start the Debian 13 VM (4 CPU, 8 GiB, 40 GiB)
make provision      # run ansible/site.yml against it
make idempotency    # second run must report changed=0
make verify         # requirement checks (scripts/verify.sh)
make smoke          # the acceptance curl above
```

`make e2e` runs all of it from a freshly recreated VM. `make help` lists every target.

## Talking to the cluster

`make provision` writes the admin kubeconfig to `out/admin.conf` (mode 0600, gitignored), pointing at
`https://127.0.0.1:6443` (Lima's port forward). It does not touch `~/.kube/config`, so pass it explicitly:

```bash
kubectl --kubeconfig out/admin.conf get nodes
```

Or set it once per shell, from the repo root:

```bash
export KUBECONFIG=$PWD/out/admin.conf
```

It is the cluster-admin credential: don't share or commit it. A VM rebuild needs no manual step;
`make provision TAGS=kubeadm` writes it again. If it is lost on a running node, see the
[troubleshooting runbook](docs/runbooks/troubleshooting.md#lost-adminconf).

## Repository layout

```
ansible/            playbook (site.yml), roles, inventory, pinned versions
lima/k8s.yaml       VM definition
scripts/            verify.sh (requirement checks), host-tools.sh (doctor/deps/uninstall), hosts-entry.sh
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
- [Runbooks](docs/runbooks/): etcd restore, operator kubeconfig, CA rotation, monitoring, troubleshooting
- [How this was built with Claude Code](docs/ai-workflow.md)
