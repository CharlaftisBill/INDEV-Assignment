# Single-node Kubernetes on a Lima VM, provisioned with Ansible.
# Run `make help` for the list of targets.

# Internal variables are `override` so `make <target> VAR=...` on the command line
# cannot replace them (they are pasted into shell recipe lines; B-019).
# Strict flags (-eu -o pipefail) live in the wrapper: make 3.81 ignores .SHELLFLAGS.
override SHELL        := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))/scripts/make-shell.sh
override .SHELLFLAGS  := -c
.DEFAULT_GOAL := help

override ROOT         := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
override LIMA_CONFIG  := $(ROOT)/lima/k8s.yaml
override BACKUP_DIR   := $(ROOT)/backups
override ANSIBLE_DIR  := $(ROOT)/ansible
override KUBECONFIG_ADMIN := $(ROOT)/out/admin.conf
# external-vm.conf (copy external-vm.conf.example) switches from the Lima VM to your own Debian 13 VM over SSH.
override EXTERNAL     := $(wildcard $(ROOT)/external-vm.conf)
override EXT          := $(ROOT)/scripts/external.sh
override INV          := $(if $(EXTERNAL),-i $(ANSIBLE_DIR)/inventory/external.yml,)
# Lima forwards host 443/80/6443 by itself; over SSH the same forwards come from a tunnel.
override TUNNEL       := $(if $(EXTERNAL),@$(EXT) tunnel start,@:)
# The VM is always air-gapped: its downloads go through the host's egress proxy over SSH while Ansible or verify run.
# Lima gets a generated conf for scripts/external.sh (its SSH port changes on every start).
override LIMA_EXT_CONF := $(ROOT)/.cache/lima-vm.conf
override EGRESS        = $(if $(EXTERNAL),@$(EXT) egress start,@$(ROOT)/scripts/lima-egress.sh $(VM) $(LIMACTL))

# User-settable variables (validated below)
VM           ?= k8s
TAGS         ?=
REQ          ?=
ANSIBLE_ARGS ?=
STRICT       ?=
DRY_RUN      ?= 0
PURGE_SECRETS ?= 0
NO_LIMA      ?= 0
KEEP_VM      ?= 0
YES          ?= 0

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
export PATH VM DRY_RUN PURGE_SECRETS YES NO_LIMA
# GNU make 3.81 (macOS) execs a recipe line without shell characters using its own, original PATH,
# so tools run that way are named by path; scripts and lines run by the shell see the PATH above.
override LIMACTL      := $(TOOLS)/bin/limactl

# ---------------------------------------------------------------- input validation (B-019, B-020)
# User-settable variables end up in recipe shell lines, so they may only contain characters
# that are inert in a shell. Checked in pure make on the raw, unexpanded text ($(value)),
# so a `$(shell ...)` or `;` payload is rejected before any shell runs. Helpers are `override`
# so the command line cannot redefine them. Not covered (make expands them before reading this
# file): `VAR:=$(shell ...)`, `--eval`, `-f`; hence only exact `make` commands are pre-approved (ADR 0009).
override USER_VARS := VM TAGS REQ ANSIBLE_ARGS STRICT PYTHON DRY_RUN PURGE_SECRETS YES NO_LIMA KEEP_VM
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
$(call check_chars,YES,0 1,0 or 1)
$(call check_chars,NO_LIMA,0 1,0 or 1)
$(call check_chars,KEEP_VM,0 1,0 or 1)
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
deps: ## Install only what is missing: pinned tools into .tools/, venv, collections, hooks (sudo steps ask; NO_LIMA=1 skips Lima+QEMU)
	@$(HOST_TOOLS) deps
	@$(MAKE) --no-print-directory -q $(VENV_STAMP) $(COLLECTIONS_STAMP) || $(MAKE) --no-print-directory tools
	@[ "$$(git config --get core.hooksPath)" = .githooks ] || $(MAKE) --no-print-directory hooks

.PHONY: uninstall
uninstall: ## Remove what make installed, asking per step (DRY_RUN=1 lists only; YES=1 no prompts; PURGE_SECRETS=1 also .secrets/)
	@$(HOST_TOOLS) uninstall

.PHONY: tools
tools: venv collections ## Pinned Python tooling (.venv) + pinned Ansible collections

.PHONY: hooks
hooks: ## Enable the repo's git hooks (.githooks: commit-msg, pre-commit)
	git config core.hooksPath .githooks

.PHONY: venv
venv: $(VENV_STAMP) ## Create .venv (Python 3.14) with the tools pinned in requirements.txt

# --clear: a new Python (pin bump, or the old Homebrew-based venv) gets a fresh venv.
# requirements.txt is a full lock with hashes (B-046); pip is the one bundled with the pinned Python.
$(VENV_STAMP): $(ROOT)/requirements.txt $(PYTHON_STAMP)
	$(PY) -m venv --clear $(VENV)
	$(VENV)/bin/pip install --quiet --disable-pip-version-check --require-hashes --only-binary=:all: -r $<
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
ifneq ($(EXTERNAL),)
.PHONY: vm-up vm-down vm-destroy vm-reset vm-shell
vm-up: ## (external VM) Check the VM from external-vm.conf (SSH, sudo, Debian 13, size), open the tunnel, test its downloads
	@mkdir -p $(BACKUP_DIR)
	@$(EXT) check
	@$(EXT) tunnel start
	@$(EXT) egress test
