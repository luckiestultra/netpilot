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
  [[ "$(rps_mask_for_cpus '0-31' 32)" == ffffffff ]] || fail '32-CPU mask must stay a single 32-bit chunk'
  [[ "$(rps_mask_for_cpus '32' 1)" == 1,00000000 ]] || fail 'CPU 32 lacked 32-bit comma chunking'
  [[ "$(rps_mask_for_cpus '32-33' 2)" == 3,00000000 ]] || fail 'CPUs 32-33 lacked 32-bit comma chunking'
  [[ "$(rps_mask_for_cpus '0-32' 33)" == 1,ffffffff ]] || fail 'CPUs 0-32 lacked 32-bit comma chunking'
  [[ "$(rps_mask_for_cpus '0-47' 48)" == ffff,ffffffff ]] || fail 'CPUs 0-47 lacked 32-bit comma chunking'
  [[ "$(rps_mask_for_cpus '0-62' 63)" == 7fffffff,ffffffff ]] || fail 'CPUs 0-62 lacked 32-bit comma chunking'
  [[ "$(rps_mask_for_cpus '62' 1)" == 40000000,00000000 ]] || fail 'CPU 62 mask was miscomputed'
  [[ "$(rps_mask_for_cpus '32,0-3' 3)" == 1,00000003 ]] || fail 'unordered high/low CPU ranges failed zero-padded chunking'
  [[ "$(rps_mask_for_cpus '0-2,1-3' 4)" == f ]] || fail 'overlapping CPU ranges were not deduplicated'
  local invalid_case allowed wanted
  for invalid_case in '63:1' '0-63:2' '64-65:2' '5-2:1' '0-1,5-2:2' '1,1:2' '0-1,:1'; do
    IFS=: read -r allowed wanted <<< "$invalid_case"
    if rps_mask_for_cpus "$allowed" "$wanted" >/dev/null; then
      fail "invalid CPU mask input was accepted: $invalid_case"
    fi
  done
)

test_ring_noop_and_exit_80() (
  STATE_DIR="$TEST_DIR/ring-exit80"; mkdir -p "$STATE_DIR"
  ensure_ethtool() { return 0; }
  network_interfaces() { printf 'eth0\n'; }
  # Already at hardware maximums: must skip without touching .before/-changed or calling ethtool -G.
  ethtool() {
    if [[ "$1" == -g ]]; then
      [[ "${LC_ALL:-}" == C ]] || fail 'ethtool -g must run under LC_ALL=C'
      printf 'Pre-set maximums:\nRX: 1024\nTX: 1024\nCurrent hardware settings:\nRX: 1024\nTX: 1024\n'
    elif [[ "$1" == -G ]]; then
      fail 'ethtool -G must not run when current ring equals maximum'
    fi
  }
  apply_nic_ring || fail 'already-maximal NIC ring failed'
  [[ ! -e "$STATE_DIR/nic-ring.before" && ! -e "$STATE_DIR/nic-ring-changed" ]] || fail 'no-op NIC ring created snapshot or change marker'

  # Exit code 80 with matching read-back succeeds, while exit codes 1 and 81 fail.
  printf '256 256\n' > "$TEST_DIR/ring-hw"
  local ring_rc=80
  ethtool() {
    local rx tx
    if [[ "$1" == -g ]]; then
      [[ "${LC_ALL:-}" == C ]] || fail 'ethtool -g must run under LC_ALL=C'
      read -r rx tx < "$TEST_DIR/ring-hw"
      printf 'Pre-set maximums:\nRX: 1024\nTX: 1024\nCurrent hardware settings:\nRX: %s\nTX: %s\n' "$rx" "$tx"
    elif [[ "$1" == -G ]]; then
      printf '%s %s\n' "$4" "$6" > "$TEST_DIR/ring-hw"
      return "$ring_rc"
    fi
  }
  apply_nic_ring || fail 'ethtool -G exit 80 with matching read-back was treated as an error'
  grep -qx $'eth0\t256\t256' "$STATE_DIR/nic-ring.before" || fail 'exit-80 apply did not record initial ring settings'

  for ring_rc in 1 81; do
    STATE_DIR="$TEST_DIR/ring-err-$ring_rc"; mkdir -p "$STATE_DIR"
    printf '256 256\n' > "$TEST_DIR/ring-hw"
    if apply_nic_ring; then fail "ethtool -G exit $ring_rc was swallowed as success"; fi
  done

  # Post-reboot restore: hardware already reset to 256/256 where ethtool -G would return 80.
  STATE_DIR="$TEST_DIR/ring-exit80"
  printf '256 256\n' > "$TEST_DIR/ring-hw"
  ethtool() {
    local rx tx
    if [[ "$1" == -g ]]; then
      [[ "${LC_ALL:-}" == C ]] || fail 'restore_nic_ring ethtool -g must run under LC_ALL=C'
      read -r rx tx < "$TEST_DIR/ring-hw"
      printf 'Current hardware settings:\nRX: %s\nTX: %s\n' "$rx" "$tx"
    elif [[ "$1" == -G ]]; then
      return 80
    fi
  }
  restore_nic_ring || fail 'post-reboot NIC ring restore failed when hardware already matched snapshot'

  # Restore where hardware differs, ethtool -G updates and exits 80 vs 81.
  ethtool() {
    local rx tx
    if [[ "$1" == -g ]]; then
      read -r rx tx < "$TEST_DIR/ring-hw"
      printf 'Current hardware settings:\nRX: %s\nTX: %s\n' "$rx" "$tx"
    elif [[ "$1" == -G ]]; then
      printf '%s %s\n' "$4" "$6" > "$TEST_DIR/ring-hw"
      return "$ring_rc"
    fi
  }
  printf '1024 1024\n' > "$TEST_DIR/ring-hw"; ring_rc=81
  if restore_nic_ring; then fail 'restore_nic_ring swallowed hardware error exit 81'; fi
  printf '1024 1024\n' > "$TEST_DIR/ring-hw"; ring_rc=80
  restore_nic_ring || fail 'restore_nic_ring rejected exit 80 with matching read-back'
)

