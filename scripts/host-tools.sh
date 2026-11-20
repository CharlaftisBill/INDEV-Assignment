#!/usr/bin/env bash
# Host toolchain: check, install and remove what `make` needs on the host (ADR 0012).
#   scripts/host-tools.sh doctor              read-only report; exit 1 if anything required is missing
#   scripts/host-tools.sh preflight [vm|hosts] quiet doctor subset: only problems, exit 1 if any
#   scripts/host-tools.sh deps                install what is missing (pinned, sha256-checked) into .tools/
#   scripts/host-tools.sh uninstall           remove what make installed, asking per step (DRY_RUN=1, YES=1, PURGE_SECRETS=1)
# Pins: host_* keys in ansible/group_vars/all/versions.yml. Runs on macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
BIN="$TOOLS/bin"
MANIFEST="$TOOLS/system-manifest"   # system-wide changes made by `make deps`; uninstall reverts only these
PINS="$ROOT/ansible/group_vars/all/versions.yml"
VM="${VM:-k8s}"
HOSTS_MARKER="# indev-k8s"
SYSCTL_FILE="/etc/sysctl.d/99-indev-k8s.conf"
[[ -f "$ROOT/Makefile" && -f "$PINS" ]] || { echo "host-tools.sh: repo root not found" >&2; exit 1; }

case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;; esac
case "$(uname -m)" in arm64 | aarch64) ARCH=arm64 ;; x86_64 | amd64) ARCH=amd64 ;; *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;; esac

# ---------------------------------------------------------------- helpers
pin() {
  local v
  v="$(awk -v k="$1:" '$1 == k { v = $2; gsub(/"/, "", v); print v; exit }' "$PINS")"
  [[ -n "$v" ]] || { echo "Missing pin $1 in $PINS" >&2; exit 1; }
  printf '%s' "$v"
}
sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
is_tty() { [[ -t 0 && -t 1 ]]; }
confirm() {  # confirm "question" -> 0 on y/yes; never auto-yes without a terminal
  is_tty || { echo "    (no terminal: skipped, run it yourself)"; return 1; }
  local a; read -r -p "    $1 [y/N] " a
  [[ "$a" == y || "$a" == Y || "$a" == yes ]]
}

# Status line: status name detail [fix]. FAILS counts required problems.
FAILS=0
QUIET=0
report() {  # report STATUS REQUIRED(1/0) NAME DETAIL [FIX]
  local st="$1" req="$2" name="$3" detail="$4" fix="${5:-}"
  if [[ "$st" != OK && "$req" == 1 ]]; then FAILS=$((FAILS + 1)); fi
  if [[ "$QUIET" == 1 && ( "$st" == OK || "$req" == 0 ) ]]; then return 0; fi
  printf '  %-14s %-22s %s\n' "$st" "$name" "$detail"
  [[ -z "$fix" ]] || printf '  %-14s %-22s fix: %s\n' "" "" "$fix"
}

# ---------------------------------------------------------------- repo-local tools (.tools/bin)
TOOL_LIST="python kubectl jq limactl shellcheck"
tool_bin() { case "$1" in python) echo python3.14 ;; *) echo "$1" ;; esac; }
tool_pin_key() { case "$1" in limactl) echo lima ;; *) echo "$1" ;; esac; }
tool_want() { local v; v="$(pin "host_$(tool_pin_key "$1")_version")"; echo "${v#v}"; }
tool_required() { [[ "$1" != shellcheck ]]; }
tool_version() {  # version of a tool binary (path), or empty
  local b="$2"
  [[ -x "$b" ]] || return 0
  case "$1" in
    python) "$b" -c 'import platform; print(platform.python_version())' 2>/dev/null ;;
    kubectl) "$b" version --client 2>/dev/null | awk '/Client Version/ {sub(/^v/, "", $3); print $3}' ;;
    jq) "$b" --version 2>/dev/null | sed 's/^jq-//' ;;
    limactl) "$b" --version 2>/dev/null | awk '{print $3}' ;;
    shellcheck) "$b" --version 2>/dev/null | awk '/^version:/ {print $2}' ;;
  esac
  return 0
}
tool_ok() { [[ "$(tool_version "$1" "$BIN/$(tool_bin "$1")")" == "$(tool_want "$1")" ]]; }

