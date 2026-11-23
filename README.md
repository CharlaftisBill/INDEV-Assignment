# INDEV assignment: single-node Kubernetes

Ansible turns a clean Debian 13 VM into a one-node Kubernetes cluster: a Lima VM it creates on your Mac or Linux
machine, or [a VM you already have](#quick-start-with-your-own-debian-13-vm).
At the end, a small language model (llama.cpp) answers over HTTPS:

```bash
curl --cacert certs/ca.crt https://llm.local/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello"}]}'
```

> **Status:** all milestones (M1–M10) are done. `make e2e` builds the cluster from a destroyed VM and every requirement check passes (313 PASS, 0 FAIL, 0 SKIP, 2026-11-20).
> Your own Debian 13 VM over SSH: all checks pass on a stand-in VM reached only over SSH (2026-11-22), also air-gapped: no internet or DNS (2026-11-23).
> Progress: [TODO.md](TODO.md). Bugs: [bugs.md](docs/ai-workflow/bugs.md). Assumptions: [assumptions.md](docs/assumptions.md).

## Quick start

Two ways to get the VM: **Lima** (default: created for you, steps below) or **a Debian 13 VM you already have**, over SSH ([steps](#quick-start-with-your-own-debian-13-vm)).

Supported hosts: Apple Silicon Mac (tested); Linux amd64 with QEMU/KVM (tested on Ubuntu 24.04); Linux arm64 (untested).
You need `make`; on a Mac run `xcode-select --install` if you don't have it.
Details: [install guide](docs/install.md).

**1. Install the tools** (into this folder only; asks before it uses `sudo`):

```bash
git clone https://github.com/CharlaftisBill/INDEV-Assignment.git
cd INDEV-Assignment

make doctor     # shows what is missing (changes nothing)
make deps       # installs it (skips Lima and QEMU when you use your own VM)
make doctor     # everything should be OK now
```

**2. Build the cluster.** A fresh clone has `certs/ca.crt` but not its key, so `make provision` asks first:
stop and restore the original key to `.secrets/ca.key` (mode 0600), or create your own local CA
(it deletes `certs/ca.crt`; `curl --cacert certs/ca.crt` then uses your new certificate). Without a terminal it stops.
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
| Grafana | `https://grafana.local`, user `admin` ([password](docs/runbooks/grafana.md)); needs the `/etc/hosts` lines (`scripts/hosts-entry.sh --apply`) |
| Prometheus, Alertmanager | `make monitoring-ui`, then `http://localhost:9090` and `http://localhost:9093`; Ctrl-C stops it. No login, so local port-forward only, no Ingress |

**5. Chat with the model** (optional):

```bash
make chat         # streams replies, keeps history; /reset clears it, /quit or Ctrl-D exits
```

`make e2e` does all of this on a fresh VM. `make uninstall` removes it again. `make help` lists every command.

## Quick start with your own Debian 13 VM

Already have a VM? Point the project at it over SSH instead of letting it create a Lima VM.
Everything else (Ansible, checks, `https://llm.local` on your machine) works the same.
**The VM may be air-gapped:** it needs no internet or DNS of its own, only SSH from your machine, which must be online.

**What the VM needs**

- A **fresh** Debian 13 (trixie), amd64 or arm64, 4 CPU, 8 GiB RAM, 40 GiB disk (≥ 20 GiB free), an IPv4 default
  route (kubeadm needs one; internet behind it is not needed).
  No Docker, containerd or Kubernetes on it already: the playbook installs and owns them.
- SSH with a key (no password prompt), as a user with **passwordless sudo** (or as `root`), and `python3`.
- An address outside the cluster ranges `10.244.0.0/16` and `10.96.0.0/12`.

Not set up yet? On the VM, as root (replace `debian` with your user):

```bash
apt-get install -y sudo python3
echo 'debian ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-indev && chmod 440 /etc/sudoers.d/90-indev
```

and from your machine: `ssh-copy-id debian@<vm-address>`.

**Run it** in the clone from step 1. Create the config before `make deps`, so Lima and QEMU are skipped.
The CA question (step 2) and the web UIs (step 4) are the same as above.

```bash
cp external-vm.conf.example external-vm.conf   # gitignored: set host=, user=, and port=/ssh_key= if needed
make deps         # host tools, without Lima/QEMU; asks before sudo (/etc/hosts line)
make vm-up        # checks SSH, sudo, Debian 13, CPU/RAM/disk, addresses; opens the tunnels; tests downloads (creates nothing)
make provision    # run Ansible against your VM; a second run changes nothing
make verify       # all requirement checks
make smoke        # the curl above
```

**What is different from Lima**

- **Internet for the VM** (`egress=` in `external-vm.conf`). By default (`host`) the VM's downloads (packages, images,
  charts, helm, etcdctl) go through your machine: an SSH reverse tunnel to a small proxy that relays HTTPS only, and
  only to the pinned sources in [`scripts/egress-allowlist.txt`](scripts/egress-allowlist.txt). Your machine downloads
  the model itself and copies it in, so the `llm` namespace has no egress at all. Got a proxy for the VM? Set
  `egress=proxy` and `proxy=http://…`. The VM has internet? `egress=direct`.
- **Ports.** `make vm-up` opens an SSH tunnel so your machine's `127.0.0.1` ports 443, 80 and 6443 reach the VM, as Lima's
  forwards do. Only connections from your machine are accepted. `make verify`, `smoke`, `chat` and `monitoring-ui`
  reopen it when needed; `make vm-down` (or `make tunnel-stop`) closes it and leaves the VM running. Stop a running
  Lima VM first (`limactl stop k8s`), since it holds the same ports.
- **Backups.** No folder is shared from your machine, so the VM writes snapshots to `/var/backups/etcd` and your
  machine pulls them into `./backups/external` every 30 minutes while the tunnel is up (`make backups-pull` pulls at once).
- **Your VM, your call.** `make vm-destroy`, `vm-reset`, `e2e` and `uninstall` never delete or reset it.
  To start over, reinstall Debian 13.
- To go back to Lima: `make tunnel-stop`, delete `external-vm.conf`, `make vm-up` (it also stops a tunnel left running).

Details and troubleshooting: [install guide](docs/install.md#your-own-debian-13-vm-over-ssh-instead-of-lima).

## Documentation

Start at the [docs index](docs/README.md). The most used pages:

- [Install and uninstall](docs/install.md)
- [Daily use](docs/usage.md): commands, kubeconfigs, Grafana, Prometheus, Alertmanager
- [Architecture](docs/architecture.md) and [versions](docs/versions.md)
- [Requirements](docs/requirements-matrix.md): what each requirement needs and how it is checked
- [Decisions](docs/decisions/) and [runbooks](docs/runbooks/)
- [How this was built with Claude Code](docs/ai-workflow/README.md)
