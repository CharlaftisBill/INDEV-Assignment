# CLAUDE.md — INDEV single-node Kubernetes assignment

Build a single-node kubeadm cluster on a local Debian 13 VM **with Ansible, from a clean VM**,
ending in a llama.cpp server reachable at `https://llm.local` over TLS from the Mac.
The assignment is `k8s-single-node-assignment.pdf`. Project state and bugs: **`TODO.md` (read it first, update it last).**

## Requirements (details + verification in `docs/requirements-matrix.md`; check IDs `1 2 3a 3b 4 5 6 7 8a 8b 8c 9`)
1. OS prep, containerd runtime, **pinned** package versions
2. kubeadm, one node = control plane + workloads
3. CNI (Calico) [3a, M3]; app pods accept only the traffic they need (NetworkPolicy) [3b, M9]
4. Ingress (Traefik) + TLS from an internal CA we create, renewed automatically (cert-manager)
5. Default StorageClass (local-path-provisioner)
6. Prometheus + Grafana; alerts for node health and etcd health firing in Alertmanager
7. Scheduled etcd snapshots stored **outside the cluster** (host `./backups` via Lima mount)
8. Hardening: read-only operator role + operator kubeconfig [8a, M8]; app pods non-root/unprivileged [8b, M9]; every API request audited [8c, M2]
9. llama.cpp + Qwen2.5-0.5B-Instruct GGUF Q4 on CPU, via ingress/TLS, no model re-download on pod restart

## Environment
- Host: Apple Silicon Mac. VM: Lima instance `k8s` (`lima/k8s.yaml`, vz, arm64, Debian 13, 4 CPU / 8 GiB / 40 GiB).
- Ansible runs **on the Mac** and pushes over SSH (`ansible/ansible.cfg` uses `~/.lima/k8s/ssh.config`, host alias `lima-k8s`).
- Shell in VM: `limactl shell k8s`. Admin kubeconfig (after M2): `out/admin.conf` → `kubectl --kubeconfig out/admin.conf ...`.
- Host-forwarded ports: 443, 80, 6443 only. `/etc/hosts` on the Mac maps `llm.local grafana.local` to 127.0.0.1 (`scripts/hosts-entry.sh`).

