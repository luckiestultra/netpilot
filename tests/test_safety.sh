#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
# Extracted application functions share the language formatter.
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
# Load function definitions only; never run startup or real system operations.
awk '/^log\(\)/ {p=1} /^# CLI entry point/ || /^need_root$/ {exit} p {print}' "$SCRIPT" > "$TEST_DIR/functions.sh"
source "$TEST_DIR/functions.sh"
declare -a SYSCTL_KEYS=()
declare -A SYSCTL_TARGETS=()
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }

test_restore_reports_failure() (
  STATE_DIR="$TEST_DIR/restore"; mkdir -p "$STATE_DIR"
  printf 'net.test.key=original\n' > "$STATE_DIR/original-values"
  sysctl() { return 1; }
  sysctl_value() { printf 'changed\n'; }
  if restore_original_values; then fail 'failed sysctl restoration must return nonzero'; fi
)

test_rollback_retains_failed_backup() (
  STATE_DIR="$TEST_DIR/rollback"; mkdir -p "$STATE_DIR"
  printf 'net.test.key=original\n' > "$STATE_DIR/original-values"
  BACKUP_DIR="$STATE_DIR/backup"; mkdir -p "$BACKUP_DIR"
  BBR_FILE=x; BBR_MODULE_FILE=x; SYSCTL_FILE=x; LIMITS_FILE=x; GAI_FILE=x
  restore_rps() { :; }; restore_nic_ring() { :; }; remove_mss_rule() { :; }
  restore_file() { :; }
  sysctl() { return 1; }; sysctl_value() { printf 'changed\n'; }
  if rollback_internal; then fail 'partial rollback must report failure'; fi
  [[ -f "$STATE_DIR/original-values" ]] || fail 'failed rollback discarded original state'
)

test_failed_apply_never_succeeds() (
  STATE_DIR="$TEST_DIR/apply"; mkdir -p "$STATE_DIR"
  BBR_FILE="$STATE_DIR/bbr.conf"; BBR_MODULE_FILE="$STATE_DIR/modules.conf"; SYSCTL_FILE="$STATE_DIR/sysctl.conf"
  load_bbr_module() { :; }; build_targets() { :; }; default_interface() { printf eth0; }
  prepare_state() { :; }; install() { :; }; write_bbr_file() { return 1; }
  write_bbr_module_file() { :; }; sysctl_supported() { return 0; }; sysctl() { :; }
  bbr_fq_active() { return 0; }; show_bbr_dashboard() { :; }
  rollback_internal() { printf 'rollback\n' >> "$STATE_DIR/events"; }
  handle_error() { return 0; }
  # Conditional execution is the same context used by the interactive menu.
  if apply_bbr_only > "$STATE_DIR/output"; then fail 'failed config write returned success'; fi
  ! grep -q '已应用并备份' "$STATE_DIR/output" || fail 'failed apply printed success'
  [[ -f "$STATE_DIR/events" ]] || fail 'failed apply did not attempt recovery'
)

test_ring_original_saved_once() (
  STATE_DIR="$TEST_DIR/ring"; mkdir -p "$STATE_DIR"
  printf '256 256\n' > "$STATE_DIR/current"
  ensure_ethtool() { return 0; }; network_interfaces() { printf 'eth0\n'; }
  ethtool() {
    if [[ "$1" == -g ]]; then
      read -r rx tx < "$STATE_DIR/current"
      printf 'Pre-set maximums:\nRX: 1024\nTX: 1024\nCurrent hardware settings:\nRX: %s\nTX: %s\n' "$rx" "$tx"
    elif [[ "$1" == -G ]]; then
      printf '%s %s\n' "$4" "$6" > "$STATE_DIR/current"
    else return 1; fi
  }
  apply_nic_ring; apply_nic_ring
  grep -q $'eth0\t256\t256' "$STATE_DIR/nic-ring.before" || fail 'second apply overwrote initial ring backup'
)

test_single_cpu_skips_rps() (
  STATE_DIR="$TEST_DIR/rps"; mkdir -p "$STATE_DIR"
  nproc() { printf '1\n'; }; network_interfaces() { :; }
  sysctl_supported() { return 0; }; sysctl_value() { printf 0; }
  sysctl() { printf write > "$STATE_DIR/sysctl-was-written"; }
  apply_rps
  [[ ! -e "$STATE_DIR/sysctl-was-written" ]] || fail 'single-CPU RPS changed a sysctl'
)

