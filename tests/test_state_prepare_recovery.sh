#!/usr/bin/env bash
# First-run preparation failures and file-only recovery use private temporary paths.
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'command rm -rf -- "$TMP"' EXIT
# shellcheck source=/dev/null
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
for fn in backup_file backup_file_once restore_file owned_config_target save_original_values managed_file_path prepare_state remove_state_files rollback_internal rollback_tuning restore_rps restore_nic_ring restore_original_values remove_mss_rule sysctl_matches normalize_sysctl_value; do
  # shellcheck source=/dev/null
  source <(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT")
done
fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
need_root() { :; }
show_status() { :; }
# The real CLI root guard is exercised by disposable-container integration.
# shellcheck disable=SC2034
setup() {
  CASE_DIR="$(mktemp -d "$TMP/case.XXXXXX")"
  STATE_DIR="$CASE_DIR/state"; BACKUP_DIR="$STATE_DIR/backup"
  BBR_FILE="$CASE_DIR/bbr.conf"; BBR_MODULE_FILE="$CASE_DIR/modules.conf"
  SYSCTL_FILE="$CASE_DIR/sysctl.conf"; LIMITS_FILE="$CASE_DIR/limits.conf"; GAI_FILE="$CASE_DIR/gai.conf"
  NIC_IFACE=''; MSS_COMMENT=netpilot; SYSCTL_KEYS=()
  printf '# original address policy\n' > "$GAI_FILE"
  cp -a "$GAI_FILE" "$CASE_DIR/expected-gai"
}
sysctl() { fail 'file-only preparation or recovery unexpectedly changed kernel parameters'; }

test_first_snapshot_publish_failure_is_retryable() (
  setup
  mv() {
    [[ "${*: -1}" != "$STATE_DIR/original-values" ]] || return 1
    command mv "$@"
  }
  if prepare_state gai-file; then fail 'snapshot publication failure was ignored'; return 1; fi
  unset -f mv
  [[ ! -e "$STATE_DIR" ]] || { fail 'failed first snapshot left an unusable state directory'; return 1; }
  prepare_state gai-file || { fail 'preparation could not retry after the transient failure'; return 1; }
  printf '# changed policy\n' > "$GAI_FILE"
  rollback_tuning || { fail 'retry baseline could not be restored'; return 1; }
  cmp -s "$GAI_FILE" "$CASE_DIR/expected-gai" || { fail 'retry did not preserve original bytes'; return 1; }
  [[ ! -e "$STATE_DIR" ]] || { fail 'successful retry recovery left owned state'; return 1; }
)

test_backup_copy_failure_keeps_a_retryable_marker() (
  setup
  cp() {
    local arg
    for arg in "$@"; do [[ "$arg" != "$GAI_FILE" ]] || return 1; done
    command cp "$@"
  }
  if prepare_state gai-file; then fail 'backup copy failure was ignored'; return 1; fi
  unset -f cp
  [[ -f "$STATE_DIR/original-values" ]] || { fail 'file-backup failure left no recovery marker'; return 1; }
  [[ -z "$(find "$STATE_DIR" -name '*.tmp.*' -print -quit)" ]] || { fail 'failed copy left incomplete temporary metadata'; return 1; }
  prepare_state gai-file || { fail 'file-backup preparation could not retry'; return 1; }
  printf '# changed policy\n' > "$GAI_FILE"
  rollback_tuning || { fail 'retried file backup could not be recovered'; return 1; }
  cmp -s "$GAI_FILE" "$CASE_DIR/expected-gai" || { fail 'retry changed the original baseline'; return 1; }
)

test_snapshot_update_failure_keeps_existing_baseline() (
  setup
  prepare_state gai-file || return 1
  cp -a "$STATE_DIR" "$CASE_DIR/expected-state"
  mv() {
    [[ "${*: -1}" != "$STATE_DIR/original-values" ]] || return 1
    command mv "$@"
  }
  if prepare_state gai-file; then fail 'repeat snapshot publication failure was ignored'; return 1; fi
  unset -f mv
  diff -r "$CASE_DIR/expected-state" "$STATE_DIR" || { fail 'failed update changed baseline or leaked a temporary file'; return 1; }
  prepare_state gai-file || { fail 'existing baseline could not retry'; return 1; }
)

test_file_only_backups_work_with_normal_rollback() (
  local name kind target
  for name in bbr-file bbr-module-file sysctl-file limits-file gai-file; do
    for kind in existing missing; do
      setup
      mkdir -p "$BACKUP_DIR"
      target="$(managed_file_path "$name")" || return 1
      # Module recovery targets a file actually written by NetPilot.
      if [[ "$name" == bbr-module-file ]]; then
        printf '# Managed by netpilot.sh.\ntcp_bbr\n' > "$target"
      else
        printf '# changed configuration\n' > "$target"
      fi
      if [[ "$kind" == existing ]]; then
        printf '# original %s\n' "$name" > "$BACKUP_DIR/$name"
        cp -a "$BACKUP_DIR/$name" "$CASE_DIR/expected-file"
      else
        : > "$BACKUP_DIR/$name.missing"
      fi
      [[ ! -e "$STATE_DIR/original-values" ]] || return 1
      rollback_tuning || { fail "normal rollback refused file-only $name/$kind"; return 1; }
      if [[ "$kind" == existing ]]; then
        cmp -s "$target" "$CASE_DIR/expected-file" || { fail 'file-only original bytes were not restored'; return 1; }
      else
        [[ ! -e "$target" && ! -L "$target" ]] || { fail 'file-only original absence was not restored'; return 1; }
      fi
      [[ ! -e "$STATE_DIR" ]] || { fail 'file-only recovery left owned metadata'; return 1; }
    done
  done
)

test_file_only_recovery_preserves_unknown_data() (
  setup
  mkdir -p "$BACKUP_DIR"
  cp -a "$GAI_FILE" "$BACKUP_DIR/gai-file"
  printf '# changed policy\n' > "$GAI_FILE"
  printf 'user notes\n' > "$STATE_DIR/user-notes"
  printf 'hidden user notes\n' > "$BACKUP_DIR/.user-notes"
  ln -s /nonexistent-user-target "$BACKUP_DIR/user-link"
  rollback_tuning || { fail 'file-only recovery failed solely due to unrelated retained files'; return 1; }
  cmp -s "$GAI_FILE" "$CASE_DIR/expected-gai" || return 1
  [[ "$(cat "$STATE_DIR/user-notes")" == 'user notes' ]] || return 1
  [[ "$(cat "$BACKUP_DIR/.user-notes")" == 'hidden user notes' ]] || return 1
  [[ -L "$BACKUP_DIR/user-link" ]] || return 1
  [[ ! -e "$BACKUP_DIR/gai-file" ]] || { fail 'successful recovery retained owned backup'; return 1; }
)

test_preparation_failure_never_recursively_deletes_unknown_files() (
  setup
  mv() {
    if [[ "${*: -1}" == "$STATE_DIR/original-values" ]]; then
      printf 'concurrently created user data\n' > "$STATE_DIR/user-notes"
      return 1
    fi
    command mv "$@"
  }
  if prepare_state gai-file; then fail 'snapshot publication failure was ignored'; return 1; fi
  unset -f mv
  [[ "$(cat "$STATE_DIR/user-notes")" == 'concurrently created user data' ]] || { fail 'preparation cleanup removed unrelated data'; return 1; }
  [[ -z "$(find "$STATE_DIR" -name 'original-values.tmp.*' -print -quit)" ]] || { fail 'failed publication leaked its own temporary file'; return 1; }
)

test_empty_and_unknown_only_state_are_not_reported_as_restored() (
  local kind
  for kind in empty unknown; do
    setup; mkdir -p "$BACKUP_DIR"
    if [[ "$kind" == unknown ]]; then printf 'keep\n' > "$STATE_DIR/user-notes"; fi
    if rollback_tuning; then fail "$kind state was falsely reported restored"; return 1; fi
    [[ -d "$STATE_DIR" ]] || { fail 'unrecognized state was removed'; return 1; }
  done
)

test_partial_directory_creation_failure_is_retryable() (
  setup
  install() {
    command mkdir -p "$STATE_DIR" || return 1
    return 1
  }
  if prepare_state gai-file > "$CASE_DIR/first-output" 2>&1; then
    fail 'partial directory creation failure was ignored'; return 1
  fi
  unset -f install
  [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]] || { fail 'failed partial creation left an unusable fresh state'; return 1; }
  if grep -q '目录已保留\|directories were retained' "$CASE_DIR/first-output"; then
    fail 'missing backup directory produced a misleading retention warning'; return 1
  fi
  prepare_state gai-file || { fail 'preparation could not retry after partial directory creation'; return 1; }
  printf '# changed policy\n' > "$GAI_FILE"
  rollback_tuning || { fail 'retried preparation could not restore its baseline'; return 1; }
  cmp -s "$GAI_FILE" "$CASE_DIR/expected-gai" || { fail 'retry lost the original file'; return 1; }
)