check_tool() {
  local t="$1" b want have other req=0 note=""
  b="$(tool_bin "$t")"; want="$(tool_want "$t")"; have="$(tool_version "$t" "$BIN/$b")"
  tool_required "$t" && req=1
  if [[ "$have" == "$want" ]]; then report OK "$req" "$b" "$want (.tools/bin)"; return 0; fi
  other="$(PATH="$(path_without_tools || true)" command -v "$b" 2>/dev/null || true)"
  [[ -z "$other" ]] || note=", ignoring $other ($(tool_version "$t" "$other" || true))"
  if [[ -z "$have" ]]; then report MISSING "$req" "$b" "want $want in .tools/bin$note" "make deps"
  else report "WRONG VERSION" "$req" "$b" "have $have, want $want$note" "make deps"; fi
}
path_without_tools() { printf '%s' "$PATH" | tr ':' '\n' | grep -vx -e "$BIN" -e "$ROOT/.venv/bin" | paste -sd: -; }

# ---------------------------------------------------------------- other checks
check_base() {  # base OS tools the project assumes
  local t
  for t in curl tar git openssl; do
    if command -v "$t" >/dev/null; then report OK 1 "$t" "$(command -v "$t")"
    else report MISSING 1 "$t" "base OS tool" "$(pkg_hint "$t")"; fi
  done
}
pkg_hint() {
  if [[ "$OS" == darwin ]]; then echo "xcode-select --install"
  elif command -v apt-get >/dev/null; then echo "sudo apt-get install $1"
  elif command -v dnf >/dev/null; then echo "sudo dnf install $1"
  else echo "install $1 with your package manager"; fi
}
venv_ok() {
  local s="$ROOT/.venv/.installed"
  [[ -f "$s" && "$s" -nt "$ROOT/requirements.txt" && "$s" -nt "$TOOLS/python/.installed" ]] &&
    [[ "$(tool_version python "$ROOT/.venv/bin/python3")" == "$(tool_want python)" ]]
}
collections_ok() { local s="$ROOT/ansible/collections/.installed"; [[ -f "$s" && "$s" -nt "$ROOT/ansible/requirements.yml" ]]; }
hooks_ok() { [[ "$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null)" == .githooks ]]; }
hosts_ok() { grep -q "$HOSTS_MARKER" /etc/hosts 2>/dev/null; }
port_start() { cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024; }
port_ok() { [[ "$OS" == darwin ]] || [[ "$(port_start)" -le 80 ]]; }
qemu_pkgs() {  # distro packages Lima needs on Linux (printed, installed only with confirmation)
  if command -v apt-get >/dev/null; then
    if [[ "$ARCH" == arm64 ]]; then echo "qemu-system-arm qemu-efi-aarch64 qemu-utils"; else echo "qemu-system-x86 qemu-utils"; fi
  elif command -v dnf >/dev/null; then echo "qemu-kvm qemu-img"
  fi
}
qemu_ok() {
  [[ "$OS" == darwin ]] && return 0
  local q=qemu-system-x86_64; [[ "$ARCH" == arm64 ]] && q=qemu-system-aarch64
  command -v "$q" >/dev/null && command -v qemu-img >/dev/null
}
limactl_bin() { if [[ -x "$BIN/limactl" ]]; then echo "$BIN/limactl"; else command -v limactl 2>/dev/null || true; fi; }
vm_status() {
  local l; l="$(limactl_bin)"; [[ -n "$l" ]] || { echo absent; return 0; }
  local s; s="$("$l" list --format '{{.Status}}' "$VM" 2>/dev/null || true)"
  echo "${s:-absent}"
}

