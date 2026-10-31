#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
# Load canonical recovery functions, with all writable paths relocated below.
# shellcheck source=/dev/null
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
for fn in backup_file backup_file_once restore_file save_original_values managed_file_path prepare_state remove_state_files rollback_internal apply_gai_preference gai_preference_active apply_ipv4_preference_only restore_rps restore_nic_ring restore_original_values remove_mss_rule transaction_failed sysctl_value sysctl_matches normalize_sysctl_value sysctl_supported rps_mask_for_cpus; do
  # shellcheck source=/dev/null
  source <(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT")
done
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
# Variables are consumed by the production functions loaded above.
# shellcheck disable=SC2034
setup() {
  CASE_DIR="$(mktemp -d "$TMP/case.XXXXXX")"
  STATE_DIR="$CASE_DIR/state"; BACKUP_DIR="$STATE_DIR/backup"
  BBR_FILE="$CASE_DIR/bbr.conf"; BBR_MODULE_FILE="$CASE_DIR/modules.conf"
  SYSCTL_FILE="$CASE_DIR/sysctl.conf"; LIMITS_FILE="$CASE_DIR/limits.conf"; GAI_FILE="$CASE_DIR/gai.conf"
  NIC_IFACE=eth0; SYSCTL_KEYS=(); declare -gA SYSCTL_TARGETS=()
  MSS_COMMENT=netpilot; FAIL_SYSCTL=0; IGNORE_SYSCTL_WRITES=0; FAIL_RING=0; IGNORE_RING_WRITES=0; CHECK_RPS_MARKER=0
  KERNEL_DIR="$CASE_DIR/kernel"; mkdir -p "$KERNEL_DIR"
  printf 'changed\n' > "$KERNEL_DIR/net.test.key"
  printf '32768\n' > "$KERNEL_DIR/net.core.rps_sock_flow_entries"
  printf '1024 1024\n' > "$CASE_DIR/ring-current"
  : > "$CASE_DIR/sysctl-writes"; : > "$CASE_DIR/ring-writes"
}
default_interface() { printf 'eth0\n'; }
# File-backed kernel values use canonical sysctl_matches read-back verification.
sysctl() {
  local key value
  case "${1:-}" in
    -n) [[ $# == 2 && -f "$KERNEL_DIR/$2" ]] || return 1; command cat "$KERNEL_DIR/$2" ;;
    -w)
      [[ $# == 2 && "$2" == *=* ]] || return 1
      key="${2%%=*}"; value="${2#*=}"
      [[ -f "$KERNEL_DIR/$key" ]] || return 1
      if ((CHECK_RPS_MARKER)) && [[ "$key" == net.core.rps_sock_flow_entries ]]; then
        [[ -f "$STATE_DIR/rps-sysctl-changed" && "$(command cat "$STATE_DIR/rps-sysctl.before")" == net.core.rps_sock_flow_entries=0 ]] || return 1
      fi
      printf '%s\n' "$2" >> "$CASE_DIR/sysctl-writes"
      ((FAIL_SYSCTL == 0)) || return 1
      if ((IGNORE_SYSCTL_WRITES == 0)); then printf '%s\n' "$value" > "$KERNEL_DIR/$key"; fi
      ;;
    *) return 1 ;;
  esac
}
ethtool() {
  local rx tx
  case "${1:-}" in
    -G)
      [[ $# == 6 && "$2" == eth0 && "$3" == rx && "$5" == tx ]] || return 1
      printf '%s %s\n' "$4" "$6" >> "$CASE_DIR/ring-writes"
      ((FAIL_RING == 0)) || return 1
      if ((IGNORE_RING_WRITES == 0)); then printf '%s %s\n' "$4" "$6" > "$CASE_DIR/ring-current"; fi
      ;;
    -g)
      read -r rx tx < "$CASE_DIR/ring-current"
      printf 'Current hardware settings:\nRX: %s\nTX: %s\n' "$rx" "$tx"
      ;;
    *) return 1 ;;
  esac
}
start_recovery() { mkdir -p "$BACKUP_DIR"; : > "$STATE_DIR/original-values"; }
assert_retained() {
  [[ -f "$STATE_DIR/original-values" ]] || { fail 'failed recovery deleted the retry marker'; return 1; }
  diff -r "$CASE_DIR/expected-state" "$STATE_DIR" > "$CASE_DIR/state-diff" || { fail 'failed recovery altered backup metadata'; return 1; }
}
assert_completed() { [[ ! -e "$STATE_DIR" ]] || { fail 'successful recovery left saved state'; return 1; }; }

test_gai_symlink_preserves_target() (
  setup
  local kind="$1"
  if [[ "$kind" == existing ]]; then printf '# administrator baseline\n' > "$CASE_DIR/target.conf"; fi
  ln -s target.conf "$GAI_FILE"
  if apply_ipv4_preference_only; then
    rollback_internal || { fail 'GAI symlink rollback failed'; return 1; }
  fi
  [[ -L "$GAI_FILE" && "$(readlink "$GAI_FILE")" == target.conf ]] || { fail 'GAI symlink changed'; return 1; }
  if [[ "$kind" == existing ]]; then
    [[ "$(cat "$CASE_DIR/target.conf")" == '# administrator baseline' ]] || { fail 'GAI symlink target was modified despite recovery'; return 1; }
  else
    [[ ! -e "$CASE_DIR/target.conf" ]] || { fail 'GAI followed a dangling symlink and created its target'; return 1; }
  fi
)

test_gai_regular_round_trip() (
  setup
  printf '# administrator baseline\n' > "$GAI_FILE"
  cp -a "$GAI_FILE" "$CASE_DIR/expected.conf"
  apply_ipv4_preference_only || { fail 'regular GAI apply failed'; return 1; }
  grep -q '^precedence ::ffff:0:0/96 100$' "$GAI_FILE" || { fail 'regular GAI preference was not applied'; return 1; }
  rollback_internal || { fail 'regular GAI rollback failed'; return 1; }
  cmp -s "$GAI_FILE" "$CASE_DIR/expected.conf" || { fail 'regular GAI rollback lost original bytes'; return 1; }
  assert_completed
)

test_gai_active_symlink_is_noop() (
  setup
  printf 'precedence ::ffff:0:0/96 100\n' > "$CASE_DIR/target.conf"
  ln -s target.conf "$GAI_FILE"
  apply_ipv4_preference_only || { fail 'active GAI preference was refused'; return 1; }
  [[ ! -e "$STATE_DIR" && -L "$GAI_FILE" && "$(cat "$CASE_DIR/target.conf")" == 'precedence ::ffff:0:0/96 100' ]] || { fail 'active GAI symlink was not a no-op'; return 1; }
)

test_rps_damaged_backup_is_retained() (
  setup; start_recovery
  : > "$STATE_DIR/rps-changed"; printf 'ff\n' > "$CASE_DIR/rps_cpus"
  case "$1" in
    missing) ;;
    empty) : > "$STATE_DIR/rps.before" ;;
    whitespace) printf ' \t \n\t\n' > "$STATE_DIR/rps.before" ;;
    invalid) printf '%s\tnot-a-mask\n' "$CASE_DIR/rps_cpus" > "$STATE_DIR/rps.before" ;;
  esac
  cp -a "$STATE_DIR" "$CASE_DIR/expected-state"
  if rollback_internal; then fail "RPS $1 snapshot falsely reported restored"; return 1; fi
  [[ "$(cat "$CASE_DIR/rps_cpus")" == ff ]] || { fail 'damaged RPS backup was written to a queue'; return 1; }
  assert_retained
)

