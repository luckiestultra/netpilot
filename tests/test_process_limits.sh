#!/usr/bin/env bash
# Process limits belong to each invocation, not to persistent tuning state.
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'command rm -rf -- "$TMP"' EXIT
# Load definitions without startup/constants so every writable path is private.
# shellcheck source=/dev/null
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
awk '/^log\(\)/ {p=1} /^# CLI entry point/ {exit} p {print}' "$SCRIPT" > "$TMP/functions.sh"
# shellcheck source=/dev/null
source "$TMP/functions.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
need_root() { :; }
show_status() { :; }
sysctl() { fail 'file-only recovery unexpectedly wrote kernel parameters'; }
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
legacy_recovery_state() {
  mkdir -p "$BACKUP_DIR"
  : > "$STATE_DIR/original-values"
  cp -a "$GAI_FILE" "$BACKUP_DIR/gai-file"
  printf '# changed address policy\n' > "$GAI_FILE"
}

test_new_state_does_not_snapshot_process_limits() (
  setup
  local soft hard
  soft="$(ulimit -Sn)"; hard="$(ulimit -Hn)"
  prepare_state gai-file || { fail 'fresh preparation failed'; return 1; }
  [[ ! -e "$STATE_DIR/ulimit.before" ]] || { fail 'fresh tuning state recorded an untouched process limit'; return 1; }
  [[ "$(ulimit -Sn)" == "$soft" && "$(ulimit -Hn)" == "$hard" ]] || { fail 'preparation changed process limits'; return 1; }
  rollback_tuning || { fail 'new file-only state could not be restored'; return 1; }
)

test_lower_hard_limit_does_not_block_configuration_restore() (
  setup; legacy_recovery_state
  printf '4096\n' > "$STATE_DIR/ulimit.before"
  # Lower both limits only in this test's subshell. Root may or may not have
  # CAP_SYS_RESOURCE; either way rollback must leave these invocation limits alone.
  ulimit -n 128 || { fail 'cannot prepare a lower process limit'; return 1; }
  local soft hard result=0
  soft="$(ulimit -Sn)"; hard="$(ulimit -Hn)"
  rollback_tuning > "$CASE_DIR/rollback-output" 2>&1 || result=$?
  cmp -s "$GAI_FILE" "$CASE_DIR/expected-gai" || { fail 'configuration was not restored'; return 1; }
  [[ "$result" == 0 ]] || { fail 'restored configuration was blocked by an unrelated old process limit'; return 1; }
  [[ "$(ulimit -Sn)" == "$soft" && "$(ulimit -Hn)" == "$hard" ]] || { fail 'rollback changed the current invocation soft/hard limits'; return 1; }
  [[ ! -e "$STATE_DIR" ]] || { fail 'old process metadata unnecessarily retained recovery state'; return 1; }
)

test_invalid_legacy_limit_is_cleaned_without_restoring_it() (
  setup; legacy_recovery_state
  printf 'not-a-process-limit\n' > "$STATE_DIR/ulimit.before"
  printf 'user notes\n' > "$STATE_DIR/user-notes"
  local soft hard
  soft="$(ulimit -Sn)"; hard="$(ulimit -Hn)"
  rollback_tuning || { fail 'unused legacy process metadata blocked file restoration'; return 1; }
  cmp -s "$GAI_FILE" "$CASE_DIR/expected-gai" || return 1
  [[ ! -e "$STATE_DIR/ulimit.before" ]] || { fail 'recognized obsolete metadata was not cleaned'; return 1; }
  [[ "$(cat "$STATE_DIR/user-notes")" == 'user notes' ]] || { fail 'unrelated user data was deleted'; return 1; }
  [[ "$(ulimit -Sn)" == "$soft" && "$(ulimit -Hn)" == "$hard" ]] || { fail 'legacy metadata altered process limits'; return 1; }
)

test_persistent_limits_file_backup_still_restores() (
  setup
  mkdir -p "$BACKUP_DIR"
  printf '# original persistent limits\n* soft nofile 2048\n' > "$BACKUP_DIR/limits-file"
  cp -a "$BACKUP_DIR/limits-file" "$CASE_DIR/expected-limits"
  printf '# changed persistent limits\n' > "$LIMITS_FILE"
  rollback_tuning || { fail 'persistent limits-file recovery was removed with process-limit handling'; return 1; }
  cmp -s "$LIMITS_FILE" "$CASE_DIR/expected-limits" || { fail 'persistent limits file was not restored exactly'; return 1; }
  [[ ! -e "$STATE_DIR" ]] || { fail 'persistent limits-file metadata was not cleaned'; return 1; }
)

failures=0
for test in test_new_state_does_not_snapshot_process_limits test_lower_hard_limit_does_not_block_configuration_restore test_invalid_legacy_limit_is_cleaned_without_restoring_it test_persistent_limits_file_backup_still_restores; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