vm-down: ## (external VM) Close the tunnel; the VM itself keeps running
	@$(EXT) tunnel stop
vm-destroy vm-reset: ## (external VM) not available: the VM is yours
	@echo "external-vm.conf is set: this VM is yours, so make does not delete or reset it." >&2; echo "To rebuild, reinstall Debian 13 yourself, or remove external-vm.conf to use Lima." >&2; exit 1
vm-shell: ## (external VM) Open a root shell on the VM
	@$(EXT) shell
else
.PHONY: vm-up
vm-up: ## Create (if missing) and start the Lima VM
	@mkdir -p $(BACKUP_DIR)
	@if $(EXT) tunnel running; then echo "Stopping the tunnel left from external-vm.conf (it holds 443/80/6443)."; $(EXT) tunnel stop; fi
	@if ! $(LIMACTL) list --quiet | grep -x '$(VM)' >/dev/null; then \
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
endif

# ---------------------------------------------------------------- provisioning
.PHONY: provision
provision: tools ## Run site.yml (TAGS=os_prep,containerd to limit)
	@$(HOST_TOOLS) ca $(TAGS)
	$(EGRESS)
	cd $(ANSIBLE_DIR) && ansible-playbook $(INV) site.yml $(if $(TAGS),--tags $(TAGS),) $(ANSIBLE_ARGS)

.PHONY: idempotency
idempotency: tools ## Re-run site.yml and fail unless changed=0
	$(EGRESS)
	cd $(ANSIBLE_DIR) && ansible-playbook $(INV) site.yml $(if $(TAGS),--tags $(TAGS),) $(ANSIBLE_ARGS) \
	  | tee /dev/stderr | grep -E 'changed=0 +unreachable=0 +failed=0' >/dev/null

.PHONY: ping
ping: tools ## Check Ansible can reach the VM (fixed command; safe to auto-allow)
	cd $(ANSIBLE_DIR) && ansible $(INV) k8s -m ansible.builtin.ping

.PHONY: check
check: tools ## Syntax-check the playbook
	cd $(ANSIBLE_DIR) && ansible-playbook $(INV) site.yml --syntax-check

# ---------------------------------------------------------------- quality
.PHONY: lint
lint: tools ## yamllint + ansible-lint + bug tracker format + shellcheck (if installed)
	$(VENV)/bin/yamllint -s .
	$(VENV)/bin/python3 $(ROOT)/scripts/check_bugs.py $(ROOT)/docs/ai-workflow/bugs.md
	cd $(ANSIBLE_DIR) && ansible-lint
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh .claude/hooks/*.sh .githooks/*; else echo "shellcheck not installed, skipping"; fi

# ---------------------------------------------------------------- verification
.PHONY: verify
verify: ## Run requirement checks (REQ=4 for one; STRICT=1 makes SKIP fail)
	@$(HOST_TOOLS) preflight vm
	$(TUNNEL)
	$(EGRESS)
	$(ROOT)/scripts/verify.sh $(if $(filter 1,$(STRICT)),--strict,) $(REQ)

.PHONY: e2e
e2e: ## Full run from a clean VM; any FAIL or SKIP fails it. KEEP_VM=1: on the existing VM (required for a provided VM)
	@if [ -n '$(EXTERNAL)' ] && [ '$(KEEP_VM)' != 1 ]; then echo 'external-vm.conf is set: make e2e cannot recreate your VM. Run it on the VM as it is: make e2e KEEP_VM=1' >&2; exit 1; fi
	@$(HOST_TOOLS) preflight hosts
	@$(HOST_TOOLS) ca
	$(MAKE) $(if $(filter 1,$(KEEP_VM)),vm-up,vm-reset)
	$(MAKE) provision
	$(MAKE) idempotency
	$(MAKE) verify STRICT=1

.PHONY: monitoring-ui
monitoring-ui: ## Port-forward Prometheus (localhost:9090) and Alertmanager (localhost:9093) until Ctrl-C
	@$(HOST_TOOLS) preflight vm
	$(TUNNEL)
	@$(ROOT)/scripts/monitoring-ui.sh $(KUBECONFIG_ADMIN)

.PHONY: chat
chat: ## Chat with the model at llm.local in the terminal (/reset, /quit)
	@$(HOST_TOOLS) preflight vm
	$(TUNNEL)
	@$(ROOT)/scripts/chat.sh

.PHONY: smoke
smoke: ## The acceptance curl from the assignment
	$(TUNNEL)
	curl --fail --cacert $(ROOT)/certs/ca.crt https://llm.local/v1/chat/completions \
	  -H 'Content-Type: application/json' \
	  -d '{"messages":[{"role":"user","content":"Say hello"}]}'

# ---------------------------------------------------------------- external VM over SSH (external-vm.conf)
.PHONY: tunnel tunnel-stop backups-pull
tunnel: ## (external VM) Forward host 443/80/6443 to the VM like Lima does, plus egress and the 30-min snapshot pull
	@$(EXT) tunnel start

tunnel-stop: ## (external VM) Stop the forwards, the egress proxy and the snapshot pull
	@$(EXT) tunnel stop

backups-pull: ## (external VM) Copy the etcd snapshots from the VM into ./backups (keeps the newest 48)
	@$(EXT) backups-pull