test_ring_damaged_backup_is_retained() (
  setup; start_recovery
  : > "$STATE_DIR/nic-ring-changed"
  case "$1" in
    missing) ;;
    empty) : > "$STATE_DIR/nic-ring.before" ;;
    whitespace) printf ' \t \t \n\t\n' > "$STATE_DIR/nic-ring.before" ;;
    invalid) printf 'eth0\tinvalid\t256\n' > "$STATE_DIR/nic-ring.before" ;;
  esac
  cp -a "$STATE_DIR" "$CASE_DIR/expected-state"
  if rollback_internal; then fail "ring $1 snapshot falsely reported restored"; return 1; fi
  [[ ! -s "$CASE_DIR/ring-writes" && "$(cat "$CASE_DIR/ring-current")" == '1024 1024' ]] || { fail 'damaged ring backup reached the driver'; return 1; }
  assert_retained
)

test_rps_sysctl_damaged_backup_is_retained() (
  setup; prepare_no_lf_case rps-sysctl
  case "$1" in
    empty) : > "$STATE_DIR/rps-sysctl.before" ;;
    whitespace) printf ' \t \n' > "$STATE_DIR/rps-sysctl.before" ;;
    invalid) printf 'net.test.key=damaged\n' > "$STATE_DIR/rps-sysctl.before" ;;
  esac
  cp -a "$STATE_DIR" "$CASE_DIR/expected-state"
  if rollback_internal; then fail "RPS sysctl $1 snapshot falsely reported restored"; return 1; fi
  [[ ! -s "$CASE_DIR/sysctl-writes" && "$(cat "$KERNEL_DIR/net.core.rps_sock_flow_entries")" == 32768 ]] || { fail 'damaged RPS sysctl backup was written'; return 1; }
  assert_retained
)

