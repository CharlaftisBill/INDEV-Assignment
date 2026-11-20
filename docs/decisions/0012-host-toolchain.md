# 0012 — Pinned host tools inside the repo (`make doctor`, `deps`, `uninstall`)

Status: Accepted · Date: 2026-11-20

## Context
A user should need only `make` to clone and run this project.

Before, `make deps` ran `brew install lima python@3.14` and assumed kubectl, jq, curl, openssl and gh were there.
Nothing checked them first (`jq` is needed by verify checks 3b, 6 and 9). Shared system copies also broke things:
- Homebrew moved its Ansible to Python 3.15, which ansible-core 2.21 does not support (B-001).
- A plain `ansible-galaxy collection install` skipped collections another Ansible already bundled (B-002, fixed with `--force`).
- A system `kubectl` drifts from the cluster (v1.36 on this Mac; the cluster is v1.35).

And nothing could undo what the project installed.

## Decision
1. **Pinned, checked binaries in `.tools/`** (gitignored), downloaded by `scripts/host-tools.sh`: Python 3.14
   (python-build-standalone), kubectl (same minor as the cluster), jq, Lima and shellcheck.
   `.venv` (ansible-core, ansible-lint, yamllint) is built on that Python from `requirements.txt`, a full lock with
   hashes (B-046). Top-level pins are in `requirements.in`.
2. **One home for versions**: flat `host_*` keys in `ansible/group_vars/all/versions.yml` (a version, plus one sha256
   per OS and CPU). They are read with `awk`, so no YAML parser is needed before Python exists.
3. **Host needs**: `make`, `curl`, `tar`, `git`, `openssl`, `sudo`. macOS and Linux, arm64 and amd64 are detected.
   Not supported: Windows, and Intel macOS (the locked cryptography 50 has no Intel macOS build; building it needs Rust).
4. **`make doctor`** is read-only. For each tool and host setting (`/etc/hosts`, port forwarding, QEMU on Linux,
   VM state) it prints OK, MISSING or WRONG VERSION, and the fix. It ignores system copies and says so.
   `make verify` and `make e2e` run a quiet subset that prints only problems.
5. **`make deps`** installs only what doctor finds missing, and shows the plan first. Steps that need sudo
   (`/etc/hosts`; on Linux, QEMU and `net.ipv4.ip_unprivileged_port_start=80`) need a `y`. Without one they are
   skipped, and doctor keeps reporting them.
6. **Install record**: system-wide changes (Linux only: newly installed packages, the sysctl and its old value) go to
   `.tools/system-manifest`. `make uninstall` reverts only what it lists, so it never removes your own tools.
7. **`make uninstall`** asks before each step. `DRY_RUN=1` only lists, `YES=1` says yes to every step.
   `.secrets/` goes only with `PURGE_SECRETS=1`, with a warning: a new CA replaces the committed `certs/ca.crt` (B-037).
   A kept system entry keeps the manifest (B-047). Full list: [install guide](../install.md#uninstall).
8. **Lima 2.3.0**, the version that created the existing VM. The VM was restarted with the repo's `limactl` and
   checked unchanged.

## Details
- GNU make 3.81 (macOS) runs a recipe line without shell characters with its **own** original `PATH`, ignoring the
  exported one. So such lines name the tool by path (`$(LIMACTL)`, `$(VENV)/bin/yamllint`). Before this, `make lint`
  and `make collections` could run Homebrew's copies.
- `.tools/bin/limactl` is a symlink; Lima finds `share/lima` through the real path.

## Alternatives
| Option | Why not |
|---|---|
| Homebrew or distro packages | Not pinned, shared with other projects (unsafe to uninstall), caused B-001 |
| `uv` for Python | One more binary to pin; a direct download with a sha256 is simpler |
| Separate host pins file | Easier to parse, but splits versions over two files |

## Consequences
- The first `make deps` downloads about 150 MB (about 290 MB in `.tools/`, 75 MB in `.venv/`). Later runs do nothing.
- Version bumps go through `pin-version` (four sha256 values per tool).
- Commands typed outside make use system tools unless you set `PATH` ([install guide](../install.md#using-the-tools-outside-make)).
- A running VM's Lima process runs from `.tools/`. Uninstall deletes the VM before `.tools/`, and warns if you keep the VM.
- Not removed by uninstall: Homebrew `lima` and `python@3.14` from the old `make deps`, `~/.lima/_config`, Lima's
  image cache (other VMs share them).
- Linux paths (QEMU, sysctl, `lima/k8s.yaml` without `vz` and virtiofs) are untested; see [install](../install.md#linux-untested).
