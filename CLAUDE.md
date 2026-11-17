# CLAUDE.md — INDEV single-node Kubernetes assignment

Build a single-node kubeadm cluster on a local Debian 13 VM **with Ansible, from a clean VM**,
ending in a llama.cpp server reachable at `https://llm.local` over TLS from the Mac.
The assignment is `k8s-single-node-assignment.pdf`. Project state and bugs: **`TODO.md` (read it first, update it last).**

## Requirements (details + verification in `docs/requirements-matrix.md`)
1. OS prep, containerd runtime, **pinned** package versions
2. kubeadm, one node = control plane + workloads
3. CNI (Calico); app pods accept only the traffic they need (NetworkPolicy)
4. Ingress (Traefik) + TLS from an internal CA we create, renewed automatically (cert-manager)
5. Default StorageClass (local-path-provisioner)
6. Prometheus + Grafana; alerts for node health and etcd health firing in Alertmanager
7. Scheduled etcd snapshots stored **outside the cluster** (host `./backups` via Lima mount)
8. Hardening: read-only operator role + operator kubeconfig; app pods non-root/unprivileged; every API request audited
9. llama.cpp + Qwen2.5-0.5B-Instruct GGUF Q4 on CPU, via ingress/TLS, no model re-download on pod restart

## Environment
- Host: Apple Silicon Mac. VM: Lima instance `k8s` (`lima/k8s.yaml`, vz, arm64, Debian 13, 4 CPU / 8 GiB / 40 GiB).
- Ansible runs **on the Mac** and pushes over SSH (`ansible/ansible.cfg` uses `~/.lima/k8s/ssh.config`, host alias `lima-k8s`).
- Shell in VM: `limactl shell k8s`. Admin kubeconfig (after M2): `out/admin.conf` → `kubectl --kubeconfig out/admin.conf ...`.
- Host-forwarded ports: 443, 80, 6443 only. `/etc/hosts` on the Mac maps `llm.local grafana.local` to 127.0.0.1 (`scripts/hosts-entry.sh`).

## Commands
- `make help` · `make deps` · `make vm-up` / `vm-down` / `vm-reset` (destructive) / `vm-shell`
- `make provision [TAGS=role]` · `make idempotency [TAGS=role]` (fails unless `changed=0`) · `make check`
- `make hooks` (enable `.githooks/`) · `make lint` · `make verify [REQ=n]` · `make smoke` (the acceptance curl) · `make e2e` (clean VM → all green)

## Hard rules
- **Versions**: every version/tag/digest lives in `ansible/group_vars/all/versions.yml`, with a source+date comment. Never `latest`, never unpinned apt installs; hold apt packages (`dpkg_selections: hold`). Images must have an arm64 manifest. Use the `pin-version` skill.
- **Ansible style**: FQCN modules (`ansible.builtin.*`, `kubernetes.core.*`); prefer modules over `command`/`shell`; when unavoidable, set `creates:`/`removes:` or `changed_when:`. Templates in `roles/<r>/templates/`, defaults in `defaults/main.yml`. Each role has a tag equal to its name in `site.yml`.
- **Idempotency**: a second `make provision` must report `changed=0`. Not optional.
- **Kubernetes objects** are applied with `kubernetes.core.k8s` / `kubernetes.core.helm` from Ansible, never by hand. Manual `kubectl` is for inspection only.
- **Secrets**: CA key lives in `.secrets/` (gitignored, Read-denied for the agent); kubeconfigs in `out/` (gitignored). Only `certs/ca.crt` is committed.
- **Workload security**: everything in `app_namespaces` must pass PSA `restricted`: `runAsNonRoot`, `allowPrivilegeEscalation: false`, drop ALL caps, `seccompProfile: RuntimeDefault`, prefer `readOnlyRootFilesystem`. Every app namespace starts with default-deny ingress+egress NetworkPolicies.
- **Commits**: only through the `split-commits` skill, which groups changes into focused Conventional Commits (`feat(kubeadm): ...`). **Never add `Co-Authored-By: Claude`, "Generated with Claude Code" or any AI attribution** to commits or PRs; `.githooks/commit-msg` rejects them (enable with `make hooks`). Never `git add -A`, never push without asking.
- **Scope**: one role/milestone at a time. Don't touch roles outside the current milestone without logging why in `TODO.md`.

## TODO.md protocol
- Read `TODO.md` before starting; update the Status line, milestone checkboxes and Bugs table before finishing.
- Bug states are only **Open** or **Solved**. IDs are sequential `B-NNN`, never reused or deleted.
- A bug becomes **Solved** only with the fixing commit hash (or "uncommitted" until committed) and a passing check.
- Verifier/reviewer agents only *open* bugs; the `ansible-engineer` agent solves them. Use the `bug` skill to keep the table format.
- A milestone can't be ticked while it has Open bugs.
- Assumptions made where the PDF is unclear go under "Assumptions" in `TODO.md`.

## Definition of done (per milestone)
`make lint` clean → `make provision TAGS=...` OK → `make idempotency` `changed=0` → `make verify REQ=n` PASS →
security review (reqs 3, 4, 8, 9) → docs/ADR + requirements matrix updated → `TODO.md` updated → commits via `split-commits` (user approves commits).

## Agents and skills
- Agents (`.claude/agents/`): `ansible-engineer` (implements), `k8s-verifier` (checks live cluster), `security-reviewer` (reviews), `docs-writer` (docs).
- Skills (`.claude/skills/`): `milestone` (orchestrates a milestone end to end), `vm-lifecycle`, `provision`, `verify-requirement`, `pin-version`, `new-role`, `bug`, `split-commits` (turns uncommitted work into focused commits).
- A PostToolUse hook lints every YAML file the agent edits (`.claude/hooks/lint-changed.sh`); fix what it reports before moving on.

## Known gotchas
- Lima forwards ports by watching listening sockets: Traefik must use `hostNetwork` to bind 443; CNI `hostPort` (iptables DNAT) is invisible to Lima.
- Lima's user network is 192.168.5.0/24 → pod CIDR is 10.244.0.0/16, not Calico's default.
- kubeadm binds etcd/scheduler/controller-manager metrics to 127.0.0.1; Prometheus needs `listen-metrics-urls`/`bind-address` changed.
- Audit "every request": the policy must not contain `level: None` rules; rotate the log (`audit-log-maxage/maxbackup/maxsize`).
- `.local` names on macOS go through mDNS first; the `/etc/hosts` entry is required.
- The CA is generated on the host and reused across VM rebuilds, so the committed `certs/ca.crt` stays valid.
- Debian 13 trixie: check package names/versions with `apt-cache madison` on the VM before pinning.