test_restore_verifies_readback() (
  STATE_DIR="$TEST_DIR/readback"; mkdir -p "$STATE_DIR"
  printf 'net.test.key=original\n' > "$STATE_DIR/original-values"
  sysctl() { return 0; }; sysctl_value() { printf 'still-changed\n'; }
  if restore_original_values; then fail 'successful command with wrong read-back must fail'; fi
)

test_missing_metadata_preserves_file() (
  BACKUP_DIR="$TEST_DIR/missing-backup"; mkdir -p "$BACKUP_DIR"
  target="$TEST_DIR/existing-config"; printf 'keep me\n' > "$target"
  if restore_file "$target" unknown; then fail 'missing backup metadata must not report restored'; fi
  [[ "$(cat "$target")" == 'keep me' ]] || fail 'unowned configuration was deleted'
)

test_dangling_backup_preserved() (
  BACKUP_DIR="$TEST_DIR/symlink"; mkdir -p "$BACKUP_DIR"
  ln -s /nonexistent-target "$BACKUP_DIR/original"
  backup_file() { fail 'existing dangling-symlink backup must not be replaced'; }
  backup_file_once "$TEST_DIR/unused" original
  [[ -L "$BACKUP_DIR/original" ]] || fail 'symlink backup lost'
)

test_saved_values_not_overwritten() (
  STATE_DIR="$TEST_DIR/snapshot"; mkdir -p "$STATE_DIR"
  SYSCTL_KEYS=(net.test.one)
  sysctl_value() { printf 'first\n'; }
  save_original_values
  SYSCTL_KEYS=(net.test.one net.test.two)
  sysctl_value() { printf 'second\n'; }
  save_original_values
  grep -qx 'net.test.one=first' "$STATE_DIR/original-values" || fail 'original value was overwritten'
  grep -qx 'net.test.two=second' "$STATE_DIR/original-values" || fail 'newly managed key was not backed up'
)

test_failed_snapshot_keeps_original() (
  STATE_DIR="$TEST_DIR/snapshot-failure"; mkdir -p "$STATE_DIR"
  printf 'net.test.one=first\n' > "$STATE_DIR/original-values"
  SYSCTL_KEYS=(net.test.one net.test.two)
  sysctl_value() { printf 'second\n'; }
  mv() { return 1; }
  if save_original_values; then fail 'failed snapshot replacement must report failure'; fi
  [[ "$(cat "$STATE_DIR/original-values")" == 'net.test.one=first' ]] || fail 'failed snapshot write damaged saved state'
)

test_cpu_mask_uses_allowed_ids() (
  [[ "$(rps_mask_for_cpus '8-11,20' 3)" == 700 ]] || fail 'CPU count was confused with CPU IDs'
  [[ "$(rps_mask_for_cpus '1,3,5' 2)" == a ]] || fail 'non-contiguous CPU IDs were ignored'
  if rps_mask_for_cpus '64-65' 2 >/dev/null; then fail 'unsupported high CPU IDs must not wrap'; fi
)

test_mss_check_failure_is_not_absence() (
  STATE_DIR="$TEST_DIR/mss-check"; mkdir -p "$STATE_DIR"
  : > "$STATE_DIR/iptables4-added"
  MSS_COMMENT=netpilot
  iptables() { return 2; }
  if remove_mss_rule; then fail 'iptables inspection error was mistaken for an absent rule'; fi
)

test_mss_absent_rule_is_success() (
  STATE_DIR="$TEST_DIR/mss-absent"; mkdir -p "$STATE_DIR"
  : > "$STATE_DIR/iptables4-added"
  MSS_COMMENT=netpilot
  iptables() { return 1; }
  remove_mss_rule || fail 'an already absent MSS rule should be idempotent'
)

failures=0
for test in test_mss_check_failure_is_not_absence test_mss_absent_rule_is_success test_restore_reports_failure test_rollback_retains_failed_backup test_failed_apply_never_succeeds test_ring_original_saved_once test_single_cpu_skips_rps test_restore_verifies_readback test_missing_metadata_preserves_file test_dangling_backup_preserved test_saved_values_not_overwritten test_failed_snapshot_keeps_original test_cpu_mask_uses_allowed_ids; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