prepare_no_lf_case() {
  local kind="$1"
  start_recovery
  case "$kind" in
    original) printf 'net.test.key=original' > "$STATE_DIR/original-values" ;;
    rps|rps-sysctl|rps-flow)
      : > "$STATE_DIR/rps-changed"; printf 'ff\n' > "$CASE_DIR/rps_cpus"
      printf '%s\t00000000' "$CASE_DIR/rps_cpus" > "$STATE_DIR/rps.before"
      if [[ "$kind" == rps-flow ]]; then
        printf '4096\n' > "$CASE_DIR/rps_flow_cnt"
        printf '%s\t00000001,00000000\n%s\t0' "$CASE_DIR/rps_cpus" "$CASE_DIR/rps_flow_cnt" > "$STATE_DIR/rps.before"
      fi
      if [[ "$kind" == rps-sysctl ]]; then printf 'net.core.rps_sock_flow_entries=0' > "$STATE_DIR/rps-sysctl.before"; fi
      ;;
    ring)
      : > "$STATE_DIR/nic-ring-changed"
      printf 'eth0\t256\t256' > "$STATE_DIR/nic-ring.before"
      ;;
  esac
}

test_no_lf_restores_last_record() (
  setup; prepare_no_lf_case "$1"
  rollback_internal || { fail "$1 recovery with no final newline failed"; return 1; }
  case "$1" in
    original) [[ "$(cat "$KERNEL_DIR/net.test.key")" == original ]] || { fail 'last sysctl record without newline was skipped'; return 1; } ;;
    rps) [[ "$(cat "$CASE_DIR/rps_cpus")" == 00000000 ]] || { fail 'last RPS queue record without newline was skipped'; return 1; } ;;
    rps-sysctl) [[ "$(cat "$KERNEL_DIR/net.core.rps_sock_flow_entries")" == 0 ]] || { fail 'last RPS sysctl record without newline was skipped'; return 1; } ;;
    rps-flow) [[ "$(cat "$CASE_DIR/rps_cpus")" == 00000001,00000000 && "$(cat "$CASE_DIR/rps_flow_cnt")" == 0 ]] || { fail 'grouped CPU mask or last flow-count record was not restored'; return 1; } ;;
    ring) [[ "$(cat "$CASE_DIR/ring-current")" == '256 256' ]] || { fail 'last ring record without newline was skipped'; return 1; } ;;
  esac
  assert_completed
)

test_no_lf_failure_is_retained() (
  setup; prepare_no_lf_case "$1"
  case "$1:$2" in
    original:write|rps-sysctl:write) FAIL_SYSCTL=1 ;;
    original:readback|rps-sysctl:readback) IGNORE_SYSCTL_WRITES=1 ;;
    rps:write) rm "$CASE_DIR/rps_cpus"; mkdir "$CASE_DIR/rps_cpus" ;;
    rps:readback)
      cat() {
        if [[ "${1:-}" == "$CASE_DIR/rps_cpus" ]]; then printf 'ff\n'; else command cat "$@"; fi
      }
      ;;
    ring:write) FAIL_RING=1 ;;
    ring:readback) IGNORE_RING_WRITES=1 ;;
  esac
  cp -a "$STATE_DIR" "$CASE_DIR/expected-state"
  if rollback_internal; then fail "$1 no-newline $2 failure was reported as restored"; return 1; fi
  assert_retained
)

