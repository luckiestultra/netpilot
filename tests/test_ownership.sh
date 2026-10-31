#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
# Extracted application functions share the language formatter.
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
source <(sed -n '/^# BEGIN RUN RECOVERY$/,/^# END RUN RECOVERY$/p' "$SCRIPT")
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
for name in backup_file backup_file_once restore_file write_lines write_bbr_file write_bbr_module_file owned_config_target save_original_values managed_file_path prepare_state rollback_internal remove_state_files gai_preference_active apply_gai_preference apply_ipv4_preference_only; do
  sed -n "/^${name}() {/,/^}/p" "$SCRIPT" >> "$TMP/functions.sh"
done
source "$TMP/functions.sh"
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
setup() {
  STATE_DIR="$TMP/$1/state"; BACKUP_DIR="$STATE_DIR/backup"
  mkdir -p "$TMP/$1"
  BBR_FILE="$TMP/$1/10-netpilot-bbr.conf"; BBR_MODULE_FILE="$TMP/$1/module.conf"
  SYSCTL_FILE="$TMP/$1/99-network.conf"; LIMITS_FILE="$TMP/$1/limits.conf"; GAI_FILE="$TMP/$1/gai.conf"
  NIC_IFACE=eth0; SYSCTL_KEYS=()
  restore_rps() { :; }; restore_nic_ring() { :; }; remove_mss_rule() { :; }
  restore_original_values() { :; }
}

test_sysctl_only_never_restores_untouched_files() (
  setup sysctl
  printf 'original sysctl\n' > "$SYSCTL_FILE"
  printf 'original gai\n' > "$GAI_FILE"
  prepare_state sysctl-file
  [[ ! -e "$BACKUP_DIR/gai-file" && ! -e "$BACKUP_DIR/gai-file.missing" ]] || fail 'untouched gai was backed up'
  printf 'tool sysctl\n' > "$SYSCTL_FILE"
  printf 'administrator gai edit\n' > "$GAI_FILE"
  rollback_internal
  [[ "$(cat "$SYSCTL_FILE")" == 'original sysctl' ]] || fail 'owned sysctl was not restored'
  [[ "$(cat "$GAI_FILE")" == 'administrator gai edit' ]] || fail 'untouched gai edit was reverted'
)

test_no_file_operation_never_takes_config_ownership() (
  setup nic
  prepare_state
  [[ -z "$(ls -A "$BACKUP_DIR")" ]] || fail 'NIC-only state claimed unrelated config files'
  printf 'administrator sysctl\n' > "$SYSCTL_FILE"
  rollback_internal
  [[ "$(cat "$SYSCTL_FILE")" == 'administrator sysctl' ]] || fail 'NIC rollback removed unrelated sysctl config'
)

test_recorded_metadata_restores_owned_file() (
  setup recorded
  prepare_state
  printf 'recorded original\n' > "$GAI_FILE"
  backup_file "$GAI_FILE" gai-file
  printf 'recorded tuned\n' > "$GAI_FILE"
  rollback_internal
  [[ "$(cat "$GAI_FILE")" == 'recorded original' ]] || fail 'recorded backup metadata was ignored'
)

test_unowned_bbr_file_is_preserved() (
  setup unowned
  printf 'administrator setting\n' > "$BBR_FILE"
  if write_bbr_file; then fail 'unowned BBR file was accepted'; fi
  [[ "$(cat "$BBR_FILE")" == 'administrator setting' ]] || fail 'unowned BBR file was overwritten'
)

test_bbr_module_symlink_is_preserved() (
  setup module
  printf 'administrator module\n' > "$TMP/module/victim"
  ln -s "$TMP/module/victim" "$BBR_MODULE_FILE"
  if write_bbr_module_file; then fail 'module symlink destination was accepted'; fi
  [[ -L "$BBR_MODULE_FILE" ]] || fail 'module symlink was replaced'
  [[ "$(cat "$TMP/module/victim")" == 'administrator module' ]] || fail 'module symlink target was modified'
)

test_existing_ipv4_preference_does_not_claim_file() (
  setup already-ipv4
  printf 'precedence ::ffff:0:0/96 100\n' > "$GAI_FILE"
  default_interface() { printf eth0; }
  log() { :; }
  apply_ipv4_preference_only
  [[ ! -e "$STATE_DIR" ]] || fail 'already-configured no-op created a rollback claim'
)


test_bbr_module_restore_preserves_new_admin_file() (
  setup concurrent-module
  prepare_state bbr-module-file
  printf '# Administrator file created after the snapshot\n' > "$BBR_MODULE_FILE"
  if restore_file "$BBR_MODULE_FILE" bbr-module-file; then fail 'rollback accepted deletion of a new administrator file'; fi
  [[ "$(cat "$BBR_MODULE_FILE")" == '# Administrator file created after the snapshot' ]] || fail 'rollback removed a concurrent administrator file'
  [[ -f "$BACKUP_DIR/bbr-module-file.missing" ]] || fail 'failed restore lost its recovery record'
)

test_bbr_module_restore_rejects_unowned_hardlink() (
  setup identical-module
  printf '# Administrator module configuration\n' > "$TMP/identical-module/admin"
  ln "$TMP/identical-module/admin" "$BBR_MODULE_FILE"
  prepare_state bbr-module-file
  local inode
  inode="$(stat -c %i "$BBR_MODULE_FILE")"
  if restore_file "$BBR_MODULE_FILE" bbr-module-file; then fail 'rollback claimed ownership of an unowned hardlink'; fi
  [[ "$(stat -c %i "$BBR_MODULE_FILE")" == "$inode" ]] || fail 'restore unnecessarily replaced an unchanged hardlink'
)

test_existing_module_directory_permissions_are_preserved() (
  setup module-permissions
  chmod 0700 "$(dirname "$BBR_MODULE_FILE")"
  write_bbr_module_file || fail 'could not write module configuration'
  [[ "$(stat -c %a "$(dirname "$BBR_MODULE_FILE")")" == 700 ]] || fail 'writing module configuration reset existing directory permissions'
)


test_managed_module_hardlink_is_rejected() (
  setup managed-hardlink
  printf '# Managed by netpilot.sh.\ntcp_bbr\n' > "$TMP/managed-hardlink/admin"
  ln "$TMP/managed-hardlink/admin" "$BBR_MODULE_FILE"
  local inode
  inode="$(stat -c %i "$BBR_MODULE_FILE")"
  if write_bbr_module_file; then fail 'a multiply-linked managed module file was replaced'; fi
  [[ "$(stat -c %i "$BBR_MODULE_FILE")" == "$inode" ]] || fail 'managed module file lost its hardlink'
)

failures=0
for test in test_existing_ipv4_preference_does_not_claim_file test_sysctl_only_never_restores_untouched_files test_no_file_operation_never_takes_config_ownership test_recorded_metadata_restores_owned_file test_unowned_bbr_file_is_preserved test_bbr_module_symlink_is_preserved test_bbr_module_restore_preserves_new_admin_file test_bbr_module_restore_rejects_unowned_hardlink test_existing_module_directory_permissions_are_preserved test_managed_module_hardlink_is_rejected; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