test_apply_nic_only_preserves_clean_and_existing_state() (
  # shellcheck disable=SC2034
  {
    STATE_DIR="$TEST_DIR/nic-only-noop"; BACKUP_DIR="$STATE_DIR/backup"
    BBR_FILE="$TEST_DIR/bbr"; BBR_MODULE_FILE="$TEST_DIR/mod"
    SYSCTL_FILE="$TEST_DIR/sys"; LIMITS_FILE="$TEST_DIR/lim"; GAI_FILE="$TEST_DIR/gai"
  }
  default_interface() { printf 'eth0\n'; }
  ensure_ethtool() { return 1; }
  adaptive_cpu_count() { printf '1\n'; }
  show_nic_dashboard() {
    (($# == 0)) || fail 'show_nic_dashboard received unexpected arguments'
  }
  apply_nic_only || fail 'zero-change apply_nic_only failed'
  [[ ! -e "$STATE_DIR" ]] || fail 'zero-change apply_nic_only polluted STATE_DIR'

  # Existing tuning baseline must survive both no-op and failed menu-4 NIC attempts.
  mkdir -p "$BACKUP_DIR"
  printf 'net.ipv4.tcp_moderate_rcvbuf=0\n' > "$STATE_DIR/original-values"
  printf '# original sysctl\n' > "$BACKUP_DIR/sysctl-file"
  apply_nic_only || fail 'no-op apply_nic_only failed with existing state'
  [[ -f "$STATE_DIR/original-values" && -f "$BACKUP_DIR/sysctl-file" ]] || fail 'no-op apply_nic_only damaged existing state'

  ensure_ethtool() { return 0; }
  network_interfaces() { printf 'eth0\n'; }
  ethtool() {
    if [[ "$1" == -g ]]; then
      printf 'Pre-set maximums:\nRX: 1024\nTX: 1024\nCurrent hardware settings:\nRX: 256\nTX: 256\n'
    else
      return 1
    fi
  }
  if apply_nic_only; then fail 'failing NIC ring write succeeded in apply_nic_only'; fi
  grep -qx 'net.ipv4.tcp_moderate_rcvbuf=0' "$STATE_DIR/original-values" || fail 'failed apply_nic_only destroyed prior original-values'
  grep -qx '# original sysctl' "$BACKUP_DIR/sysctl-file" || fail 'failed apply_nic_only destroyed prior sysctl backup'
  [[ ! -e "$STATE_DIR/nic-ring-changed" && ! -e "$STATE_DIR/nic-ring.before" ]] || fail 'failed apply_nic_only leaked transient NIC ring markers'
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
for test in test_mss_check_failure_is_not_absence test_mss_absent_rule_is_success test_restore_reports_failure test_rollback_retains_failed_backup test_failed_apply_never_succeeds test_ring_original_saved_once test_ring_noop_and_exit_80 test_apply_nic_only_preserves_clean_and_existing_state test_single_cpu_skips_rps test_restore_verifies_readback test_missing_metadata_preserves_file test_dangling_backup_preserved test_saved_values_not_overwritten test_failed_snapshot_keeps_original test_cpu_mask_uses_allowed_ids; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
