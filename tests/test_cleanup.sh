#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'command rm -rf -- "$TMP"' EXIT
for name in remove_state_files rollback_internal rollback_tuning; do
  sed -n "/^${name}() {/,/^}/p" "$SCRIPT" >> "$TMP/functions.sh"
done
source "$TMP/functions.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
setup() {
  STATE_DIR="$TMP/$1/state"; BACKUP_DIR="$STATE_DIR/backup"
  mkdir -p "$BACKUP_DIR"
  printf 'net.test.key=original\n' > "$STATE_DIR/original-values"
  printf '256\n' > "$STATE_DIR/ulimit.before"
  printf 'original config\n' > "$BACKUP_DIR/sysctl-file"
}

test_failed_delete_preserves_retry_marker() (
  setup failed-rm
  rm() { return 1; }
  if remove_state_files; then fail 'failed state deletion must return nonzero'; fi
  [[ -f "$STATE_DIR/original-values" ]] || fail 'failed cleanup removed retry marker'
  [[ -f "$BACKUP_DIR/sysctl-file" ]] || fail 'failed cleanup lost untouched backup'
)

test_partial_delete_preserves_retry_marker() (
  setup partial-rm
  rm() {
    local path
    for path in "$@"; do
      [[ "$path" == -* ]] && continue
      [[ "$path" == "$BACKUP_DIR/sysctl-file" ]] && return 1
      command rm -f -- "$path" || return 1
    done
  }
  if remove_state_files; then fail 'partly successful deletion must return nonzero'; fi
  [[ -f "$STATE_DIR/original-values" ]] || fail 'partial cleanup removed retry marker before all backups were cleaned'
  [[ -f "$BACKUP_DIR/sysctl-file" ]] || fail 'partial cleanup lost failed-to-delete backup'
  unset -f rm
  remove_state_files || fail 'cleanup could not be retried'
  [[ ! -e "$STATE_DIR" ]] || fail 'successful retry left empty state directories'
)

test_original_values_delete_failure_is_reported() (
  setup failed-marker
  rm() {
    local path
    for path in "$@"; do
      [[ "$path" == "$STATE_DIR/original-values" ]] && return 1
    done
    command rm "$@"
  }
  if remove_state_files; then fail 'failed marker deletion must return nonzero'; fi
  [[ -f "$STATE_DIR/original-values" ]] || fail 'failed marker deletion discarded retry state'
)

test_empty_directory_failure_is_reported() (
  setup failed-rmdir
  rmdir() { return 1; }
  if remove_state_files; then fail 'failed empty-directory removal must return nonzero'; fi
  [[ -d "$BACKUP_DIR" ]] || fail 'injected directory failure did not retain directory'
)

test_unknown_files_are_retained() (
  setup unknown
  printf 'administrator data\n' > "$STATE_DIR/keep"
  printf 'hidden data\n' > "$BACKUP_DIR/.keep"
  ln -s /nonexistent-target "$BACKUP_DIR/link"
  remove_state_files || fail 'unknown files should be retained without failing restored state cleanup'
  [[ "$(cat "$STATE_DIR/keep")" == 'administrator data' ]] || fail 'unknown state data was deleted'
  [[ "$(cat "$BACKUP_DIR/.keep")" == 'hidden data' ]] || fail 'unknown hidden backup data was deleted'
  [[ -L "$BACKUP_DIR/link" ]] || fail 'unknown dangling link was deleted'
  [[ ! -e "$STATE_DIR/original-values" && ! -e "$BACKUP_DIR/sysctl-file" ]] || fail 'owned state was not cleaned'
)

test_completed_cleanup_is_idempotent() (
  setup success
  remove_state_files || fail 'cleanup failed'
  [[ ! -e "$STATE_DIR" ]] || fail 'empty state directories remain'
  remove_state_files || fail 'already absent state must be a no-op'
)

test_rollback_propagates_cleanup_failure() (
  setup rollback
  need_root() { :; }; show_status() { :; }
  restore_rps() { :; }; restore_nic_ring() { :; }; remove_mss_rule() { :; }
  restore_original_values() { :; }; restore_ulimit() { :; }
  managed_file_path() { printf '%s\n' "$TMP/config"; }; restore_file() { :; }
  rm() { return 1; }
  if rollback_tuning > "$TMP/rollback-output"; then fail 'rollback reported success after cleanup failure'; fi
  ! grep -q 'Rollback completed' "$TMP/rollback-output" || fail 'rollback printed completion after cleanup failure'
  [[ -f "$STATE_DIR/original-values" ]] || fail 'failed rollback cleanup removed retry marker'
)

failures=0
for test in test_failed_delete_preserves_retry_marker test_partial_delete_preserves_retry_marker test_original_values_delete_failure_is_reported test_empty_directory_failure_is_reported test_unknown_files_are_retained test_completed_cleanup_is_idempotent test_rollback_propagates_cleanup_failure; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