## Commands
- `make help` · `make deps` · `make tools` (pinned `.venv` on Python 3.14 + collections; all make targets use it — run ansible/ansible-lint outside make via `source .venv/bin/activate`, never Homebrew's copies) · `make vm-up` / `vm-down` / `vm-reset` (destructive) / `vm-shell`
- `make provision [TAGS=role]` · `make idempotency [TAGS=role]` (fails unless `changed=0`) · `make check`
- `make hooks` (enable `.githooks/`) · `make lint` · `make verify [REQ="2 8c"] [STRICT=1]` (STRICT: SKIP fails) · `make smoke` (the acceptance curl) · `make e2e` (clean VM → all green)

## Hard rules
- **Versions**: every version/tag/digest lives in `ansible/group_vars/all/versions.yml`, with a source+date comment. Never `latest`, never unpinned apt installs; hold apt packages (`dpkg_selections: hold`). Images must have an arm64 manifest. Use the `pin-version` skill.
- **Ansible style**: FQCN modules (`ansible.builtin.*`, `kubernetes.core.*`); prefer modules over `command`/`shell`; when unavoidable, set `creates:`/`removes:` or `changed_when:`. Templates in `roles/<r>/templates/`, defaults in `defaults/main.yml`. Each role has a tag equal to its name in `site.yml`.
- **Idempotency**: a second `make provision` must report `changed=0`. Not optional.
- **Kubernetes objects** are applied with `kubernetes.core.k8s` / `kubernetes.core.helm` from Ansible, never by hand. Manual `kubectl` is for inspection only.
- **Secrets**: CA key in `.secrets/`, kubeconfigs in `out/`, etcd snapshots (which contain every Secret) in `backups/`; all gitignored, only `certs/ca.crt` is committed. Never read secret material. How `.claude/settings.json` enforces it (precedence deny > ask > allow):
  - **allow-list**: `kubectl --kubeconfig out/admin.conf get <kind>` runs without a prompt only for listed kinds (pods, nodes, events, certificates, networkpolicies, …; Secrets are not listed). **Put the kind right after `get`** (`get pods -n llm`, not `get -n llm pods`), otherwise it prompts. Node-side `kubectl get` is allowed for nodes and pods only. The operator kubeconfig is auto-allowed for `auth can-i` only (check 8a in `verify.sh` covers the rest).
  - **ask** (you approve each time): unlisted kinds (Secrets in any case), comma-separated kinds, `--raw`, a second `--kubeconfig` / `--kubeconfig=` / `KUBECONFIG=` / `--context` / `--user` / `--token` (kubectl uses the last one given), shell metacharacters (`;` `&` `|` `$(` backtick `>`) on a `limactl shell` line (they run in the VM's shell even when quoted locally), anything touching `/etc/kubernetes/pki/` or the CA-key directory (e.g. `openssl x509 -enddate` on a cert, `etcdctl endpoint health`, file-mode checks).
  - **deny** (cannot be approved): reading the secret files themselves: Read tool on `.secrets/`, `out/`, `backups/`; `cat`/`head`/`tail`/`less`/`more`/`base64`/`xxd` of the CA-key directory, `cat` of `out/`/`backups/`; `cat` of node `*.conf` and `pki/*.key`; `kubectl config view --raw`.
  - **Best effort** (ADR 0009: a guardrail against accidents, not a security boundary): these are pattern rules (e.g. `get pod -o yaml` can show env values; `python3 -c` reading a file isn't matched), so this rule is what actually applies. To check that a Secret exists, use `kubectl describe secret` (key names and sizes, not values).
- **Workload security**: everything in `app_namespaces` must pass PSA `restricted`: `runAsNonRoot`, `allowPrivilegeEscalation: false`, drop ALL caps, `seccompProfile: RuntimeDefault`, prefer `readOnlyRootFilesystem`. Every app namespace starts with default-deny ingress+egress NetworkPolicies.
- **Commits**: only through the `split-commits` skill, which groups changes into focused Conventional Commits (`feat(kubeadm): ...`). **Never add `Co-Authored-By: Claude`, "Generated with Claude Code" or any AI attribution** to commits or PRs; `.githooks/commit-msg` rejects them (enable with `make hooks`). Never `git add -A`, never push without asking.
- **Scope**: one role/milestone at a time. Don't touch roles outside the current milestone without logging why in `TODO.md`.

## TODO.md protocol
- Read `TODO.md` before starting; update the Status line, milestone checkboxes and Bugs table before finishing.
- Bug states are only **Open** or **Solved**. IDs are sequential `B-NNN`, never reused or deleted.
- Format (defined in the `bug` skill, checked by `make lint`): a compact index table (`ID | Title | Sev | State | Milestone | Found | Solved | Fix`, titles ≤ ~100 chars, no evidence in cells) plus a `## Bug details` entry per bug of **at most 5 lines** (heading + one-line Report, Direction or Root cause/Fix/Verification).
- A bug becomes **Solved** only with the fixing commit hash (or `uncommitted` until committed) in the Fix column and a passing check.
- Verifier/reviewer agents (`k8s-verifier`, `sre-reviewer`, `security-reviewer`) only *open* bugs; review findings set the Sev column and only Critical/High/Medium are logged. Fixes go through the `fix-next-bug` skill (one bug per run, reproduce → root cause → fix → verify). Use the `bug` skill to keep the table format.
- A milestone can't be ticked while Open bugs exist for it or an earlier milestone. Open bugs for later milestones are *deferred*: tracked, not worked, until their milestone becomes current.
- Assumptions made where the PDF is unclear go under "Assumptions" in `TODO.md`.

## Definition of done (per milestone)
`make lint` clean → `make provision TAGS=...` OK → `make idempotency` `changed=0` → `make verify REQ="<IDs on the milestone line>" STRICT=1` PASS (no SKIP) →
`review-loop` clean (SRE review + tests, plus security review for reqs 3, 4, 8, 9, fixes re-reviewed until no new bugs) → docs/ADR + requirements matrix updated → `TODO.md` updated → commits via `split-commits` (user approves commits).

## Agents and skills
- Agents (`.claude/agents/`): `ansible-engineer` (implements), `k8s-verifier` (checks live cluster), `sre-reviewer` (senior SRE/DevOps: reviews changes and tests the infrastructure), `security-reviewer` (security deep-dive), `docs-writer` (docs).
- Skills (`.claude/skills/`): `milestone` (orchestrates a milestone end to end), `vm-lifecycle`, `provision`, `verify-requirement`, `pin-version`, `new-role`, `bug`, `fix-next-bug` (picks the next Open bug, reproduces, fixes, verifies, marks Solved), `review-loop` (sre-reviewer → fix-next-bug → re-review until a round finds nothing new; **max 2 rounds**, then ask the user), `split-commits` (turns uncommitted work into focused commits).
- A PostToolUse hook lints every YAML file the agent edits (`.claude/hooks/lint-changed.sh`); fix what it reports before moving on.

## Known gotchas
- Lima forwards ports by watching listening sockets: Traefik must use `hostNetwork` to bind 443; CNI `hostPort` (iptables DNAT) is invisible to Lima.
- Lima's user network is 192.168.5.0/24 → pod CIDR is 10.244.0.0/16, not Calico's default.
- kubeadm binds etcd/scheduler/controller-manager metrics to 127.0.0.1; Prometheus needs `listen-metrics-urls`/`bind-address` changed.
- Audit "every request": the policy must not contain `level: None` rules; rotate the log (`audit-log-maxage/maxbackup/maxsize`).
- `.local` names on macOS go through mDNS first; the `/etc/hosts` entry is required.
- The CA is generated on the host and reused across VM rebuilds, so the committed `certs/ca.crt` stays valid.
- Debian 13 trixie: check package names/versions with `apt-cache madison` on the VM before pinning.
