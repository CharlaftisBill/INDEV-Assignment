# Single-node Kubernetes on a Lima VM, provisioned with Ansible.
# Run `make help` for the list of targets.

# Internal variables are `override` so `make <target> VAR=...` on the command line
# cannot replace them (they are pasted into shell recipe lines; B-019).
override SHELL        := /bin/bash
override .SHELLFLAGS  := -eu -o pipefail -c
.DEFAULT_GOAL := help

override ROOT         := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
override LIMA_CONFIG  := $(ROOT)/lima/k8s.yaml
override BACKUP_DIR   := $(ROOT)/backups
override ANSIBLE_DIR  := $(ROOT)/ansible
override KUBECONFIG_ADMIN := $(ROOT)/out/admin.conf

# User-settable variables (validated below)
VM           ?= k8s
TAGS         ?=
REQ          ?=
ANSIBLE_ARGS ?=
STRICT       ?=
DRY_RUN      ?= 0
PURGE_SECRETS ?= 0

override ANSIBLE_CONFIG := $(ANSIBLE_DIR)/ansible.cfg
export ANSIBLE_CONFIG

# Pinned host toolchain (ADR 0012): `make deps` downloads Python 3.14, kubectl, jq, Lima and
# shellcheck into .tools/ (sha256-checked, pins in versions.yml); ansible-core, ansible-lint and
# yamllint live in .venv on that Python. Both come first on PATH, so system copies (e.g. Homebrew's
# Python 3.15 build of ansible, B-001) are never used by make.
override TOOLS        := $(ROOT)/.tools
override HOST_TOOLS   := $(ROOT)/scripts/host-tools.sh
PYTHON       ?=
override PY   := $(or $(PYTHON),$(TOOLS)/bin/python3.14)
override PYTHON_STAMP := $(TOOLS)/python/.installed
override VENV         := $(ROOT)/.venv
override VENV_STAMP   := $(VENV)/.installed
override PATH         := $(TOOLS)/bin:$(VENV)/bin:$(PATH)
export PATH VM DRY_RUN PURGE_SECRETS
# GNU make 3.81 (macOS) execs a recipe line without shell characters using its own, original PATH,
# so tools run that way are named by path; scripts and lines run by the shell see the PATH above.
override LIMACTL      := $(TOOLS)/bin/limactl

# ---------------------------------------------------------------- input validation (B-019, B-020)
# User-settable variables end up in recipe shell lines, so they may only contain characters
# that are inert in a shell. Checked in pure make on the raw, unexpanded text ($(value)),
# so a `$(shell ...)` or `;` payload is rejected before any shell runs. Helpers are `override`
# so the command line cannot redefine them. Not covered (make expands them before reading this
# file): `VAR:=$(shell ...)`, `--eval`, `-f`; hence only exact `make` commands are pre-approved (ADR 0009).
override USER_VARS := VM TAGS REQ ANSIBLE_ARGS STRICT PYTHON DRY_RUN PURGE_SECRETS
override _cmdline_vars := $(foreach v,$(.VARIABLES),$(if $(filter command line,$(origin $(v))),$(v)))
$(if $(filter-out $(USER_VARS),$(_cmdline_vars)),$(error Only these variables can be set: $(USER_VARS); got: $(filter-out $(USER_VARS),$(_cmdline_vars))))
# Destructive targets run alone, so they can't ride along with a harmless one (`make verify vm-destroy`).
override DESTRUCTIVE := vm-down vm-destroy vm-reset e2e uninstall
$(if $(and $(filter $(DESTRUCTIVE),$(MAKECMDGOALS)),$(word 2,$(MAKECMDGOALS))),$(error $(filter $(DESTRUCTIVE),$(MAKECMDGOALS)) must be the only goal))

override empty  :=
override space  := $(empty) $(empty)
override comma  := ,
override _lower := a b c d e f g h i j k l m n o p q r s t u v w x y z
override _upper := A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
override _digit := 0 1 2 3 4 5 6 7 8 9
# $(call _strip_chars,TEXT,CHARS): TEXT with every char in the CHARS list removed
override _strip_chars = $(if $(2),$(call _strip_chars,$(subst $(firstword $(2)),,$(1)),$(wordlist 2,999,$(2))),$(1))
# $(call check_chars,VAR,ALLOWED CHARS,DESCRIPTION): error unless VAR has only allowed chars and spaces
override check_chars = $(if $(subst $(space),,$(call _strip_chars,$(value $(1)),$(2))),$(error $(1) may only contain $(3); got: $(value $(1))))
$(call check_chars,REQ,$(_digit) a b c,check IDs such as 2 8c)
$(call check_chars,TAGS,$(_lower) $(_digit) _ $(comma),role names separated by commas)
$(call check_chars,STRICT,0 1,0 or 1)
$(call check_chars,DRY_RUN,0 1,0 or 1)
$(call check_chars,PURGE_SECRETS,0 1,0 or 1)
$(call check_chars,VM,$(_lower) $(_digit) -,a Lima instance name)
$(call check_chars,PYTHON,$(_lower) $(_digit) . / - _,a python executable name or path)
$(call check_chars,ANSIBLE_ARGS,$(_lower) $(_upper) $(_digit) - _ = . / : $(comma) +,ansible-playbook flags without quotes or shell characters)

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---------------------------------------------------------------- host deps
override COLLECTIONS_STAMP := $(ANSIBLE_DIR)/collections/.installed

.PHONY: doctor
doctor: ## Check host tools and state (read-only): OK / MISSING / WRONG VERSION, with fixes
	@$(HOST_TOOLS) doctor

