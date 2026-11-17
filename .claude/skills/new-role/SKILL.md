---
name: new-role
description: Scaffold a new Ansible role in ansible/roles/ following this project's conventions, wire it into site.yml with its tag, add a verify.sh check stub and a requirements-matrix row. Use when a milestone needs a role that doesn't exist yet.
---

# Scaffold a role

Argument: role name (snake_case, from the planned list in `ansible/site.yml`) and the requirement number(s) it serves.

## Files
```
ansible/roles/<role>/
├── defaults/main.yml     # role-local defaults; versions NOT here (versions.yml)
├── tasks/main.yml        # entry point; split into tasks/<topic>.yml and import when > ~80 lines
├── handlers/main.yml     # only if the role restarts services
├── templates/            # *.j2 (manifests, configs, helm values)
├── files/                # static files
└── meta/main.yml         # galaxy_info (author, description, min_ansible_version, platforms: Debian trixie), dependencies: []
```
Create only the directories the role actually uses (no empty `handlers/` if nothing restarts).

## Conventions to start from
```yaml
---
# tasks/main.yml — <one line: what this role does, which requirement>
- name: <Verb> <object>
  ansible.builtin.<module>:
    ...
```
- Task names start with a verb and are unique (ansible-lint `name[casing]`, `name[unique]`).
- Helm values go in `templates/values.yaml.j2`, rendered with `ansible.builtin.template` lookup into `kubernetes.core.helm: values:`.
- Manifests go in `templates/*.yaml.j2`, applied with `kubernetes.core.k8s: template:` and `state: present`.
- Kubernetes modules run on the node with `kubeconfig: /etc/kubernetes/admin.conf` (python3-kubernetes is installed by the kubeadm role).

## Wire it in
1. `ansible/site.yml`: move the commented line for the role into `roles:` (keep order), tag = role name.
2. `scripts/verify.sh`: make sure `check_<N>` exists; leave `skip "not implemented"` until the checks are written.
3. `docs/requirements-matrix.md`: set the Implementation column to `ansible/roles/<role>/`.
4. `make lint && make check`.
