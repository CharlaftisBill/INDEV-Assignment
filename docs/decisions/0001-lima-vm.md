# 0001 — Lima for the VM

Status: Proposed (accepted when implemented) · Date: 2026-11-17

## Context
The assignment needs one Debian 13 VM (4 vCPU, 8 GB, 40 GB) created with Vagrant, Lima or similar. The host is an Apple Silicon Mac.

## Decision
Use Lima with `vmType: vz` (Apple Virtualization.framework) and the official Debian 13 arm64 genericcloud image. The VM is defined in `lima/k8s.yaml`; Lima's built-in containerd is disabled so Ansible owns the runtime.

## Alternatives considered
- **Vagrant**: on Apple Silicon it needs a third-party provider (vagrant-qemu, or paid VMware/Parallels) and arm64 Debian 13 boxes are scarce.
- **UTM / plain QEMU**: no declarative config or SSH/port-forward integration out of the box.

## Consequences
- Native speed on arm64, one YAML file, SSH config generated for Ansible, port forwarding and host mounts built in.
- Lima forwards ports by watching listening sockets in the guest, so ingress must bind 443 directly (see 0003).
- Intel hosts would use the amd64 image entry; untested.