# Exercise real apply_rps against relocated sysfs queues and process affinity.
# Only filesystem paths change; backup, marker, write and read-back logic stays canonical.
start_rps_apply() {
  local mode="$1"
  start_recovery
  printf '0\n' > "$KERNEL_DIR/net.core.rps_sock_flow_entries"
  printf 'Cpus_allowed_list:\t0-1\n' > "$CASE_DIR/status"
  if [[ "$mode" != no-queues ]]; then
    mkdir -p "$CASE_DIR/sysfs/eth0/queues/rx-0"
    printf '0\n' > "$CASE_DIR/sysfs/eth0/queues/rx-0/rps_cpus"
    printf '0\n' > "$CASE_DIR/sysfs/eth0/queues/rx-0/rps_flow_cnt"
  fi
  if [[ "$mode" == unsupported ]]; then rm "$KERNEL_DIR/net.core.rps_sock_flow_entries"; fi
  network_interfaces() { printf 'eth0\n'; }
  adaptive_cpu_count() { printf '2\n'; }
  # shellcheck source=/dev/null
  source <(sed -n '/^apply_rps() {/,/^}/p' "$SCRIPT" | sed "s@/sys/class/net/@$CASE_DIR/sysfs/@g;s@/proc/self/status@$CASE_DIR/status@g")
  apply_rps
}

test_applied_rps_sysctl_damaged_snapshot_is_retained() (
  setup
  start_rps_apply supported || { fail 'real RPS apply fixture failed'; return 1; }
  [[ "$(cat "$KERNEL_DIR/net.core.rps_sock_flow_entries")" == 32768 ]] || { fail 'RPS fixture did not apply the auxiliary sysctl'; return 1; }
  case "$1" in
    missing) rm "$STATE_DIR/rps-sysctl.before" ;;
    empty) : > "$STATE_DIR/rps-sysctl.before" ;;
    whitespace) printf ' \t \n' > "$STATE_DIR/rps-sysctl.before" ;;
    invalid) printf 'net.test.key=damaged\n' > "$STATE_DIR/rps-sysctl.before" ;;
  esac
  cp -a "$STATE_DIR" "$CASE_DIR/expected-state"
  cp "$CASE_DIR/sysctl-writes" "$CASE_DIR/expected-writes"
  if rollback_internal; then fail "applied RPS sysctl $1 snapshot falsely reported restored"; return 1; fi
  [[ "$(cat "$KERNEL_DIR/net.core.rps_sock_flow_entries")" == 32768 ]] || { fail 'damaged RPS snapshot changed the auxiliary sysctl'; return 1; }
  cmp -s "$CASE_DIR/sysctl-writes" "$CASE_DIR/expected-writes" || { fail 'damaged RPS snapshot reached sysctl'; return 1; }
  assert_retained
)

test_applied_rps_sysctl_round_trip() (
  setup
  start_rps_apply supported || { fail 'RPS apply failed'; return 1; }
  [[ -f "$STATE_DIR/rps-sysctl-changed" ]] || { fail 'RPS sysctl mutation has no independent marker'; return 1; }
  apply_rps || { fail 'repeated RPS apply failed'; return 1; }
  [[ "$(cat "$STATE_DIR/rps-sysctl.before")" == net.core.rps_sock_flow_entries=0 ]] || { fail 'repeated RPS apply replaced the first auxiliary baseline'; return 1; }
  rollback_internal || { fail 'RPS sysctl round-trip failed'; return 1; }
  [[ "$(cat "$KERNEL_DIR/net.core.rps_sock_flow_entries")" == 0 && "$(cat "$CASE_DIR/sysfs/eth0/queues/rx-0/rps_cpus")" == 0 && "$(cat "$CASE_DIR/sysfs/eth0/queues/rx-0/rps_flow_cnt")" == 0 ]] || { fail 'RPS round-trip lost original kernel or queue values'; return 1; }
  assert_completed
)

test_rps_sysctl_marker_precedes_write() (
  setup
  CHECK_RPS_MARKER=1
  start_rps_apply supported || { fail 'RPS sysctl write started before its snapshot and marker existed'; return 1; }
  [[ "$(cat "$KERNEL_DIR/net.core.rps_sock_flow_entries")" == 32768 ]] || { fail 'RPS marker order control never reached the write'; return 1; }
)

test_rps_without_auxiliary_mutation_needs_no_snapshot() (
  setup
  start_rps_apply "$1" || { fail "$1 RPS apply failed"; return 1; }
  [[ ! -e "$STATE_DIR/rps-sysctl.before" && ! -e "$STATE_DIR/rps-sysctl-changed" && ! -s "$CASE_DIR/sysctl-writes" ]] || { fail 'RPS claimed auxiliary ownership without changing the key'; return 1; }
  rollback_internal || { fail "$1 RPS incorrectly required an auxiliary snapshot"; return 1; }
  if [[ "$1" == unsupported ]]; then
    [[ "$(cat "$CASE_DIR/sysfs/eth0/queues/rx-0/rps_cpus")" == 0 && "$(cat "$CASE_DIR/sysfs/eth0/queues/rx-0/rps_flow_cnt")" == 0 ]] || { fail 'queue-only RPS rollback lost originals'; return 1; }
  else
    [[ "$(cat "$KERNEL_DIR/net.core.rps_sock_flow_entries")" == 0 ]] || { fail 'no-queue RPS changed the auxiliary sysctl'; return 1; }
  fi
  assert_completed
)

