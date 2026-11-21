# INDEV assignment: single-node Kubernetes

Ansible turns a clean Debian 13 VM on a Mac into a one-node Kubernetes cluster.
At the end, a small language model (llama.cpp) answers over HTTPS:

```bash
curl --cacert certs/ca.crt https://llm.local/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello"}]}'
```

> **Status:** all milestones (M1–M10) are done. `make e2e` builds the cluster from a destroyed VM and every requirement check passes (313 PASS, 0 FAIL, 0 SKIP, 2026-11-20).
> Progress: [TODO.md](TODO.md). Bugs: [bugs.md](docs/ai-workflow/bugs.md). Assumptions: [assumptions.md](docs/assumptions.md).

## Quick start

Supported hosts: Apple Silicon Mac (tested); Linux arm64/amd64 with QEMU (config portable, untested).
You need `make`; on a Mac run `xcode-select --install` if you don't have it.
Details: [install guide](docs/install.md).

**1. Install the tools** (into this folder only; asks before it uses `sudo`):

```bash
git clone https://github.com/CharlaftisBill/INDEV-Assignment.git
cd INDEV-Assignment

make doctor     # shows what is missing (changes nothing)
make deps       # installs it
make doctor     # everything should be OK now
```

**2. Build the cluster.** A fresh clone has `certs/ca.crt` but not its key, so `make provision` stops in `pki`.
Either put the original key in `.secrets/ca.key` (mode 0600), or run `rm certs/ca.crt` to create your own CA
(then `curl --cacert certs/ca.crt` uses your new certificate).
See [troubleshooting](docs/runbooks/troubleshooting.md#fresh-clone-fails-in-pki-cert-without-key).

```bash
make vm-up        # create and start the VM (4 CPU, 8 GiB RAM, 40 GiB disk)
make provision    # run Ansible; a second run changes nothing
```

**3. Check it:**

```bash
kubectl --kubeconfig out/admin.conf get nodes
make verify       # all requirement checks
make smoke        # the curl above
```

**4. Open the web UIs** (optional):

| UI | How |
|---|---|
| Grafana | `https://grafana.local`, user `admin` ([password](docs/runbooks/grafana.md)); needs the `/etc/hosts` line (`scripts/hosts-entry.sh --apply`) |
| Prometheus, Alertmanager | `make monitoring-ui`, then `http://localhost:9090` and `http://localhost:9093`; Ctrl-C stops it. No login, so local port-forward only, no Ingress |

**5. Chat with the model** (optional):

```bash
make chat         # streams replies, keeps history; /reset clears it, /quit or Ctrl-D exits
```

`make e2e` does all of this on a fresh VM. `make uninstall` removes it again. `make help` lists every command.

## Documentation

Start at the [docs index](docs/README.md). The most used pages:

- [Install and uninstall](docs/install.md)
- [Daily use](docs/usage.md): commands, kubeconfigs, Grafana, Prometheus, Alertmanager
- [Architecture](docs/architecture.md) and [versions](docs/versions.md)
- [Requirements](docs/requirements-matrix.md): what each requirement needs and how it is checked
- [Decisions](docs/decisions/) and [runbooks](docs/runbooks/)
- [How this was built with Claude Code](docs/ai-workflow/README.md)