check_state() {  # check_state REQUIRE_VM(1/0) REQUIRE_HOSTS(1/0)
  local need_vm="$1" need_hosts="$2" st
  if hosts_ok; then report OK "$need_hosts" "/etc/hosts entry" "llm.local grafana.local -> 127.0.0.1"
  else report MISSING "$need_hosts" "/etc/hosts entry" "needed for https://llm.local" "make deps (or scripts/hosts-entry.sh --apply)"; fi
  if port_ok; then report OK 1 "port 443 forwarding" "$([[ $OS == darwin ]] && echo "macOS allows unprivileged binds" || echo "ip_unprivileged_port_start=$(port_start)")"
  else report MISSING 1 "port 443 forwarding" "net.ipv4.ip_unprivileged_port_start=$(port_start) (Lima can't bind 443/80)" "make deps (or sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80)"; fi
  if [[ "$OS" == linux ]]; then
    if qemu_ok; then report OK 1 "qemu" "$(command -v qemu-img)"
    else report MISSING 1 "qemu" "Lima needs QEMU on Linux" "make deps (or $(pkg_hint "$(qemu_pkgs)"))"; fi
  fi
  st="$(vm_status)"
  case "$st" in
    Running) report OK "$need_vm" "VM $VM" "Running" ;;
    absent) report MISSING "$need_vm" "VM $VM" "not created" "make vm-up" ;;
    *) report "$(printf '%s' "$st" | tr '[:lower:]' '[:upper:]')" "$need_vm" "VM $VM" "$st" "make vm-up" ;;
  esac
}

# ---------------------------------------------------------------- doctor / preflight
cmd_doctor() {
  echo "Host: $OS/$ARCH (repo-local tools in .tools/bin, first on PATH inside make)"
  echo "Pinned tools"
  local t; for t in $TOOL_LIST; do check_tool "$t"; done
  echo "Base OS tools"
  check_base
  echo "Project"
  if venv_ok; then report OK 1 ".venv" "requirements.txt on Python $(tool_want python)"
  else report MISSING 1 ".venv" "ansible-core, ansible-lint, yamllint" "make deps"; fi
  if collections_ok; then report OK 1 "ansible collections" "ansible/requirements.yml"
  else report MISSING 1 "ansible collections" "ansible/collections" "make deps"; fi
  if hooks_ok; then report OK 0 "git hooks" "core.hooksPath=.githooks"
  else report MISSING 0 "git hooks" "optional, for contributors" "make hooks"; fi
  echo "Host state"
  check_state 0 1
  echo "Optional"
  if command -v gh >/dev/null; then report OK 0 gh "$(command -v gh) (PRs only)"
  else report MISSING 0 gh "only needed to open PRs" "https://cli.github.com"; fi
  if [[ "$FAILS" -gt 0 ]]; then echo "$FAILS required item(s) missing. Run: make deps"; return 1; fi
  echo "All required items OK."
}

cmd_preflight() {  # preflight [vm] [hosts]
  QUIET=1
  local need_vm=0 need_hosts=0 a t
  for a in "$@"; do case "$a" in vm) need_vm=1 ;; hosts) need_hosts=1 ;; *) echo "preflight: unknown check $a" >&2; exit 2 ;; esac; done
  for t in $TOOL_LIST; do check_tool "$t"; done
  check_base
  check_state "$need_vm" "$need_hosts"
  if [[ "$FAILS" -gt 0 ]]; then echo "Preflight failed ($FAILS). Details: make doctor"; return 1; fi
}

# ---------------------------------------------------------------- deps
tool_asset() {  # url for tool $1 on this platform
  local v; v="$(pin "host_$(tool_pin_key "$1")_version")"
  local la=aarch64 ja="$ARCH" mo="$OS"
  [[ "$ARCH" == amd64 ]] && la=x86_64
  case "$1" in
    python)
      local triple="$la-apple-darwin"; [[ "$OS" == linux ]] && triple="$la-unknown-linux-gnu"
      echo "https://github.com/astral-sh/python-build-standalone/releases/download/$(pin host_python_build)/cpython-$v%2B$(pin host_python_build)-$triple-install_only_stripped.tar.gz" ;;
    kubectl) echo "https://dl.k8s.io/release/$v/bin/$OS/$ARCH/kubectl" ;;
    jq) [[ "$OS" == darwin ]] && mo=macos; echo "https://github.com/jqlang/jq/releases/download/jq-$v/jq-$mo-$ja" ;;
    limactl)
      local lo=Darwin lla="$ARCH"; [[ "$OS" == linux ]] && { lo=Linux; lla="$la"; }; [[ "$ARCH" == amd64 ]] && lla=x86_64
      echo "https://github.com/lima-vm/lima/releases/download/v$v/lima-$v-$lo-$lla.tar.gz" ;;
    shellcheck) echo "https://github.com/koalaman/shellcheck/releases/download/v$v/shellcheck-v$v.$OS.$la.tar.gz" ;;
  esac
}

