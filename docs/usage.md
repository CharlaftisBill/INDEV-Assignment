# Daily use

Run all commands from the repo root. `make help` lists every target.

## Commands

| Command | What it does |
|---|---|
| `make doctor` | Checks the host tools (changes nothing) |
| `make deps` | Installs missing host tools ([install guide](install.md)) |
| `make vm-up` / `make vm-down` | Starts / stops the VM |
| `make vm-shell` | Opens a shell in the VM (same as `limactl shell k8s`) |
| `make vm-reset` | Deletes the VM and makes a clean one. **Destroys the cluster** |
| `make provision` | Runs the Ansible playbook. `TAGS=<role>` runs one role |
| `make idempotency` | Runs the playbook again and fails if anything changed |
| `make verify` | Runs the requirement checks. `REQ=<id>` for one, `STRICT=1` to fail on SKIP |
| `make smoke` | Sends the test question to `https://llm.local` |
| `make lint` | yamllint, ansible-lint, bug tracker format, shellcheck |
| `make e2e` | Clean VM → provision → all checks |
| `make uninstall` | Removes what make installed ([install guide](install.md#uninstall)) |

Requirement IDs: `1 2 3a 3b 4 5 6 7 8a 8b 8c 9` ([requirements](requirements-matrix.md)).
Roles: see [provisioning order](architecture.md#provisioning-order).

## Admin access

`make provision` writes the admin kubeconfig to `out/admin.conf`. It points at `https://127.0.0.1:6443`
(Lima forwards that port to the VM). It does not touch `~/.kube/config`, so pass it each time:

```bash
kubectl --kubeconfig out/admin.conf get nodes
```

Or set it once per shell:

```bash
export KUBECONFIG=$PWD/out/admin.conf
```

This file is full cluster-admin access. Don't share or commit it (`out/` is gitignored).
After a VM rebuild, `make provision` writes it again.
Lost it on a running node? See [troubleshooting](runbooks/troubleshooting.md#lost-adminconf).

## Read-only access

`out/operator.conf` can read most things but no Secrets, and cannot change anything:

```bash
kubectl --kubeconfig out/operator.conf get pods -A
```

Renew or revoke it: [operator kubeconfig runbook](runbooks/operator-kubeconfig.md).

## Web pages

Both need the `/etc/hosts` line ([install guide](install.md#other-changes-it-makes)).
Their certificates are signed by `certs/ca.crt`.

| URL | What |
|---|---|
| `https://llm.local` | llama.cpp API (OpenAI-style `/v1/chat/completions`) |
| `https://grafana.local` | Grafana dashboards, user `admin` ([password](runbooks/grafana.md)) |

`make chat` is a terminal chat with the model: it streams replies and keeps the conversation history.
`/reset` clears the history; `/quit` or Ctrl-D exits.

## Files to keep private

All are gitignored. Never print or share them.

| Path | Holds |
|---|---|
| `.secrets/` | CA key, cluster CAs and ServiceAccount keys (`kubeadm-pki/`), operator key, Grafana password |
| `out/` | admin and operator kubeconfigs |
| `backups/` | etcd snapshots. They contain every Kubernetes Secret |
