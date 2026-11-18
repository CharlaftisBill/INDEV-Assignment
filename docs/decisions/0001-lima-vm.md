# 0001 — Lima for the VM

Status: Accepted (M1) · Date: 2026-11-17

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
- The image is a dated build (`debian_image_build`) pinned by sha512, not `latest`, so rebuilds are reproducible.
- Only TCP 443/80/6443 are forwarded. A catch-all ignore rule (`guestIP 0.0.0.0`, `guestIPMustBeZero: false`, `proto: any`) stops Lima auto-forwarding other guest listeners, including loopback and UDP (B-025, B-028).
- Intel hosts would use the amd64 image entry; untested.