install_tool() {  # download, verify, unpack into .tools
  local t="$1" url sha dl got
  url="$(tool_asset "$t")"; sha="$(pin "host_$(tool_pin_key "$t")_sha256_${OS}_$ARCH")"
  dl="$(mktemp -d "$TOOLS/.dl.XXXXXX")"
  echo "==> $t $(tool_want "$t"): $url"
  curl -fsSL --proto '=https' --retry 3 -o "$dl/asset" "$url"
  got="$(sha256_of "$dl/asset")"
  [[ "$got" == "$sha" ]] || { rm -rf "$dl"; echo "sha256 mismatch for $url: got $got, pinned $sha" >&2; exit 1; }
  case "$t" in
    kubectl | jq) chmod 0755 "$dl/asset"; mv -f "$dl/asset" "$BIN/$t" ;;
    shellcheck) tar -xzf "$dl/asset" -C "$dl"; mv -f "$dl"/shellcheck-v*/shellcheck "$BIN/shellcheck" ;;
    python)
      mkdir "$dl/x"; tar -xzf "$dl/asset" -C "$dl/x"
      rm -rf "$TOOLS/python"; mv "$dl/x/python" "$TOOLS/python"; touch "$TOOLS/python/.installed"
      ln -sfn ../python/bin/python3.14 "$BIN/python3.14" ;;
    limactl)  # limactl finds share/lima next to its real path, so a symlink in .tools/bin works
      mkdir "$dl/x"; tar -xzf "$dl/asset" -C "$dl/x"
      rm -rf "$TOOLS/lima"; mv "$dl/x" "$TOOLS/lima"
      ln -sfn ../lima/bin/limactl "$BIN/limactl" ;;
  esac
  rm -rf "$dl"
  tool_ok "$t" || { echo "$t installed but reports $(tool_version "$t" "$BIN/$(tool_bin "$t")")" >&2; exit 1; }
}

record() { mkdir -p "$TOOLS"; grep -qxF "$*" "$MANIFEST" 2>/dev/null || echo "$*" >>"$MANIFEST"; }

cmd_deps() {
  local t plan=() todo=() sudo_steps=()
  for t in $TOOL_LIST; do tool_ok "$t" || { todo+=("$t"); plan+=("download $(tool_bin "$t") $(tool_want "$t") into .tools/ (sha256-checked)"); }; done
  venv_ok || plan+=("build .venv from requirements.txt on the .tools Python")
  collections_ok || plan+=("install pinned Ansible collections into ansible/collections")
  hooks_ok || plan+=("git config core.hooksPath .githooks")
  hosts_ok || sudo_steps+=(hosts)
  qemu_ok || sudo_steps+=(qemu)
  port_ok || sudo_steps+=(port)
  for t in ${sudo_steps[@]+"${sudo_steps[@]}"}; do
    case "$t" in
      hosts) plan+=("[sudo, asks first] add '127.0.0.1 llm.local grafana.local $HOSTS_MARKER' to /etc/hosts") ;;
      qemu) plan+=("[sudo, asks first] install QEMU for Lima: $(qemu_pkgs)") ;;
      port) plan+=("[sudo, asks first] net.ipv4.ip_unprivileged_port_start=80 via $SYSCTL_FILE (Lima forwards 443/80)") ;;
    esac
  done
  if [[ ${#plan[@]} -eq 0 ]]; then echo "make deps: nothing to install, host is ready ($OS/$ARCH)."; return 0; fi

  echo "make deps will ($OS/$ARCH):"
  for t in "${plan[@]}"; do echo "  - $t"; done
  for t in curl tar; do command -v "$t" >/dev/null || { echo "$t is required: $(pkg_hint "$t")" >&2; exit 1; }; done

  mkdir -p "$BIN"
  trap 'rm -rf "$TOOLS"/.dl.*' EXIT
  for t in ${todo[@]+"${todo[@]}"}; do install_tool "$t"; done

  for t in ${sudo_steps[@]+"${sudo_steps[@]}"}; do
    case "$t" in
      hosts)
        echo "==> /etc/hosts: $ROOT/scripts/hosts-entry.sh --apply"
        if confirm "Add the hosts line with sudo?"; then "$ROOT/scripts/hosts-entry.sh" --apply; fi ;;
      qemu)
        local pkgs; pkgs="$(qemu_pkgs)"
        if [[ -z "$pkgs" ]]; then echo "==> QEMU: no apt-get/dnf found; install qemu-system and qemu-img yourself"; continue; fi
        local mgr=dnf; command -v apt-get >/dev/null && mgr=apt-get
        echo "==> QEMU: sudo $mgr install -y $pkgs"
        if confirm "Install these system packages with sudo?"; then
          local p new=""
          for p in $pkgs; do  # record only packages that were not installed before
            if [[ "$mgr" == apt-get ]]; then dpkg -s "$p" >/dev/null 2>&1 || new="$new $p"
            else rpm -q "$p" >/dev/null 2>&1 || new="$new $p"; fi
          done
          # shellcheck disable=SC2086  # word splitting of the package list is intended
          sudo "$mgr" install -y $pkgs
          for p in $new; do record "pkg $mgr $p"; done
        fi ;;
      port)
        local prev; prev="$(port_start)"
        echo "==> sysctl: echo 'net.ipv4.ip_unprivileged_port_start = 80' | sudo tee $SYSCTL_FILE; sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80"
        if confirm "Apply this kernel setting with sudo?"; then
          echo 'net.ipv4.ip_unprivileged_port_start = 80' | sudo tee "$SYSCTL_FILE" >/dev/null
          sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80 >/dev/null
          record "sysctl net.ipv4.ip_unprivileged_port_start $prev"
        fi ;;
    esac
  done
}

