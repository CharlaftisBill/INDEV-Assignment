# Install and uninstall

Everything the project needs on the Mac goes into this folder. Nothing is installed system-wide,
except one line in `/etc/hosts`, and `make deps` asks before it adds it.

## What you need

- An **Apple Silicon Mac** (tested), or a Linux host (arm64 or amd64, see [Linux](#linux-untested)).
- `make`, `curl`, `tar`, `git`, `openssl` and `sudo`. `xcode-select --install` gives you all of them on a Mac.

Not supported:
- **Intel Macs.** A locked Python package (cryptography 50) has no Intel macOS build.
- **Windows.**

### Linux (untested)

`lima/k8s.yaml` sets no VM type or mount type, so Lima picks QEMU with 9p on Linux (vz with virtiofs on macOS).
The config is portable, but no Linux host was available, so this path is **untested**. On Linux, `make deps`
asks for sudo to:
- install QEMU packages for Lima;
- set `net.ipv4.ip_unprivileged_port_start=80` so Lima can forward 443 and 80. This lowers the limit **host-wide**
  for every user. It is asked first and reverted by `make uninstall`.

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

- **`/etc/hosts`** (asks for sudo): adds `127.0.0.1 llm.local grafana.local # indev-k8s`.
  Same as `scripts/hosts-entry.sh --apply`. macOS needs this line because `.local` names go to mDNS first.
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
- the VM, and the `/etc/hosts` line;
- what `.tools/system-manifest` lists (Linux packages and sysctl). If you keep one, the manifest stays;
- `.tools/`, `.venv/`, `.ansible/`, `ansible/collections/`;
- `out/` (kubeconfigs) and `backups/*` (etcd snapshots; `.gitkeep` stays);
- the `core.hooksPath` git setting.

**Kept** unless you add `PURGE_SECRETS=1`: `.secrets/` (the CA key, and the cluster CAs that let old etcd snapshots
restore onto a new VM). Without the CA key, the next provision stops (B-037)
until you restore the key or delete `certs/ca.crt` to create a new CA (then commit and trust the new one). See
[troubleshooting](runbooks/troubleshooting.md#fresh-clone-fails-in-pki-cert-without-key).

**Never touched**: tools you installed yourself, `~/.lima/_config`, and Lima's image cache (other VMs share them).
Older versions of `make deps` used Homebrew `lima` and `python@3.14`. Remove them with
`brew uninstall lima python@3.14` if nothing else needs them.