test_unterminated_snapshot_preserves_first_values_when_extended() (
  setup
  mkdir -p "$BACKUP_DIR"
  printf 'net.core.rmem_max=123' > "$STATE_DIR/original-values"
  local -A fixture_kernel=([net.core.rmem_max]=999 [net.core.wmem_max]=777)
  # Used by the production functions sourced above.
  # shellcheck disable=SC2034
  SYSCTL_KEYS=(net.core.rmem_max net.core.wmem_max)
  sysctl_value() { printf '%s\n' "${fixture_kernel[$1]}"; }
  sysctl() {
    [[ "$1" == -w && "$2" == *=* ]] || return 1
    local key="${2%%=*}" value="${2#*=}"
    [[ "$key" == net.core.rmem_max || "$key" == net.core.wmem_max ]] || return 1
    fixture_kernel["$key"]="$value"
  }
  prepare_state || { fail 'existing unterminated snapshot could not be extended'; return 1; }
  grep -Fxq 'net.core.rmem_max=123' "$STATE_DIR/original-values" || { fail 'existing first value was corrupted by the new record'; return 1; }
  grep -Fxq 'net.core.wmem_max=777' "$STATE_DIR/original-values" || { fail 'new key was not saved on its own line'; return 1; }
  [[ "$(wc -l < "$STATE_DIR/original-values")" -eq 2 ]] || { fail 'snapshot records do not have separate line boundaries'; return 1; }
  cp -a "$STATE_DIR/original-values" "$CASE_DIR/expected-values"
  fixture_kernel[net.core.rmem_max]=1111
  fixture_kernel[net.core.wmem_max]=2222
  prepare_state || { fail 'repeated preparation failed'; return 1; }
  cmp -s "$STATE_DIR/original-values" "$CASE_DIR/expected-values" || { fail 'repeated preparation replaced a first value'; return 1; }
  rollback_tuning || { fail 'extended first values could not be restored'; return 1; }
  [[ "${fixture_kernel[net.core.rmem_max]}" == 123 && "${fixture_kernel[net.core.wmem_max]}" == 777 ]] || {
    fail 'rollback did not restore each original value'; return 1
  }
)

failures=0
for test in test_partial_directory_creation_failure_is_retryable test_unterminated_snapshot_preserves_first_values_when_extended test_first_snapshot_publish_failure_is_retryable test_backup_copy_failure_keeps_a_retryable_marker test_snapshot_update_failure_keeps_existing_baseline test_file_only_backups_work_with_normal_rollback test_file_only_recovery_preserves_unknown_data test_preparation_failure_never_recursively_deletes_unknown_files test_empty_and_unknown_only_state_are_not_reported_as_restored; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
