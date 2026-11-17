# Single-node Kubernetes on a Lima VM, provisioned with Ansible.
# Run `make help` for the list of targets.

SHELL        := /bin/bash
.SHELLFLAGS  := -eu -o pipefail -c
.DEFAULT_GOAL := help

ROOT         := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VM           ?= k8s
LIMA_CONFIG  := $(ROOT)/lima/k8s.yaml
BACKUP_DIR   := $(ROOT)/backups
ANSIBLE_DIR  := $(ROOT)/ansible
KUBECONFIG_ADMIN := $(ROOT)/out/admin.conf

TAGS         ?=
REQ          ?=
ANSIBLE_ARGS ?=

export ANSIBLE_CONFIG := $(ANSIBLE_DIR)/ansible.cfg

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---------------------------------------------------------------- host deps
COLLECTIONS_STAMP := $(ANSIBLE_DIR)/collections/.installed

.PHONY: deps
deps: ## Install host tools (Homebrew) and pinned Ansible collections
	brew install lima ansible ansible-lint yamllint
	$(MAKE) collections hooks

.PHONY: hooks
hooks: ## Enable the repo's git hooks (.githooks/commit-msg)
	git config core.hooksPath .githooks

.PHONY: collections
collections: $(COLLECTIONS_STAMP) ## Install pinned Ansible collections into ansible/collections

# --force: Homebrew's ansible bundles its own copies of these collections, and
# without it galaxy skips the install ("already installed") and the pins are ignored.
# The stamp makes this re-run only when requirements.yml changes.
$(COLLECTIONS_STAMP): $(ANSIBLE_DIR)/requirements.yml
	ansible-galaxy collection install --force -r $< -p $(ANSIBLE_DIR)/collections
	@touch $@

# ---------------------------------------------------------------- VM lifecycle
.PHONY: vm-up
vm-up: ## Create (if missing) and start the Lima VM
	@mkdir -p $(BACKUP_DIR)
	@if ! limactl list --quiet | grep -qx '$(VM)'; then \
	  limactl create --tty=false --name=$(VM) \
	    --set '.mounts=[{"location":"$(BACKUP_DIR)","mountPoint":"/mnt/host-backups","writable":true}]' \
	    $(LIMA_CONFIG); \
	fi
	limactl start --tty=false $(VM)

.PHONY: vm-down
vm-down: ## Stop the Lima VM
	limactl stop $(VM)

.PHONY: vm-destroy
vm-destroy: ## Delete the Lima VM (destructive)
	limactl delete --force $(VM)

.PHONY: vm-reset
vm-reset: vm-destroy vm-up ## Destroy and recreate a clean VM

.PHONY: vm-shell
vm-shell: ## Open a shell in the VM
	limactl shell $(VM)

# ---------------------------------------------------------------- provisioning
.PHONY: provision
provision: ## Run site.yml (TAGS=os_prep,containerd to limit)
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(if $(TAGS),--tags $(TAGS),) $(ANSIBLE_ARGS)

.PHONY: idempotency
idempotency: ## Re-run site.yml and fail unless changed=0
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(if $(TAGS),--tags $(TAGS),) $(ANSIBLE_ARGS) \
	  | tee /dev/stderr | grep -Eq 'changed=0 +unreachable=0 +failed=0'

.PHONY: check
check: ## Syntax-check the playbook
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml --syntax-check

# ---------------------------------------------------------------- quality
.PHONY: lint
lint: ## yamllint + ansible-lint + shellcheck (if installed)
	yamllint -s .
	cd $(ANSIBLE_DIR) && ansible-lint
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh .claude/hooks/*.sh .githooks/*; else echo "shellcheck not installed, skipping"; fi

# ---------------------------------------------------------------- verification
.PHONY: verify
verify: ## Run requirement checks (REQ=4 for one requirement)
	$(ROOT)/scripts/verify.sh $(REQ)

.PHONY: e2e
e2e: vm-reset provision idempotency verify ## Full run from a clean VM

.PHONY: smoke
smoke: ## The acceptance curl from the assignment
	curl --fail --cacert $(ROOT)/certs/ca.crt https://llm.local/v1/chat/completions \
	  -H 'Content-Type: application/json' \
	  -d '{"messages":[{"role":"user","content":"Say hello"}]}'