# ---------------------------------------------------------------- uninstall
DRY_RUN="${DRY_RUN:-0}"
PURGE_SECRETS="${PURGE_SECRETS:-0}"
YES="${YES:-0}"  # answer yes to every step (no prompts); sudo may still ask for a password
STEP_DONE=0
step() {  # step "what" "shown command" function [args]: print, then ask (only print with DRY_RUN=1, no ask with YES=1); sets STEP_DONE
  local what="$1" shown="$2"; shift 2
  STEP_DONE=0
  echo "- $what"
  echo "    \$ $shown"
  if [[ "$DRY_RUN" == 1 ]]; then return 0; fi
  if [[ "$YES" == 1 ]] || confirm "Remove?"; then "$@"; STEP_DONE=1; echo "    done"; else echo "    kept"; fi
}
rm_path() { rm -rf -- "${ROOT:?}/${1:?}"; }
rm_tools_keep_manifest() { find "${ROOT:?}/.tools" -mindepth 1 -maxdepth 1 ! -name system-manifest -exec rm -rf -- {} +; }
rm_backups() { find "$ROOT/backups" -mindepth 1 ! -name .gitkeep -exec rm -rf -- {} +; }
unset_hooks() { git -C "$ROOT" config --unset core.hooksPath; }
delete_vm() { "$(limactl_bin)" delete --force "$VM"; }
remove_pkgs() { local mgr="$1"; shift; sudo "$mgr" remove -y "$@"; }
revert_sysctl() { sudo rm -f "$SYSCTL_FILE"; sudo sysctl -w "$1=$2" >/dev/null; }

