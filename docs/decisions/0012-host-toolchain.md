# 0012: Repo-local pinned host toolchain (`make doctor`, `make deps`, `make uninstall`)

Status: Accepted · Date: 2026-11-20

## Context
A user should need only `make` to clone and run this project. Until now `make deps` ran `brew install lima python@3.14`
and assumed kubectl, jq, curl, openssl and gh were already installed; nothing checked them up front (`jq` is needed by
verify checks 3b, 6 and 9). System copies are not trustworthy here: Homebrew moved its Ansible to Python 3.15, which
broke ansible-core (B-001), and a system `kubectl` drifts from the cluster (v1.36 on this Mac, cluster is v1.35).
Nothing could undo what the project installs on the host.

## Decision
1. **Repo-local, pinned, sha256-checked binaries** in gitignored `.tools/`, downloaded by `scripts/host-tools.sh`:
   Python 3.14 (python-build-standalone `install_only_stripped`, relocatable), kubectl (cluster minor, v1.35.x),
   jq, Lima (release tarball; `.tools/bin/limactl` is a symlink, Lima finds `share/lima` through the real path) and
   shellcheck. `.venv` (ansible-core, ansible-lint, yamllint) is built on that Python from `requirements.txt`, a full
   lock with hashes (`--require-hashes --only-binary=:all:`, the Python's bundled pip; top-level pins in
   `requirements.in`, B-046). The Makefile puts `.tools/bin` and `.venv/bin` first on `PATH`.
   - GNU make 3.81 (macOS) execs a recipe line that has no shell characters with its *own* original `PATH`, ignoring
     the exported one, so such lines name the tool by path (`$(LIMACTL)`, `$(VENV)/bin/yamllint`). Before this, `make
     lint` and `make collections` could run Homebrew's yamllint / ansible-galaxy.
2. **Pins** are flat `host_*` keys in `ansible/group_vars/all/versions.yml` (version + one sha256 per
   `darwin|linux` × `arm64|amd64`), read with `awk`, so versions keep one home (CLAUDE.md) and no YAML parser
   is needed before Python exists. Ansible loads them as unused vars; harmless.
3. **Host assumptions**: `make` plus base OS tools (`curl`, `tar`, `git`, `openssl`, `sudo`). On macOS the Xcode
   Command Line Tools provide them. OS and CPU are detected (macOS/Linux, arm64/amd64). Windows is out of scope.
   Intel macOS is not supported: the locked cryptography 50 has no macOS x86_64 wheel, and building it needs Rust.
4. **`make doctor`** is read-only and prints OK / MISSING / WRONG VERSION with the fix for each tool and host setting
   (`/etc/hosts` entry, port 443 forwarding, QEMU on Linux, VM state); it ignores system copies and says so.
   `make verify` (`preflight vm`) and `make e2e` (`preflight hosts`) run a quiet subset that prints only problems.
5. **`make deps`** installs only what doctor finds missing and prints the plan first. Steps needing sudo
   (hosts line; on Linux QEMU packages and `net.ipv4.ip_unprivileged_port_start=80`) are shown and need a `y` on a
   terminal; without one they are skipped and doctor keeps reporting them.
6. **Install record**: system-wide changes (Linux only: packages that were not installed before, the sysctl file and
   its previous value) go to `.tools/system-manifest`. `make uninstall` reverts only what it lists, so tools the user
   installed themselves are never touched.
7. **`make uninstall`** asks before each step (VM, hosts line, manifest entries, `.tools/`, `.venv/`, `.ansible/`,
   `ansible/collections/`, `out/`, `backups/*` keeping `.gitkeep`, `core.hooksPath`); `DRY_RUN=1` lists only, `YES=1`
   answers yes to every step (no prompts; `.secrets/` still needs `PURGE_SECRETS=1`). A kept
   system entry keeps `.tools/system-manifest` (B-047).
   `.secrets/` only with `PURGE_SECRETS=1`, with the B-037 warning (a new CA replaces the committed `certs/ca.crt`).
8. **Lima 2.3.0**, the version that created the existing VM (`~/.lima/k8s/lima-version`): the VM was restarted
   with the repo-local `limactl` and verified unchanged.

## Alternatives
- **Homebrew / distro packages**: unpinned, shared with other projects (uninstall would be unsafe), and the cause of
  B-001. Rejected.
- **`uv` for Python**: one more binary to pin; a direct python-build-standalone download with its sha256 is simpler.
- **Separate host pins file**: cleaner to parse, but splits versions across two files; flat keys keep one home.

## Consequences
- First `make deps` downloads about 150 MB (about 290 MB unpacked in `.tools/`, 75 MB `.venv/`); later runs are no-ops. Pin bumps go through `pin-version`
  (four sha256 values per tool).
- Commands typed outside make use system tools unless the user runs `export PATH=$PWD/.tools/bin:$PWD/.venv/bin:$PATH`.
- A running VM's hostagent runs from `.tools/`; uninstall deletes the VM before `.tools/` and warns if the VM is kept.
- Not removed by uninstall: Homebrew `lima` / `python@3.14` from the old `make deps`, `~/.lima/_config` and Lima's
  image cache (shared with other Lima VMs).
- Linux paths (QEMU packages, sysctl, `lima/k8s.yaml` without `vz`/`virtiofs`) are untested; see the Linux Backlog item.
