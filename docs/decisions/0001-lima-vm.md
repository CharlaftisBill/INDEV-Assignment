# 0001 — Lima for the VM

Status: Accepted (M1) · Date: 2026-11-17

## Context
We need one Debian 13 VM (4 vCPU, 8 GB RAM, 40 GB disk) on an Apple Silicon Mac.
The assignment allows Vagrant, Lima or similar.

## Decision
Use Lima with Apple's own virtualization (`vmType: vz`) and the official Debian 13 arm64 cloud image.

> **Amended (M10, 2026-11-20):** `lima/k8s.yaml` no longer sets `vmType`/`mountType`; Lima's defaults pick vz + virtiofs on macOS (same result) and QEMU + 9p on Linux.
> **Amended (2026-11-22):** tested on Linux amd64. x86_64 uses Debian's `generic` image (its kernel has 9p); virtiofs on QEMU puts guest RAM in `/dev/shm` and locked up the VM (B-058).
The VM is defined in `lima/k8s.yaml`. Lima's built-in containerd is off, so Ansible installs the runtime itself.

## Details
- The image is a fixed, dated build checked by sha512 (never `latest`), so every rebuild is the same.
- Lima forwards only TCP 443, 80 and 6443. A catch-all ignore rule stops it from forwarding any other port the VM
  opens, including loopback and UDP ports (B-025, B-028).

> **Amended (2026-11-22):** a reviewer can bring their own Debian 13 VM instead: `external-vm.conf` switches Ansible
> and the checks to it over SSH, an SSH tunnel plus a loopback-only forwarder stands in for Lima's ports, and snapshots
> are pulled with `make backups-pull` ([install guide](../install.md#your-own-debian-13-vm-over-ssh-instead-of-lima)).
> Lima stays the default and the only path `make e2e` covers, since it can recreate the VM.
> **Amended (2026-11-23):** every VM, Lima's included, is air-gapped (firewall from `os_prep`): its downloads go through the reviewer's machine (SSH reverse
> tunnel to an allowlisting proxy) and the model is copied in ([install guide](../install.md#internet-access-from-the-vm)).
> One exception: NTP (udp/123) to pinned server IPs (Google Public NTP by default, `ntp=` for your own), so the clock syncs (B-094).

## Alternatives
| Option | Why not |
|---|---|
| Vagrant | Needs a third-party provider on Apple Silicon; few arm64 Debian 13 boxes |
| UTM or plain QEMU | No config file, no built-in SSH or port forwarding |

## Consequences
- Fast (native arm64), one YAML file, SSH config for Ansible, port forwarding and folder sharing built in.
- Lima forwards a port only when a process listens on it in the VM. So the ingress must listen on a real port
  ([ADR 0003](0003-traefik-ingress.md)).
- Intel hosts would need the amd64 image. Not tested.
