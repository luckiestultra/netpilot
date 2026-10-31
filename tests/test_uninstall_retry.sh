#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_OVERRIDE="${SCRIPT_OVERRIDE:-$ROOT/netpilot.sh}"
# Reuse the canonical fixture and real recovery implementation without running
# its test list. These regressions assert only public uninstall behavior.
# shellcheck source=/dev/null
source <(sed '/^failures=0$/,$d' "$ROOT/tests/test_uninstall.sh")

retry_setup() {
  setup "$1"
  mkdir -p "$BACKUP_DIR" "$CASE_DIR/config"
  printf '# original configuration\n' > "$BACKUP_DIR/gai-file"
  printf '# changed configuration\n' > "$GAI_FILE"
  run_dir="$(auto_report prepare "$AUTO_REPORT_ROOT" "$STATE_DIR")"
  printf '{"type":"netpilot-tune-report","version":1}\n' > "$run_dir/summary.json"
  rollback_internal() { fixture_canonical_rollback_internal "$@"; }
}
retry_assert_no_success() {
  if grep -Eq '回退已完成|Rollback completed|程序、自有快捷命令和可识别的默认报告已清理|The tool, its owned shortcut and recognized default reports were removed' "$CASE_DIR/output"; then
    fail 'failed uninstall reported success'
  fi
}
retry_assert_complete() {
  invoke_cli y --rollback || { cat "$CASE_DIR/output" >&2; fail 'same rollback uninstall command could not retry'; }
  assert_removed
  [[ ! -e "$STATE_DIR" && ! -e "$run_dir" ]] || fail 'successful retry retained owned state or reports'
  [[ "$(cat "$GAI_FILE")" == '# original configuration' ]] || fail 'retry lost the restored configuration'
}
test_report_cleanup_failure_can_retry_rollback_uninstall() (
  retry_setup retry-report-cleanup
  ln -s "$CASE_DIR/user-file" "$run_dir/before.json"
  printf 'unrelated\n' > "$CASE_DIR/user-file"
  if invoke_cli y --rollback; then fail 'unsafe report cleanup unexpectedly succeeded'; fi
  assert_installed; retry_assert_no_success
  [[ -f "$run_dir/summary.json" && -f "$BACKUP_DIR/gai-file" ]] || fail 'report cleanup failure discarded report or recovery backup'
  rm "$run_dir/before.json"
  retry_assert_complete
)
test_program_removal_failure_can_retry_rollback_uninstall() (
  retry_setup retry-program-removal
  rm() {
    if [[ "${*: -1}" == "$INSTALL_PATH" && ! -e "$CASE_DIR/removal-failed" ]]; then
      : > "$CASE_DIR/removal-failed"; return 1
    fi
    command rm "$@"
  }
  if invoke_cli y --rollback; then fail 'program removal failure was ignored'; fi
  assert_installed
  [[ -f "$BACKUP_DIR/gai-file" ]] || fail 'failed program removal discarded recovery backup'
  retry_assert_no_success
  retry_assert_complete
)
test_state_cleanup_failures_can_retry_rollback_uninstall() (
  local point records marker_hash
  for point in partial backup-directory state-directory; do
    for records in file-only kernel-and-file; do
      retry_setup "retry-state-cleanup-$point-$records"
      if [[ "$records" == kernel-and-file ]]; then
        printf 'net.ipv4.tcp_congestion_control=cubic\n' > "$STATE_DIR/original-values"
        marker_hash="$(sha256sum "$STATE_DIR/original-values" | awk '{print $1}')"
      fi
      rm() {
        local path
        if [[ "$point" == partial && ! -e "$CASE_DIR/state-cleanup-failed" ]]; then
          for path in "$@"; do
            if [[ "$path" == "$STATE_DIR/rps-sysctl-changed" ]]; then
              : > "$CASE_DIR/state-cleanup-failed"; return 1
            fi
          done
        fi
        command rm "$@"
      }
      rmdir() {
        if [[ ! -e "$CASE_DIR/state-cleanup-failed" ]] && {
          [[ "$point" == backup-directory && "${*: -1}" == "$BACKUP_DIR" ]] ||
          [[ "$point" == state-directory && "${*: -1}" == "$STATE_DIR" ]]; }; then
          : > "$CASE_DIR/state-cleanup-failed"; return 1
        fi
        command rmdir "$@"
      }
      if invoke_cli y --rollback; then fail "state cleanup failure was ignored: $point/$records"; fi
      assert_installed; retry_assert_no_success
      if [[ "$records" == kernel-and-file ]]; then
        [[ "$(sha256sum "$STATE_DIR/original-values" | awk '{print $1}')" == "$marker_hash" ]] || fail 'state cleanup compensation lost original kernel values'
      fi
      retry_assert_complete
      [[ "$records" == file-only || "$(cat "$KERNEL_STATE")" == cubic ]] || fail 'retry failed to retain restored kernel value'
    done
  done
)
test_partial_change_marker_removal_retains_snapshots_for_retry() (
  local kind
  for kind in rps nic-ring; do
    retry_setup "retry-partial-marker-$kind"
    if [[ "$kind" == rps ]]; then
      printf 'ff\n' > "$CASE_DIR/rps_cpus"
      printf '%s\t0\n' "$CASE_DIR/rps_cpus" > "$STATE_DIR/rps.before"
    else
      printf '4096 4096\n' > "$CASE_DIR/ring-values"
      printf 'eth-test\t128\t256\n' > "$STATE_DIR/nic-ring.before"
      ethtool() {
        local rx tx
        if [[ "$1" == -G ]]; then printf '%s %s\n' "$4" "$6" > "$CASE_DIR/ring-values"
        else
          builtin read -r rx tx < "$CASE_DIR/ring-values"
          printf 'Current hardware settings:\nRX: %s\nTX: %s\n' "$rx" "$tx"
        fi
      }
    fi
    : > "$STATE_DIR/$kind-changed"
    rm() {
      local path status=0
      # GNU rm can remove later operands after one operand fails. Exercise
      # actual deletions on both sides of a retained modification marker.
      for path in "$@"; do
        [[ "$path" == -* ]] && continue
        if [[ "$path" == "$STATE_DIR/$kind-changed" && ! -e "$CASE_DIR/partial-delete-failed" ]]; then
          : > "$CASE_DIR/partial-delete-failed"; status=1; continue
        fi
        command rm -f -- "$path" || status=1
      done
      return "$status"
    }
    if invoke_cli y --rollback; then fail 'partial marker removal failure was ignored'; fi
    assert_installed; retry_assert_no_success
    [[ -f "$STATE_DIR/$kind-changed" && -f "$STATE_DIR/$kind.before" ]] || fail 'partial marker cleanup discarded the snapshot needed to retry'
    retry_assert_complete
    if [[ "$kind" == rps ]]; then
      [[ "$(cat "$CASE_DIR/rps_cpus")" == 0 ]] || fail 'RPS original value was not restored'
    else
      [[ "$(cat "$CASE_DIR/ring-values")" == '128 256' ]] || fail 'NIC ring original values were not restored'
    fi
  done
)
test_compensation_preserves_concurrent_original_values() (
  retry_setup retry-concurrent-original-values
  printf 'net.ipv4.tcp_congestion_control=cubic\n' > "$STATE_DIR/original-values"
  rmdir() {
    if [[ "${*: -1}" == "$BACKUP_DIR" && ! -e "$CASE_DIR/state-cleanup-failed" ]]; then
      : > "$CASE_DIR/state-cleanup-failed"
      printf 'concurrent user data\n' > "$STATE_DIR/original-values"
      return 1
    fi
    command rmdir "$@"
  }
  if invoke_cli y --rollback; then fail 'state cleanup collision reported success'; fi
  retry_assert_no_success
  [[ "$(cat "$STATE_DIR/original-values")" == 'concurrent user data' ]] || fail 'compensation overwrote concurrent original-values path'
  recovery_path="$(grep -oE '/tmp/netpilot-uninstall\.[[:alnum:]]+' "$CASE_DIR/output" | tail -n 1)"
  [[ -f "$recovery_path/original-values" && "$(cat "$recovery_path/original-values")" == 'net.ipv4.tcp_congestion_control=cubic' ]] || fail 'compensation discarded the original recovery snapshot after a collision'
)
test_compensation_never_overwrites_concurrent_program() (
  retry_setup retry-concurrent-program
  rmdir() {
    if [[ "${*: -1}" == "$BACKUP_DIR" && ! -e "$CASE_DIR/state-cleanup-failed" ]]; then
      : > "$CASE_DIR/state-cleanup-failed"
      printf '#!/bin/sh\nprintf unrelated\n' > "$INSTALL_PATH"
      return 1
    fi
    command rmdir "$@"
  }
  if invoke_cli y --rollback; then fail 'failed compensation reported success'; fi
  retry_assert_no_success
  [[ "$(cat "$INSTALL_PATH")" == $'#!/bin/sh\nprintf unrelated' ]] || fail 'compensation overwrote concurrent program'
  [[ ! -L "$SHORTCUT_PATH" ]] || fail 'compensation attached the shortcut to an unrelated replacement'
  recovery_path="$(grep -oE '/tmp/netpilot-uninstall\.[[:alnum:]]+' "$CASE_DIR/output" | tail -n 1)"
  [[ -f "$recovery_path/program" && -f "$recovery_path/original-values" ]] || fail 'failed compensation did not retain and report recovery copies'
  installed_script_owned "$recovery_path/program" || fail 'retained program recovery copy is not usable'
)
test_compensation_publication_failure_keeps_recovery_copies() (
  retry_setup retry-compensation-failure
  rmdir() {
    if [[ "${*: -1}" == "$BACKUP_DIR" && ! -e "$CASE_DIR/state-cleanup-failed" ]]; then
      : > "$CASE_DIR/state-cleanup-failed"; return 1
    fi
    command rmdir "$@"
  }
  ln() { [[ "${*: -1}" != "$INSTALL_PATH" ]] || return 1; command ln "$@"; }
  if invoke_cli y --rollback; then fail 'failed compensation publication reported success'; fi
  retry_assert_no_success
  recovery_path="$(grep -oE '/tmp/netpilot-uninstall\.[[:alnum:]]+' "$CASE_DIR/output" | tail -n 1)"
  [[ ! -e "$INSTALL_PATH" && -f "$recovery_path/program" && -f "$STATE_DIR/original-values" ]] || fail 'failed compensation lost program or retry recovery data'
  [[ ! -L "$SHORTCUT_PATH" ]] || fail 'failed compensation restored a broken shortcut'
)
test_compensation_does_not_publish_inside_concurrent_directories() (
  local collision concurrent_path
  for collision in program shortcut; do
    retry_setup "retry-concurrent-directory-$collision"
    if [[ "$collision" == program ]]; then concurrent_path="$INSTALL_PATH"
    else concurrent_path="$SHORTCUT_PATH"; fi
    rmdir() {
      if [[ "${*: -1}" == "$BACKUP_DIR" && ! -e "$CASE_DIR/state-cleanup-failed" ]]; then
        : > "$CASE_DIR/state-cleanup-failed"
        [[ "$collision" != shortcut ]] || mkdir "$SHORTCUT_PATH"
        return 1
      fi
      command rmdir "$@"
    }
    ln() {
      if [[ "$collision" == program && "${*: -1}" == "$INSTALL_PATH" ]]; then mkdir "$INSTALL_PATH"; fi
      command ln "$@"
    }
    if invoke_cli y --rollback; then fail 'concurrent directory collision reported success'; fi
    retry_assert_no_success
    [[ -d "$concurrent_path" && -z "$(find "$concurrent_path" -mindepth 1 -print -quit)" ]] || fail 'compensation published recovery data inside an unrelated directory'
  done
)
test_state_cleanup_retry_preserves_unknown_state_data() (
  retry_setup retry-unowned-state
  printf 'private user data\n' > "$STATE_DIR/user-data"
  rmdir() {
    if [[ "${*: -1}" == "$BACKUP_DIR" && ! -e "$CASE_DIR/state-cleanup-failed" ]]; then
      : > "$CASE_DIR/state-cleanup-failed"; return 1
    fi
    command rmdir "$@"
  }
  if invoke_cli y --rollback; then fail 'state cleanup failure was ignored'; fi
  assert_installed; retry_assert_no_success
  invoke_cli y --rollback || fail 'state cleanup with unknown data could not retry'
  assert_removed
  [[ "$(cat "$STATE_DIR/user-data")" == 'private user data' ]] || fail 'state cleanup retry changed unknown user data'
  [[ ! -e "$STATE_DIR/original-values" && ! -e "$BACKUP_DIR" ]] || fail 'state cleanup retry retained owned recovery data'
)
test_initial_missing_state_still_refuses_rollback_uninstall() (
  setup retry-no-state
  if invoke_cli y --rollback; then fail 'initial missing rollback state was accepted'; fi
  assert_installed; retry_assert_no_success
  [[ ! -e "$STATE_DIR" ]] || fail 'refused rollback fabricated recovery state'
)
test_cancelled_rollback_uninstall_keeps_state_and_reports() (
  retry_setup retry-cancelled
  protected_snapshot > "$CASE_DIR/before-snapshot"
  invoke_cli n --rollback || fail 'cancelled rollback uninstall failed'
  assert_installed; assert_protected_unchanged; retry_assert_no_success
)
test_restore_failure_keeps_program_and_reports() (
  retry_setup retry-restoration-failure
  cp() { [[ "${*: -2:1}" != "$BACKUP_DIR/gai-file" ]] || return 1; command cp "$@"; }
  if invoke_cli y --rollback; then fail 'restoration failure was ignored'; fi
  assert_installed; retry_assert_no_success
  [[ -f "$run_dir/summary.json" && -f "$BACKUP_DIR/gai-file" ]] || fail 'restoration failure discarded report or backup'
)
failures=0
for test in test_report_cleanup_failure_can_retry_rollback_uninstall test_program_removal_failure_can_retry_rollback_uninstall test_state_cleanup_failures_can_retry_rollback_uninstall test_partial_change_marker_removal_retains_snapshots_for_retry test_compensation_preserves_concurrent_original_values test_compensation_never_overwrites_concurrent_program test_compensation_publication_failure_keeps_recovery_copies test_compensation_does_not_publish_inside_concurrent_directories test_state_cleanup_retry_preserves_unknown_state_data test_initial_missing_state_still_refuses_rollback_uninstall test_cancelled_rollback_uninstall_keeps_state_and_reports test_restore_failure_keeps_program_and_reports; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
