# INDEV assignment: single-node Kubernetes

This project builds a small Kubernetes cluster on **one virtual machine (VM)**, fully automated with Ansible.
When it is done, a small AI language model (llama.cpp with Qwen2.5-0.5B) answers you over a secure HTTPS connection:

```bash
curl --cacert certs/ca.crt https://llm.local/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello"}]}'
```

You can let the project **create the VM for you** (with Lima), or **use a Debian 13 VM you already have**.

> **Status:** everything is built and tested. One command (`make e2e`) deletes the VM, builds it again from scratch
> and runs all checks: all 315 pass, none fail or are skipped (2026-11-23).
> More: [progress](TODO.md) · [known bugs](docs/ai-workflow/bugs.md) · [how we read the assignment](docs/assumptions.md)

## What you get

- A one-node Kubernetes cluster: the same machine runs the control plane and the apps.
- Secure web access with certificates from our own certificate authority (CA), renewed automatically.
- Monitoring dashboards (Grafana) and alerts for node and etcd health (Prometheus, Alertmanager).
- A backup of the cluster database (etcd) every 30 minutes, kept outside the VM.
- Locked-down apps: no root, no extra privileges, only the network traffic they need, every API call logged.

### The VM never touches the internet

The VM is treated as **air-gapped**, whether Lima created it or you brought it:

- A firewall on the VM blocks every connection to the outside world.
- Everything it needs to download (packages, container images, charts) goes through **your computer**, over SSH,
  and only from a fixed list of trusted sources ([`scripts/egress-allowlist.txt`](scripts/egress-allowlist.txt)).
- Your computer downloads the AI model and copies it in.
- `make verify` proves it: it checks the firewall is on and that the VM cannot reach the internet by itself.

So your computer needs internet access; the VM does not.

## Before you start

- **Your computer:** an Apple Silicon Mac (tested) or Linux on Intel/AMD with KVM (tested on Ubuntu 24.04).
- **`make`:** on a Mac, run `xcode-select --install` if you don't have it. Everything else is installed for you.
- **Room for the VM:** 4 CPU cores, 8 GB of memory, 40 GB of disk.

More detail: [install guide](docs/install.md).

## Quick start with a provided Debian 13 VM

Already have a VM? The project can use it over SSH instead of creating one. Everything else works the same.

**Your VM needs:**

- A fresh **Debian 13** install (Intel/AMD or ARM) with 4 CPU cores, 8 GB of memory and 40 GB of disk.
  Nothing container-related on it yet: the project installs and manages that itself.
- **SSH login with a key** (no password prompt), as `root` or as a user who can `sudo` without a password.
- `python3` installed, and a default network route (no internet needed behind it).
- An address that is not inside `10.244.x.x` or `10.96.x.x` to `10.111.x.x` (the cluster uses those ranges).

**Step 0 (only if needed). Prepare the VM.** Log in to the VM as root and run (use your own user name instead
of `debian`):

```bash
apt-get install -y sudo python3
echo 'debian ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-indev && chmod 440 /etc/sudoers.d/90-indev
```

Then, from your computer, copy your SSH key to it: `ssh-copy-id debian@<vm-address>`.

**Step 1. Get the code and point it at your VM.**

```bash
git clone https://github.com/CharlaftisBill/INDEV-Assignment.git
cd INDEV-Assignment

cp external-vm.conf.example external-vm.conf
nano external-vm.conf   # set host= (the VM's address) and user=; port= and ssh_key= only if needed
```

**Step 2. Install the tools.** Tools go into this folder only. You are asked before anything needs `sudo`.
Because `external-vm.conf` exists, the software for creating a VM (Lima) is skipped.

```bash
make doctor     # shows what is missing (changes nothing)
make deps       # installs what is missing
make doctor     # now everything should say OK
```

**Step 3. Build the cluster.**

```bash
make vm-up        # checks your VM is ready and connects to it (it creates nothing)
make provision    # sets everything up with Ansible (safe to run again: a second run changes nothing)
```