.PHONY: deps
deps: ## Install only what is missing: pinned tools into .tools/, venv, collections, hooks (sudo steps ask)
	@$(HOST_TOOLS) deps
	@$(MAKE) --no-print-directory -q $(VENV_STAMP) $(COLLECTIONS_STAMP) || $(MAKE) --no-print-directory tools
	@[ "$$(git config --get core.hooksPath)" = .githooks ] || $(MAKE) --no-print-directory hooks

.PHONY: uninstall
uninstall: ## Remove what make installed, asking per step (DRY_RUN=1 lists only; PURGE_SECRETS=1 also .secrets/)
	@$(HOST_TOOLS) uninstall

.PHONY: tools
tools: venv collections ## Pinned Python tooling (.venv) + pinned Ansible collections

.PHONY: hooks
hooks: ## Enable the repo's git hooks (.githooks: commit-msg, pre-commit)
	git config core.hooksPath .githooks

.PHONY: venv
venv: $(VENV_STAMP) ## Create .venv (Python 3.14) with the tools pinned in requirements.txt

# --clear: a new Python (pin bump, or the old Homebrew-based venv) gets a fresh venv.
$(VENV_STAMP): $(ROOT)/requirements.txt $(PYTHON_STAMP)
	$(PY) -m venv --clear $(VENV)
	$(VENV)/bin/pip install --quiet --upgrade pip
	$(VENV)/bin/pip install --quiet -r $<
	@touch $@

$(PYTHON_STAMP):
	@echo "Pinned Python 3.14 missing in .tools/: run make deps"; exit 1

.PHONY: collections
collections: $(COLLECTIONS_STAMP) ## Install pinned Ansible collections into ansible/collections

# --force: a plain install skips collections that any ansible on the machine
# already bundles (e.g. Homebrew's), so the pins would be ignored (B-002).
# The stamp makes this re-run only when requirements.yml changes.
$(COLLECTIONS_STAMP): $(ANSIBLE_DIR)/requirements.yml | $(VENV_STAMP)
	$(VENV)/bin/ansible-galaxy collection install --force -r $< -p $(ANSIBLE_DIR)/collections
	@touch $@

# ---------------------------------------------------------------- VM lifecycle
.PHONY: vm-up
vm-up: ## Create (if missing) and start the Lima VM
	@mkdir -p $(BACKUP_DIR)
	@if ! $(LIMACTL) list --quiet | grep -qx '$(VM)'; then \
	  $(LIMACTL) create --tty=false --name=$(VM) \
	    --set '.mounts=[{"location":"$(BACKUP_DIR)","mountPoint":"/mnt/host-backups","writable":true}]' \
	    $(LIMA_CONFIG); \
	fi
	$(LIMACTL) start --tty=false $(VM)

.PHONY: vm-down
vm-down: ## Stop the Lima VM
	$(LIMACTL) stop $(VM)

.PHONY: vm-destroy
vm-destroy: ## Delete the Lima VM (destructive)
	$(LIMACTL) delete --force $(VM)

.PHONY: vm-reset
vm-reset: vm-destroy vm-up ## Destroy and recreate a clean VM

.PHONY: vm-shell
vm-shell: ## Open a shell in the VM
	$(LIMACTL) shell $(VM)

# ---------------------------------------------------------------- provisioning
.PHONY: provision
provision: tools ## Run site.yml (TAGS=os_prep,containerd to limit)
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(if $(TAGS),--tags $(TAGS),) $(ANSIBLE_ARGS)

.PHONY: idempotency
idempotency: tools ## Re-run site.yml and fail unless changed=0
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(if $(TAGS),--tags $(TAGS),) $(ANSIBLE_ARGS) \
	  | tee /dev/stderr | grep -Eq 'changed=0 +unreachable=0 +failed=0'

.PHONY: ping
ping: tools ## Check Ansible can reach the VM (fixed command; safe to auto-allow)
	cd $(ANSIBLE_DIR) && ansible k8s -m ansible.builtin.ping

.PHONY: check
check: tools ## Syntax-check the playbook
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml --syntax-check

# ---------------------------------------------------------------- quality
.PHONY: lint
lint: tools ## yamllint + ansible-lint + TODO.md bug format + shellcheck (if installed)
	$(VENV)/bin/yamllint -s .
	$(VENV)/bin/python3 $(ROOT)/scripts/check_todo.py $(ROOT)/TODO.md
	cd $(ANSIBLE_DIR) && ansible-lint
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh .claude/hooks/*.sh .githooks/*; else echo "shellcheck not installed, skipping"; fi

# ---------------------------------------------------------------- verification
.PHONY: verify
verify: ## Run requirement checks (REQ=4 for one; STRICT=1 makes SKIP fail)
	@$(HOST_TOOLS) preflight vm
	$(ROOT)/scripts/verify.sh $(if $(filter 1,$(STRICT)),--strict,) $(REQ)

.PHONY: e2e
e2e: ## Full run from a clean VM; any FAIL or SKIP fails it
	@$(HOST_TOOLS) preflight hosts
	$(MAKE) vm-reset
	$(MAKE) provision
	$(MAKE) idempotency
	$(MAKE) verify STRICT=1

.PHONY: smoke
smoke: ## The acceptance curl from the assignment
	curl --fail --cacert $(ROOT)/certs/ca.crt https://llm.local/v1/chat/completions \
	  -H 'Content-Type: application/json' \
	  -d '{"messages":[{"role":"user","content":"Say hello"}]}'
