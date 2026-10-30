#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/netpilot.sh"
[[ -f "$SCRIPT" ]] || SCRIPT="$ROOT/vps-tcp-full-tune.sh"
TMP="$(mktemp -d)"
trap 'command rm -rf -- "$TMP"' EXIT
# Source the original, guarded script in a child; load its real function bodies
# without its readonly paths so every write below stays inside a private fixture.
bash -c 'source "$1"; declare -f' _ "$SCRIPT" > "$TMP/functions.sh"
source "$TMP/functions.sh"
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

migration_entrypoints() (
  [[ -f "$ROOT/netpilot.sh" && ! -L "$ROOT/netpilot.sh" ]] || fail 'canonical NetPilot entry is missing or symlink'
  [[ -f "$ROOT/vps-tcp-full-tune.sh" && ! -L "$ROOT/vps-tcp-full-tune.sh" ]] || fail 'legacy standalone payload is missing or symlink'
  cmp -s "$ROOT/netpilot.sh" "$ROOT/vps-tcp-full-tune.sh" || fail 'legacy update payload differs from canonical script'
  bash "$ROOT/netpilot.sh" help > "$TMP/help"
  grep -q 'NetPilot' "$TMP/help" || fail 'canonical help has no NetPilot branding'
)

migration_stable_contract() (
  source "$SCRIPT"
  [[ "$UPDATE_URL" == 'https://github.com/liuxr0814/netpilot/raw/refs/heads/main/netpilot.sh' ]] || fail 'updater does not use canonical NetPilot URL'
  [[ "$STATE_DIR" == /var/lib/vps-tcp-full-tune && "$INSTALL_PATH" == /usr/local/bin/tcp.sh ]] || fail 'rename moved legacy baseline or installed update target'
  [[ "$MSS_COMMENT" == vps-tcp-full-tune && "$BBR_MODULE_FILE" == /etc/modules-load.d/vps-tcp-full-tune.conf ]] || fail 'rename orphaned firewall/module ownership'
  [[ "${NETPILOT_SHORTCUT_PATH:-}" == /usr/local/bin/netpilot && "$SHORTCUT_PATH" == /usr/local/bin/tcp ]] || fail 'new and legacy command paths not both defined'
  declare -f run_mutation | grep -q '/run/vps-tcp-full-tune.lock' || fail 'rename split the mutation lock'
)

migration_owned_revision_detection() (
  INSTALL_PATH="$TMP/owned-script"
  UPDATE_URL='https://github.com/liuxr0814/netpilot/raw/refs/heads/main/netpilot.sh'
  for url in "$UPDATE_URL" 'https://github.com/liuxr0814/vps-tcp-tune/raw/refs/heads/main/vps-tcp-full-tune.sh'; do
    printf '#!/bin/bash\nreadonly UPDATE_URL="%s"\nuninstall_own_script() {\n  :\n}\ntouch "%s"\n' "$url" "$TMP/executed-target" > "$INSTALL_PATH"
    installed_script_owned || fail 'known installed revision was not recognized'
    [[ ! -e "$TMP/executed-target" ]] || fail 'ownership check executed installed target'
  done
  printf '#!/bin/bash\nreadonly UPDATE_URL="https://example.invalid/other-tool.sh"\nuninstall_own_script() {\n  :\n}\ntouch "%s"\n' "$TMP/untrusted-executed-target" > "$INSTALL_PATH"
  if installed_script_owned; then fail 'installation with untrusted update URL was accepted'; fi
  [[ ! -e "$TMP/untrusted-executed-target" ]] || fail 'ownership check executed untrusted target'
  printf '#!/bin/bash\nprintf unrelated\n' > "$INSTALL_PATH"
  if installed_script_owned; then fail 'unrelated installation was accepted'; fi
  command rm -f "$INSTALL_PATH"
  ln -s "$TMP/nonexistent" "$INSTALL_PATH"
  if installed_script_owned; then fail 'dangling installation link was accepted'; fi
)

migration_config_markers() (
  SYSCTL_FILE="$TMP/managed.conf"
  declare -a SYSCTL_KEYS=(net.ipv4.tcp_rmem)
  declare -A SYSCTL_TARGETS=([net.ipv4.tcp_rmem]='4096 131072 2097152')
  chown() { :; }
  printf '# Managed by vps-tcp-full-tune.sh.\nnet.ipv4.tcp_wmem = 4096 16384 1048576\n' > "$SYSCTL_FILE"
  write_sysctl_file || fail 'legacy owned config was rejected during continued apply'
  grep -qx '# Managed by netpilot.sh.' "$SYSCTL_FILE" || fail 'newly written config retains old display marker'
  grep -q '^net.ipv4.tcp_wmem = 4096 16384 1048576$' "$SYSCTL_FILE" || fail 'legacy persisted targets were lost'
  grep -q '^net.ipv4.tcp_rmem = 4096 131072 2097152$' "$SYSCTL_FILE" || fail 'new target was not persisted'
  owned_config_target "$SYSCTL_FILE" || fail 'new marker not accepted'
  printf '# Managed by vps-tcp-full-tune.sh.\n' > "$SYSCTL_FILE"
  owned_config_target "$SYSCTL_FILE" || fail 'legacy marker no longer accepted'
  printf 'administrator config\n' > "$SYSCTL_FILE"
  if owned_config_target "$SYSCTL_FILE"; then fail 'unowned config accepted after rename'; fi
)

migration_alias_ownership() (
  INSTALL_PATH="$TMP/alias-install"
  SHORTCUT_PATH="$TMP/tcp"
  NETPILOT_SHORTCUT_PATH="$TMP/netpilot"
  LEGACY_SHORTCUT_PATH="$TMP/t"
  printf '#!/bin/bash\n' > "$INSTALL_PATH"
  declare -F install_shortcuts >/dev/null || fail 'shared explicit-install alias routine is missing'
  install_shortcuts || fail 'explicit alias install failed'
  [[ -L "$SHORTCUT_PATH" && "$(readlink "$SHORTCUT_PATH")" == "$INSTALL_PATH" ]] || fail 'legacy tcp alias missing'
  [[ -L "$NETPILOT_SHORTCUT_PATH" && "$(readlink "$NETPILOT_SHORTCUT_PATH")" == "$INSTALL_PATH" ]] || fail 'NetPilot alias missing'
  command rm -f "$NETPILOT_SHORTCUT_PATH"
  printf 'unrelated command\n' > "$NETPILOT_SHORTCUT_PATH"
  install_shortcuts || fail 'unrelated alias should be preserved without failing installation'
  [[ "$(cat "$NETPILOT_SHORTCUT_PATH")" == 'unrelated command' ]] || fail 'unrelated NetPilot command was overwritten'
)

migration_update_alias_failure() (
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
for test in migration_entrypoints migration_stable_contract migration_owned_revision_detection migration_config_markers migration_alias_ownership migration_update_alias_failure; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