test_repeated_rps_apply_keeps_missing_original_detectable() (
  setup
  start_rps_apply supported || { fail 'RPS missing-original fixture failed'; return 1; }
  rm "$STATE_DIR/rps-sysctl.before"
  cp -a "$STATE_DIR" "$CASE_DIR/expected-state"
  cp "$CASE_DIR/sysctl-writes" "$CASE_DIR/expected-writes"
  if apply_rps; then fail 'repeated RPS apply replaced a lost original with the tuned value'; return 1; fi
  [[ ! -e "$STATE_DIR/rps-sysctl.before" && "$(cat "$KERNEL_DIR/net.core.rps_sock_flow_entries")" == 32768 ]] || { fail 'repeated RPS apply fabricated a missing baseline'; return 1; }
  cmp -s "$CASE_DIR/sysctl-writes" "$CASE_DIR/expected-writes" || { fail 'repeated RPS apply wrote despite its missing original'; return 1; }
  assert_retained
)

test_rps_sysctl_marker_cleanup_failure_is_retryable() (
  setup
  start_rps_apply supported || { fail 'RPS cleanup fixture failed'; return 1; }
  cp -a "$STATE_DIR" "$CASE_DIR/expected-state"
  rm() {
    local path failed=0
    for path in "$@"; do
      case "$path" in
        --|-f) ;;
        "$STATE_DIR/rps-sysctl-changed") failed=1 ;;
        *) command rm -f -- "$path" || failed=1 ;;
      esac
    done
    return "$failed"
  }
  if rollback_internal; then fail 'RPS marker deletion failure reported completed cleanup'; return 1; fi
  assert_retained || return 1
  unset -f rm
  rollback_internal || { fail 'RPS marker cleanup failure could not be retried'; return 1; }
  [[ "$(cat "$KERNEL_DIR/net.core.rps_sock_flow_entries")" == 0 ]] || { fail 'RPS cleanup retry lost the initial original'; return 1; }
  assert_completed
)

test_legacy_rps_sysctl_snapshot_still_restores() (
  setup
  start_rps_apply supported || { fail 'legacy RPS fixture failed'; return 1; }
  rm -f "$STATE_DIR/rps-sysctl-changed"
  rollback_internal || { fail 'legacy complete RPS snapshot was refused'; return 1; }
  [[ "$(cat "$KERNEL_DIR/net.core.rps_sock_flow_entries")" == 0 ]] || { fail 'legacy RPS auxiliary original was not restored'; return 1; }
  assert_completed
)

failures=0
run_case() {
  if "$@"; then printf 'PASS: %s\n' "$*"; else failures=$((failures + 1)); fi
}
for kind in existing dangling; do run_case test_gai_symlink_preserves_target "$kind"; done
run_case test_gai_regular_round_trip
run_case test_gai_active_symlink_is_noop
for kind in missing empty whitespace invalid; do
  run_case test_rps_damaged_backup_is_retained "$kind"
  run_case test_ring_damaged_backup_is_retained "$kind"
done
for kind in empty whitespace invalid; do run_case test_rps_sysctl_damaged_backup_is_retained "$kind"; done
for kind in original rps rps-sysctl rps-flow ring; do run_case test_no_lf_restores_last_record "$kind"; done
for kind in original rps rps-sysctl ring; do
  for failure in write readback; do run_case test_no_lf_failure_is_retained "$kind" "$failure"; done
done
for kind in missing empty whitespace invalid; do run_case test_applied_rps_sysctl_damaged_snapshot_is_retained "$kind"; done
run_case test_applied_rps_sysctl_round_trip
run_case test_rps_sysctl_marker_precedes_write
for kind in unsupported no-queues; do run_case test_rps_without_auxiliary_mutation_needs_no_snapshot "$kind"; done
run_case test_legacy_rps_sysctl_snapshot_still_restores
run_case test_repeated_rps_apply_keeps_missing_original_detectable
run_case test_rps_sysctl_marker_cleanup_failure_is_retryable
[[ "$failures" == 0 ]]
