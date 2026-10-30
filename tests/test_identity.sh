#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/netpilot.sh"
TMP="$(mktemp -d)"
trap 'command rm -rf -- "$TMP"' EXIT
# Load the real guarded script's functions without binding fixtures to its
# readonly system paths. Writes in this default suite stay in the temp dir.
bash -c 'source "$1"; declare -f' _ "$SCRIPT" > "$TMP/functions.sh"
source "$TMP/functions.sh"
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

identity_namespace() (
  source "$SCRIPT"
  [[ "$STATE_DIR" == /var/lib/netpilot && "$BACKUP_DIR" == /var/lib/netpilot/backup ]] || fail 'state namespace is not exclusively NetPilot'
  [[ "$INSTALL_PATH" == /usr/local/bin/netpilot.sh && "$SHORTCUT_PATH" == /usr/local/bin/netpilot ]] || fail 'installation namespace is not exclusively NetPilot'
  [[ "$BBR_FILE" == /etc/sysctl.d/10-netpilot-bbr.conf && "$SYSCTL_FILE" == /etc/sysctl.d/99-netpilot.conf ]] || fail 'sysctl namespace is not exclusively NetPilot'
  [[ "$LIMITS_FILE" == /etc/security/limits.d/99-netpilot.conf && "$BBR_MODULE_FILE" == /etc/modules-load.d/netpilot.conf && "$MSS_COMMENT" == netpilot ]] || fail 'module/limits/firewall namespace is not NetPilot'
  [[ "$UPDATE_URL" == 'https://github.com/liuxr0814/netpilot/raw/refs/heads/main/netpilot.sh' ]] || fail 'update URL is not canonical'
  declare -f run_mutation | grep -q '/run/netpilot.lock' || fail 'mutation lock is not NetPilot-owned'
)

identity_entrypoint() (
  [[ -f "$SCRIPT" && ! -L "$SCRIPT" ]] || fail 'NetPilot standalone entry is missing or symlink'
  mapfile -t sources < <(find "$ROOT" -maxdepth 1 -name '*.sh' -type f -printf '%f\n')
  [[ "${#sources[@]}" == 1 && "${sources[0]}" == netpilot.sh ]] || fail 'repository has additional top-level script entrypoints'
  bash "$SCRIPT" help > "$TMP/help"
  grep -q 'NetPilot' "$TMP/help" || fail 'help has no NetPilot identity'
  grep -q '^用法：netpilot ' "$TMP/help" || fail 'help advertises a different command'
)

identity_static_ownership() (
  INSTALL_PATH="$TMP/owned-script"
  UPDATE_URL='https://github.com/liuxr0814/netpilot/raw/refs/heads/main/netpilot.sh'
  printf '#!/bin/bash\nreadonly UPDATE_URL="%s"\nuninstall_own_script() {\n  :\n}\ntouch "%s"\n' "$UPDATE_URL" "$TMP/executed-target" > "$INSTALL_PATH"
  installed_script_owned || fail 'canonical installed revision was not recognized'
  [[ ! -e "$TMP/executed-target" ]] || fail 'ownership check executed installed target'
  printf '#!/bin/bash\nreadonly UPDATE_URL="https://example.invalid/other-tool.sh"\nuninstall_own_script() {\n  :\n}\ntouch "%s"\n' "$TMP/untrusted-executed-target" > "$INSTALL_PATH"
  if installed_script_owned; then fail 'installation with untrusted update URL was accepted'; fi
  [[ ! -e "$TMP/untrusted-executed-target" ]] || fail 'ownership check executed untrusted target'
  printf '#!/bin/bash\nprintf unrelated\n' > "$INSTALL_PATH"
  if installed_script_owned; then fail 'unrelated installation was accepted'; fi
  command rm -f "$INSTALL_PATH"
  ln -s "$TMP/nonexistent" "$INSTALL_PATH"
  if installed_script_owned; then fail 'dangling installation link was accepted'; fi
)

identity_config_marker() (
  SYSCTL_FILE="$TMP/managed.conf"
  declare -a SYSCTL_KEYS=(net.ipv4.tcp_rmem)
  declare -A SYSCTL_TARGETS=([net.ipv4.tcp_rmem]='4096 131072 2097152')
  chown() { :; }
  printf '# Managed by netpilot.sh.\nnet.ipv4.tcp_wmem = 4096 16384 1048576\n' > "$SYSCTL_FILE"
  write_sysctl_file || fail 'NetPilot-owned config was rejected'
  grep -qx '# Managed by netpilot.sh.' "$SYSCTL_FILE" || fail 'new config has wrong marker'
  grep -q '^net.ipv4.tcp_wmem = 4096 16384 1048576$' "$SYSCTL_FILE" || fail 'persisted targets were lost'
  grep -q '^net.ipv4.tcp_rmem = 4096 131072 2097152$' "$SYSCTL_FILE" || fail 'new target was not persisted'
  owned_config_target "$SYSCTL_FILE" || fail 'canonical marker was not accepted'
  printf '# Managed by other-tool.sh.\n' > "$SYSCTL_FILE"
  if owned_config_target "$SYSCTL_FILE"; then fail 'foreign marker was accepted'; fi
  if write_sysctl_file; then fail 'foreign config was overwritten'; fi
  [[ "$(cat "$SYSCTL_FILE")" == '# Managed by other-tool.sh.' ]] || fail 'foreign config changed on refusal'
)

identity_single_alias() (
  INSTALL_PATH="$TMP/alias-install"
  SHORTCUT_PATH="$TMP/netpilot"
  printf '#!/bin/bash\n' > "$INSTALL_PATH"
  install_shortcuts || fail 'explicit alias install failed'
  [[ -L "$SHORTCUT_PATH" && "$(readlink "$SHORTCUT_PATH")" == "$INSTALL_PATH" ]] || fail 'NetPilot alias missing'
  command rm -f "$SHORTCUT_PATH"
  printf 'unrelated command\n' > "$SHORTCUT_PATH"
  install_shortcuts || fail 'unrelated alias should be preserved without failing installation'
  [[ "$(cat "$SHORTCUT_PATH")" == 'unrelated command' ]] || fail 'unrelated NetPilot command was overwritten'
  command rm -f "$SHORTCUT_PATH"
  ln -s "$TMP/foreign-target" "$SHORTCUT_PATH"
  install_shortcuts || fail 'unrelated link collision should be preserved'
  [[ "$(readlink "$SHORTCUT_PATH")" == "$TMP/foreign-target" ]] || fail 'unrelated alias link was changed'
  command rm -f "$SHORTCUT_PATH"
  ln() { return 1; }
  if install_shortcuts; then fail 'alias creation failure was ignored'; fi
)

identity_update_alias_failure() (
  INSTALL_PATH="$TMP/update-target"
  UPDATE_URL='https://github.com/liuxr0814/netpilot/raw/refs/heads/main/netpilot.sh'
  printf '#!/bin/bash\nprintf old\n' > "$INSTALL_PATH"
  curl() {
    while (($#)); do
      if [[ "$1" == --output ]]; then printf '#!/bin/bash\nprintf new\n' > "$2"; return; fi
      shift
    done
    return 1
  }
  install_shortcuts() { return 1; }
  exec() { printf 'executed\n' > "$TMP/failed-alias-exec"; }
  if check_update; then fail 'update ignored shortcut creation failure'; fi
  [[ ! -e "$TMP/failed-alias-exec" ]] || fail 'update continued execution after alias failure'
)

failures=0
for test in identity_namespace identity_entrypoint identity_static_ownership identity_config_marker identity_single_alias identity_update_alias_failure; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