The first time, `make provision` asks about the certificate key, the same as in the
[other quick start](#quick-start-the-project-creates-the-vm).

**Step 4. Check that it works.**

```bash
make verify       # runs every requirement check
make smoke        # sends the "Say hello" request above
```

**Step 5 (optional). Look around:** the same dashboards, chat and commands as in
[step 4 of the other quick start](#quick-start-the-project-creates-the-vm).

**Good to know:**

- **Connections:** `make vm-up` opens SSH tunnels, so `https://llm.local` on your computer reaches the VM.
  Only your own computer can use them. `make tunnel-stop` closes them (the VM keeps running).
  If the Lima VM is also running, stop it first (`limactl stop k8s`): both need the same ports.
- **Backups:** while the tunnels are open, your computer copies the VM's backups into `backups/external/`
  every 30 minutes. `make backups-pull` copies them right away.
- **Behind a proxy?** Add `egress=proxy` and `proxy=http://<proxy IP>:<port>` to `external-vm.conf`.
- **It's your VM:** the project never deletes or resets it. To start over, reinstall Debian 13.
- **Back to Lima:** run `make tunnel-stop`, delete `external-vm.conf`, then `make vm-up`.

Full details and troubleshooting: [install guide](docs/install.md#your-own-debian-13-vm-over-ssh-instead-of-lima).

## Quick start (the project creates the VM)

**Step 1. Get the code and install the tools.** Tools go into this folder only. You are asked before anything
needs `sudo`.

```bash
git clone https://github.com/CharlaftisBill/INDEV-Assignment.git
cd INDEV-Assignment

make doctor     # shows what is missing (changes nothing)
make deps       # installs what is missing
make doctor     # now everything should say OK
```

**Step 2. Build the cluster.**

```bash
make vm-up        # creates and starts the VM
make provision    # sets everything up with Ansible (safe to run again: a second run changes nothing)
```

The first time, `make provision` asks about the certificate key. The repository contains our CA certificate
(`certs/ca.crt`) but, for safety, not its secret key. You can either put the original key in `.secrets/ca.key`,
or let it create a new CA for you (then `certs/ca.crt` is replaced by yours).
[More about this choice](docs/runbooks/troubleshooting.md#fresh-clone-fails-in-pki-cert-without-key).

**Step 3. Check that it works.**

```bash
make verify       # runs every requirement check
make smoke        # sends the "Say hello" request above
```

**Step 4 (optional). Look around.**

| What | How |
|---|---|
| Grafana dashboards | Open `https://grafana.local`, user `admin` ([where the password is](docs/runbooks/grafana.md)) |
| Prometheus and Alertmanager | Run `make monitoring-ui`, then open `http://localhost:9090` and `http://localhost:9093`. Ctrl-C stops it |
| Chat with the model | Run `make chat`. `/reset` starts over, `/quit` exits |
| Kubernetes itself | `kubectl --kubeconfig out/admin.conf get pods -A` |

**Handy commands:** `make help` lists everything. `make e2e` does steps 2 and 3 from a clean VM (Lima only).
`make uninstall` removes what the project installed.

## Keep these private

These folders are never committed to git. Don't share them:

- `.secrets/`: the CA key and other keys
- `out/`: the admin login for the cluster (`admin.conf`)
- `backups/`: the cluster backups (they contain every password stored in the cluster)

## Documentation

Start at the [documentation index](docs/README.md). Most used:

- [Install and uninstall](docs/install.md)
- [Daily use](docs/usage.md): commands, cluster access, dashboards
- [How it fits together](docs/architecture.md) and [exact versions](docs/versions.md)
- [Requirements](docs/requirements-matrix.md): how each one is built and checked
- [Design decisions](docs/decisions/) and [step-by-step guides](docs/runbooks/)
- [How this was built with Claude Code](docs/ai-workflow/README.md)
