# Install and uninstall

Everything the project needs on the Mac goes into this folder. Nothing is installed system-wide,
except two lines in `/etc/hosts`, and `make deps` asks before it adds them.

## What you need

- An **Apple Silicon Mac** (tested), or a Linux host with KVM: amd64 tested on Ubuntu 24.04, arm64 untested (see [Linux](#linux)).
- With [your own Debian 13 VM](#your-own-debian-13-vm-over-ssh-instead-of-lima) over SSH, the host still runs Ansible but needs no Lima, QEMU or KVM.
- `make`, `curl`, `tar`, `git`, `openssl` and `sudo`. `xcode-select --install` gives you all of them on a Mac.

Not supported:
- **Intel Macs.** A locked Python package (cryptography 50) has no Intel macOS build.
- **Windows.**

### Linux

`lima/k8s.yaml` sets no VM type or mount type, so Lima picks QEMU with 9p on Linux (vz with virtiofs on macOS).
x86_64 uses Debian's `generic` image, whose kernel has 9p (the `genericcloud` one does not). virtiofs is avoided
on QEMU: Lima backs guest RAM with `/dev/shm`, too small for 8 GiB on a 16 GiB host (B-058).
Tested on Ubuntu 24.04 amd64 (`make provision`, `changed=0`, all 12 checks strict PASS, `make smoke`);
Linux arm64 is untested and would also need the `generic` image. Your user needs `/dev/kvm` access. `make deps`
asks for sudo to:
- install QEMU packages for Lima;
- set `net.ipv4.ip_unprivileged_port_start=80` so Lima can forward 443 and 80. This lowers the limit **host-wide**
  for every user. It is asked first and reverted by `make uninstall`.

## Your own Debian 13 VM over SSH (instead of Lima)

Lima stays the default. When `external-vm.conf` exists at the repo root, every `make` command uses the VM it names
instead (`ansible/inventory/external.yml`, `scripts/external.sh`). To go back to Lima: `make tunnel-stop`, delete the
file, `make vm-up` (it stops a tunnel left running; `make doctor` flags one).
Short version: [README](../README.md#quick-start-with-a-provided-debian-13-vm).

### The VM

| Needs | Why | Checked by |
|---|---|---|
| Fresh Debian 13, amd64 or arm64 | Packages and images are pinned for it; the playbook owns containerd and Kubernetes | `make vm-up`, playbook preflight |
| 4 CPU, 8 GiB RAM, 40 GiB disk (≥ 20 GiB free) | The assignment's size; images, the model and Prometheus need the space | `make vm-up`, playbook preflight |
| SSH with a key, `BatchMode` (no password prompt) | Ansible and the checks run unattended | `make vm-up` |
| Passwordless sudo, or log in as `root` | Ansible `become`; root needs no sudo | `make vm-up` |
| `python3` | Ansible modules | `make vm-up` |
| IPv4 default route | kubeadm picks the node address from it. Internet behind it is optional: [internet access](#internet-access-from-the-vm) | `make vm-up` |
| Address outside `10.244.0.0/16` and `10.96.0.0/12` | Pod and Service ranges (`ansible/group_vars/all/main.yml`) | `make vm-up` |

The playbook changes the VM like it changes the Lima one: swap off, kernel modules and sysctls, held apt packages,
containerd, kubeadm. It does not change the hostname, users or SSH. Prepare a plain install (as root, your user instead of `debian`):

```bash
apt-get install -y sudo python3
echo 'debian ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-indev && chmod 440 /etc/sudoers.d/90-indev
```

Then copy your key from the host: `ssh-copy-id debian@<vm-address>`.

### external-vm.conf

```bash
cp external-vm.conf.example external-vm.conf   # gitignored
```

One `key=value` per line, no trailing comments:

| Key | Default | Meaning |
|---|---|---|
| `host` | (required) | VM address or name |
| `user` | (required) | SSH user; `root` skips sudo |
| `port` | `22` | SSH port |
| `ssh_key` | your ssh agent / `~/.ssh` keys | Private key file |
| `backup_dir` | `/var/backups/etcd` | Where the VM keeps etcd snapshots |
| `egress` | `host` | Where the VM's downloads go: `host` or `proxy` ([below](#internet-access-from-the-vm)) |
| `proxy` | | Your proxy URL, with `egress=proxy` |

The host key is accepted on first use (`StrictHostKeyChecking=accept-new`) and checked after that.

### Commands

The usual ones work: `make deps` (no Lima or QEMU while the file exists; `make deps NO_LIMA=1` before creating it),
`make doctor`, `make vm-up`, `make provision`, `make idempotency`, `make verify`, `make smoke`, `make chat`,
`make monitoring-ui`. Differences:

| Command | With your own VM |
|---|---|
| `make vm-up` | Creates nothing. Checks the table above, opens the tunnels, tests that the VM can download |
| `make provision`, `make idempotency` | Open the egress tunnel first (`egress=host`); host ports 443/80/6443 are not needed |
| `make vm-down` | Closes the tunnel; the VM keeps running |
| `make vm-shell` | Root shell on the VM over SSH |
| `make tunnel` / `make tunnel-stop` | Start / stop the tunnels (ports, and egress for `egress=host`) and the 30-min [snapshot pull](#backups) |
| `make backups-pull` | Copy new VM snapshots into `./backups/external` now (the loop does it every 30 min) |
| `make vm-destroy`, `make vm-reset`, `make e2e` | Refuse: they would need to delete your VM. Run `make provision`, `make idempotency`, `make verify STRICT=1` instead |
| `make uninstall` | Leaves the VM and its cluster alone; closes the tunnel |

### Internet access from the VM

The VM is always air-gapped, Lima's and yours: `os_prep` installs a firewall (nftables table `inet indev_airgap`,
unit `indev-airgap`) that lets it reach only itself, the node IP, the pod and Service ranges (and your proxy, with
`egress=proxy`). `make verify` (check 1) proves it cannot open a connection to the internet. Its downloads go through:

| `egress=` | The VM's downloads | Needs |
|---|---|---|
| `host` (default) | Through your machine, over SSH | Your machine online; the VM's sshd allows forwarding (`AllowTcpForwarding`, Debian's default) |
| `proxy` | Through your proxy, `proxy=http://<IPv4>:<port>` (an address: the VM has no DNS) | That proxy reaches the sources below |

With `host` (the only mode for Lima; `make provision`, `idempotency` and `verify` open the tunnel through Lima's SSH
port, `scripts/lima-egress.sh`):
- `ssh -R` maps the VM's `127.0.0.1:18128` to `scripts/egress-proxy.py` on your machine (`127.0.0.1:18128`).
  It relays `CONNECT` to port 443 (TLS stays end to end) and plain `http://` on port 80, only to hosts in
  [`scripts/egress-allowlist.txt`](../scripts/egress-allowlist.txt): Debian, Kubernetes packages, helm, GitHub
  releases, the four chart repositories, and the image registries with their CDNs. Everything else is refused.
- Each decision is logged to `$TMPDIR/indev-k8s-ext-<uid>.egress.log`. A pin that moves to a new CDN shows up there as
  `DENY <host>`: add the host to the allowlist; the proxy reloads it at once.
- The VM needs no DNS: the proxy resolves names on your machine.

Ansible sets the proxy for apt (`/etc/apt/apt.conf.d/95indev-proxy`), containerd (systemd
drop-in) and its own tasks (helm, `get_url`). `NO_PROXY` keeps node, pod and Service traffic direct. Pods get no
proxy and no internet. The model is the one download a pod used to make, so instead your machine downloads it into
`.cache/models/` (sha256-pinned, kept for rebuilds) and Ansible copies it into the model volume. The `llm` namespace
then has no egress policy at all, not even DNS.

`make vm-up` ends with a download test from the VM (`scripts/external.sh egress test`).

### Ports: the tunnel

Lima forwards the host's `127.0.0.1` ports 443, 80 and 6443 to the VM's 8443, 8000 (Traefik) and 6443 (API server).
Here an SSH tunnel does the same, so `https://llm.local`, `https://grafana.local` and `out/admin.conf` work unchanged:

- `ssh -L` forwards `127.0.0.1:6443` and two high loopback ports, `18443` and `18000`, to the VM.
- `scripts/loopback-forward.py` serves 443 and 80 from those. macOS lets a normal user bind ports below 1024 only on
  the wildcard address, so it listens there and drops every connection that does not come from this machine
  (Lima does the same). On Linux, `make deps` sets `net.ipv4.ip_unprivileged_port_start=80` for it, as for Lima.
- Nothing else on the VM is reachable from the host; the VM's own firewall and SSH settings are yours.

`make vm-up` opens it; `make verify`, `smoke`, `chat` and `monitoring-ui` reopen it if it is down. It fails when
ports 443, 80, 6443, 18443, 18000 or (with `egress=host`) 18128 are taken, most often by a running Lima VM: `limactl stop k8s`.

### Backups

Requirement 7 wants snapshots outside the cluster. With Lima they land in `./backups` on the host through a shared
folder. Your VM has no such folder and is air-gapped, so it cannot send them: its timer writes them to
`backup_dir` on the VM, and **this machine pulls them** into `./backups/external` every 30 minutes (B-063).
- The pull runs in a background loop that starts and stops with the tunnel (`make vm-up`, `make tunnel`, and the
  `verify`/`smoke`/`chat` targets start it; `make tunnel-stop` stops it). Log: `.cache/backups-pull.log`. Not launchd
  or systemd: macOS keeps launchd jobs out of `~/Desktop`, `~/Documents` and `~/Downloads`, where a clone often lives.
- Each pull fetches only snapshots it does not have yet, only names like `etcd-snapshot-<UTC>.db` and regular files,
  stored as 0600 in a 0700 folder; it keeps the newest 48 (the VM's own retention). Lima's `./backups` is never touched.
- Stopping the loop (`make tunnel-stop`) also stops a pull in progress and waits for it.
- `make verify` (check 7) fails when the loop is not running or no host copy of the VM's snapshots is under an hour
  old, before it pulls once itself.
- Like the tunnel, the loop does not survive a reboot of this machine; `make vm-up` starts it again. Until then, new
  snapshots wait on the VM: [assumptions](assumptions.md).

## Install

```bash
make doctor   # read-only: each tool is OK, MISSING or WRONG VERSION, with the fix
make deps     # installs only what is missing; shows the plan first; asks before sudo
```

Run `make deps` again and it installs nothing. Why it works this way: [ADR 0012](decisions/0012-host-toolchain.md).

### Tools it installs

All downloads are pinned and checked by sha256. Versions live in the `host_*` keys of
[`versions.yml`](../ansible/group_vars/all/versions.yml).

| Tool | Version | Goes to | Used for |
|---|---|---|---|
| Python | 3.14.10 | `.tools/` | runs Ansible and the linters |
| Lima (`limactl`) | 2.3.0 | `.tools/` | creates and runs the VM |
| kubectl | v1.35.10 | `.tools/` | talks to the cluster (same version as the cluster) |
| jq | 1.8.2 | `.tools/` | used by `make verify` |
| shellcheck | 0.11.0 | `.tools/` | used by `make lint` |
| ansible-core, ansible-lint, yamllint | 2.21.6, 26.10.1, 1.38.0 | `.venv/` | runs the playbook, lint |
| Ansible collections | see [`requirements.yml`](../ansible/requirements.yml) | `ansible/collections/` | Kubernetes, crypto and system modules |

Python packages come from [`requirements.in`](../requirements.in), locked with hashes in `requirements.txt`.
`gh` (GitHub CLI) is optional and not installed.

### Other changes it makes

- **`/etc/hosts`** (asks for sudo): adds `127.0.0.1 llm.local grafana.local # indev-k8s` and the same line for `::1`.
  Same as `scripts/hosts-entry.sh --apply`. macOS needs both: `.local` names go to mDNS first, and without the `::1`
  line the IPv6 lookup waits 5 s on mDNS (B-059). Where nothing listens on `::1:443`, clients are refused at once and
  fall back to 127.0.0.1, so the extra line costs nothing on Linux.
- **Git hooks**: sets `core.hooksPath` to `.githooks`. See [git workflow](ai-workflow/git-workflow.md).
- **Linux only** (asks for sudo): installs QEMU for Lima, and sets `net.ipv4.ip_unprivileged_port_start=80`
  so Lima can forward ports 443 and 80. Both are recorded in `.tools/system-manifest`.

### Using the tools outside make

Every `make` command uses `.tools/bin` and `.venv/bin` first. Other copies (Homebrew, distro) are ignored.
To get the same tools in your own shell:

```bash
export PATH=$PWD/.tools/bin:$PWD/.venv/bin:$PATH
```

## Uninstall

```bash
make uninstall DRY_RUN=1   # only list the steps
make uninstall             # asks y/N before each step
make uninstall YES=1       # runs every step without asking (sudo may still ask for your password)
```

It removes only what `make` created:
- the Lima VM (never a VM from `external-vm.conf`: only its tunnels are closed), and the `/etc/hosts` lines;
- what `.tools/system-manifest` lists (Linux packages and sysctl). If you keep one, the manifest stays;
- `.tools/`, `.venv/`, `.ansible/`, `ansible/collections/`;
- `out/` (kubeconfigs) and `backups/*` (etcd snapshots; `.gitkeep` stays);
- the `core.hooksPath` git setting.

**Kept** unless you add `PURGE_SECRETS=1`: `.secrets/` (the CA key, and the cluster CAs that let old etcd snapshots
restore onto a new VM). Without the CA key, the next `make provision` asks (B-037): restore the key, or
create a new local CA (deletes `certs/ca.crt`; trust the new one). See
[troubleshooting](runbooks/troubleshooting.md#fresh-clone-fails-in-pki-cert-without-key).

**Never touched**: tools you installed yourself, `~/.lima/_config`, and Lima's image cache (other VMs share them).
Older versions of `make deps` used Homebrew `lima` and `python@3.14`. Remove them with
`brew uninstall lima python@3.14` if nothing else needs them.