cmd_uninstall() {
  if [[ "$DRY_RUN" == 1 ]]; then echo "DRY_RUN=1: listing the steps only, nothing is removed."
  elif [[ "$YES" == 1 ]]; then echo "YES=1: removing every step below without asking."
  else echo "Each step asks first (y/N)."; fi
  local st; st="$(vm_status)"
  if [[ "$st" != absent ]]; then step "Lima VM '$VM' ($st): the whole cluster, its disk and etcd" "limactl delete --force $VM" delete_vm
  else echo "- VM '$VM': not present"; fi
  if hosts_ok; then step "/etc/hosts line '$HOSTS_MARKER' (sudo)" "scripts/hosts-entry.sh --remove" "$ROOT/scripts/hosts-entry.sh" --remove
  else echo "- /etc/hosts line: not present"; fi

  local kept_system=0  # a system change the user keeps: its manifest record must survive the .tools/ step (B-047)
  if [[ -f "$MANIFEST" ]]; then  # system-wide changes recorded by make deps (Linux)
    local mgr pkgs=""
    for mgr in apt-get dnf; do
      pkgs="$(awk -v m="$mgr" '$1 == "pkg" && $2 == m {printf "%s ", $3}' "$MANIFEST")"
      [[ -n "$pkgs" ]] || continue
      # shellcheck disable=SC2086  # package list
      step "system packages installed by make deps (sudo)" "sudo $mgr remove -y $pkgs" remove_pkgs "$mgr" $pkgs
      [[ "$STEP_DONE" == 1 || "$DRY_RUN" == 1 ]] || kept_system=1
    done
    # Collect first, prompt after: a prompt inside `while read ... < manifest` reads the manifest, not the tty.
    local entries=() line key prev
    while IFS= read -r line; do [[ -z "$line" ]] || entries+=("$line"); done < <(awk '$1 == "sysctl" {print $2, $3}' "$MANIFEST")
    for line in ${entries[@]+"${entries[@]}"}; do
      key="${line%% *}"; prev="${line#* }"
      step "kernel setting $key (back to $prev, sudo)" "sudo rm -f $SYSCTL_FILE && sudo sysctl -w $key=$prev" revert_sysctl "$key" "$prev"
      [[ "$STEP_DONE" == 1 || "$DRY_RUN" == 1 ]] || kept_system=1
    done
  fi

  local p
  for p in .tools .venv .ansible ansible/collections out; do
    if [[ -e "$ROOT/$p" ]]; then
      case "$p" in
        .tools)
          [[ "$(vm_status)" == absent || "$DRY_RUN" == 1 ]] || echo "  note: VM '$VM' is kept; without .tools/ its limactl is gone (make deps brings it back)"
          if [[ "$kept_system" == 1 ]]; then
            step ".tools/: repo-local Python, kubectl, jq, Lima, shellcheck (keeps system-manifest: it lists the system changes kept above)" \
              "find .tools -mindepth 1 -maxdepth 1 ! -name system-manifest -exec rm -rf {} +" rm_tools_keep_manifest
          else
            step ".tools/: repo-local Python, kubectl, jq, Lima, shellcheck (and the install manifest)" "rm -rf .tools" rm_path .tools
          fi ;;
        out) step "out/: admin and operator kubeconfigs" "rm -rf out" rm_path out ;;
        *) step "$p/" "rm -rf $p" rm_path "$p" ;;
      esac
    else echo "- $p/: not present"; fi
  done
  if [[ -n "$(find "$ROOT/backups" -mindepth 1 ! -name .gitkeep 2>/dev/null | head -1)" ]]; then
    step "backups/*: etcd snapshots (keeps .gitkeep)" "find backups -mindepth 1 ! -name .gitkeep -exec rm -rf {} +" rm_backups
  else echo "- backups/: empty"; fi
  if hooks_ok; then step "git config core.hooksPath (.githooks)" "git config --unset core.hooksPath" unset_hooks
  else echo "- core.hooksPath: not set to .githooks"; fi

  if [[ "$PURGE_SECRETS" == 1 ]]; then
    echo "WARNING: .secrets/ holds the CA key. Without it the next provision creates a NEW CA, so the committed"
    echo "         certs/ca.crt no longer matches (B-037): commit the new certs/ca.crt and re-trust it."
    if [[ -e "$ROOT/.secrets" ]]; then step ".secrets/: CA key, operator key, Grafana password" "rm -rf .secrets" rm_path .secrets
    else echo "- .secrets/: not present"; fi
  else echo "- .secrets/: kept (CA key, reused across rebuilds). PURGE_SECRETS=1 removes it."; fi

  echo "Not touched: tools you installed yourself (e.g. Homebrew lima/python@3.14 from an older make deps,"
  echo "  kubectl, gh), ~/.lima/_config and Lima's image cache (shared with other Lima VMs)."
}

case "${1:-}" in
  doctor) cmd_doctor ;;
  preflight) shift; cmd_preflight "$@" ;;
  deps) cmd_deps ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
