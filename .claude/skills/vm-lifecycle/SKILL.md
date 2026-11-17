---
name: vm-lifecycle
description: Create, start, stop, reset or destroy the Lima VM "k8s" (Debian 13, 4 CPU, 8 GiB, 40 GiB) used by this project, and check that Ansible can reach it. Use when the VM is not running, when a "clean VM" run is needed, or when SSH/Ansible connectivity fails.
---

# Lima VM lifecycle

Config: `lima/k8s.yaml`. Instance name: `k8s`. Ansible connects through `~/.lima/k8s/ssh.config` (host alias `lima-k8s`).

| Want | Command | Notes |
|---|---|---|
| Status | `limactl list` | `Running` / `Stopped` / missing |
| Create + start | `make vm-up` | Creates if missing; mounts `./backups` → `/mnt/host-backups` (rw) |
| Stop | `make vm-down` | Ask the user first if the cluster is in use |
| Clean VM | `make vm-reset` | **Destructive**: deletes the VM and recreates it. Always ask the user first |
| Destroy | `make vm-destroy` | **Destructive**. Always ask the user first |
| Shell | `limactl shell k8s` | Run single commands with `limactl shell k8s -- sudo <cmd>` |

## After create/start, confirm reachability
```bash
limactl list k8s
make ping                       # Ansible reachability, using the pinned .venv tools
limactl shell k8s -- cat /etc/os-release | grep VERSION_CODENAME   # expect trixie
limactl shell k8s -- nproc; limactl shell k8s -- free -g; limactl shell k8s -- df -h /
```
Prefer the make targets (`make ping`, `make provision`): they use the pinned `.venv` tools and are pre-approved. To run
`ansible` yourself: `source .venv/bin/activate && cd ansible` (ansible.cfg and the inventory path are relative to `ansible/`).

## Troubleshooting
- `limactl start` hangs on "Waiting for ssh": `limactl shell k8s` / check `~/.lima/k8s/ha.stderr.log` and `serial*.log`.
- Port 443 not reachable from the Mac: `lsof -nP -iTCP:443 -sTCP:LISTEN` on the host; in the guest the listener must be a real socket (`ss -ltnp | grep 443`), see the Lima gotcha in `CLAUDE.md`.
- Mount missing: `limactl shell k8s -- findmnt /mnt/host-backups`. The mount is set at create time; changing it needs `make vm-reset` (ask first).
