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

# Pinned host tooling (ansible-core, ansible-lint, yamllint) lives in .venv on
# Python 3.14 and takes precedence over Homebrew's copies, which run on Python
# 3.15, unsupported by ansible-core 2.21 (B-001).
PYTHON       ?= python3.14
VENV         := $(ROOT)/.venv
VENV_STAMP   := $(VENV)/.installed
export PATH  := $(VENV)/bin:$(PATH)

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---------------------------------------------------------------- host deps
COLLECTIONS_STAMP := $(ANSIBLE_DIR)/collections/.installed

.PHONY: deps
deps: ## Install host tools: Lima + Python 3.14 (Homebrew), pinned venv, collections, git hooks
	brew install lima python@3.14
	$(MAKE) tools hooks

.PHONY: tools
tools: venv collections ## Pinned Python tooling (.venv) + pinned Ansible collections

.PHONY: hooks
hooks: ## Enable the repo's git hooks (.githooks/commit-msg)
	git config core.hooksPath .githooks

.PHONY: venv
venv: $(VENV_STAMP) ## Create .venv (Python 3.14) with the tools pinned in requirements.txt

$(VENV_STAMP): $(ROOT)/requirements.txt
	@command -v $(PYTHON) >/dev/null || { echo "$(PYTHON) not found: brew install python@3.14"; exit 1; }
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install --quiet --upgrade pip
	$(VENV)/bin/pip install --quiet -r $<
	@touch $@

.PHONY: collections
collections: $(COLLECTIONS_STAMP) ## Install pinned Ansible collections into ansible/collections

# --force: a plain install skips collections that any ansible on the machine
# already bundles (e.g. Homebrew's), so the pins would be ignored (B-002).
# The stamp makes this re-run only when requirements.yml changes.
$(COLLECTIONS_STAMP): $(ANSIBLE_DIR)/requirements.yml | $(VENV_STAMP)
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
provision: tools ## Run site.yml (TAGS=os_prep,containerd to limit)
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(if $(TAGS),--tags $(TAGS),) $(ANSIBLE_ARGS)

.PHONY: idempotency
idempotency: tools ## Re-run site.yml and fail unless changed=0
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(if $(TAGS),--tags $(TAGS),) $(ANSIBLE_ARGS) \
	  | tee /dev/stderr | grep -Eq 'changed=0 +unreachable=0 +failed=0'

.PHONY: check
check: tools ## Syntax-check the playbook
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml --syntax-check

# ---------------------------------------------------------------- quality
.PHONY: lint
lint: tools ## yamllint + ansible-lint + shellcheck (if installed)
	yamllint -s .
	cd $(ANSIBLE_DIR) && ansible-lint
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh .claude/hooks/*.sh .githooks/*; else echo "shellcheck not installed, skipping"; fi

# ---------------------------------------------------------------- verification
.PHONY: verify
verify: ## Run requirement checks (REQ=4 for one; STRICT=1 makes SKIP fail)
	$(ROOT)/scripts/verify.sh $(if $(filter 1,$(STRICT)),--strict,) $(REQ)

.PHONY: e2e
e2e: ## Full run from a clean VM; any FAIL or SKIP fails it
	$(MAKE) vm-reset
	$(MAKE) provision
	$(MAKE) idempotency
	$(MAKE) verify STRICT=1

.PHONY: smoke
smoke: ## The acceptance curl from the assignment
	curl --fail --cacert $(ROOT)/certs/ca.crt https://llm.local/v1/chat/completions \
	  -H 'Content-Type: application/json' \
	  -d '{"messages":[{"role":"user","content":"Say hello"}]}'
