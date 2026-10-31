#!/usr/bin/env bash
set -Eeuo pipefail
[[ $(uname -s) == Linux && ${BASH_VERSINFO[0]} -ge 4 ]] || { printf 'Tests require Linux and Bash 4+.\n' >&2; exit 2; }
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Run the production menu, planner, application, persistence and rollback.
# Only constant paths are relocated; no startup or actual kernel writes run.
# The formatter definitions are extracted from the selected production script.
# shellcheck source=/dev/null
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
awk '/^log\(\)/ {p=1} /^# CLI entry point/ {exit} p {print}' "$SCRIPT" |
  sed "s@/etc/sysctl.d@$TMP/sysctl.d@g; s@/run/netpilot.lock@$TMP/operation.lock@g" > "$TMP/functions.sh"
# This generated file contains production functions with relocated write paths.
# shellcheck source=/dev/null
source "$TMP/functions.sh"
# Load the real command dispatcher without running the script's startup guard.
# shellcheck source=/dev/null
source <(sed -n '/^main() {/,/^}/p' "$SCRIPT")
# These globals are consumed by the dynamically loaded production functions.
# shellcheck disable=SC2034
{
  declare -a SYSCTL_KEYS=()
  declare -A SYSCTL_TARGETS=()
  RED=''; GREEN=''; YELLOW=''; NC=''; NIC_IFACE=''
  SOURCE_PATH="$SCRIPT"; SOURCE_SNAPSHOT=''; SCRIPT_PATH=''; RESOLVED_SOURCE=''
  UPDATE_URL='https://github.com/luckiestultra/netpilot/raw/refs/heads/main/netpilot.sh'
  MSS_COMMENT=netpilot
}

# Assign every production path used by the extracted functions to this case's
# temporary directory; static analysis cannot see their dynamic consumers.
# shellcheck disable=SC2034
setup_case() {
  CASE_DIR="$TMP/$1"; KERNEL_DIR="$CASE_DIR/kernel"
  STATE_DIR="$CASE_DIR/state"; BACKUP_DIR="$STATE_DIR/backup"
  SYSCTL_FILE="$CASE_DIR/sysctl.d/99-netpilot.conf"
  BBR_FILE="$CASE_DIR/sysctl.d/10-netpilot-bbr.conf"
  BBR_MODULE_FILE="$CASE_DIR/modules.conf"; LIMITS_FILE="$CASE_DIR/limits.conf"
  GAI_FILE="$CASE_DIR/gai.conf"
  INSTALL_PATH="$CASE_DIR/install/netpilot.sh"; SHORTCUT_PATH="$CASE_DIR/install/netpilot"
  FAIL_SYSCTL_KEY=''; SYSCTL_KEYS=(); SYSCTL_TARGETS=()
  mkdir -p "$KERNEL_DIR" "$(dirname "$SYSCTL_FILE")"
  printf 'reno cubic bbr\n' > "$KERNEL_DIR/net.ipv4.tcp_available_congestion_control"
  printf 'cubic\n' > "$KERNEL_DIR/net.ipv4.tcp_congestion_control"
  printf 'fq_codel\n' > "$KERNEL_DIR/net.core.default_qdisc"
  printf '0\n' > "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf"
  printf '212992\n' > "$KERNEL_DIR/net.core.rmem_max"
  printf '212992\n' > "$KERNEL_DIR/net.core.wmem_max"
  printf '4096 131072 6291456\n' > "$KERNEL_DIR/net.ipv4.tcp_rmem"
  printf '4096 16384 4194304\n' > "$KERNEL_DIR/net.ipv4.tcp_wmem"
  printf '0\n' > "$KERNEL_DIR/net.ipv4.tcp_ecn"
  cp -a "$KERNEL_DIR" "$CASE_DIR/original-kernel"
  printf '# Managed by netpilot.sh.\nnet.ipv4.tcp_ecn = 0\n' > "$SYSCTL_FILE"
  cp -a "$SYSCTL_FILE" "$CASE_DIR/original.conf"
  printf '# Original address selection\n' > "$GAI_FILE"
  : > "$CASE_DIR/prompts"; : > "$CASE_DIR/writes"
}

# File-backed kernel values survive command substitutions and allow real
# read-back verification, partial-write recovery and baseline restoration.
sysctl() {
  local key value
  case "${1:-}" in
    -n) [[ $# == 2 && -f "$KERNEL_DIR/$2" ]] || return 1; cat "$KERNEL_DIR/$2" ;;
    -w)
      [[ $# == 2 && "$2" == *=* ]] || return 1
      key="${2%%=*}"; value="${2#*=}"
      [[ "$key" =~ ^net\.[a-zA-Z0-9_.]+$ && -f "$KERNEL_DIR/$key" ]] || return 1
      printf '%s\n' "$2" >> "$CASE_DIR/writes"
      if [[ "$key" == "$FAIL_SYSCTL_KEY" && "$value" != "$(cat "$CASE_DIR/original-kernel/$key")" ]]; then return 1; fi
      printf '%s\n' "$value" > "$KERNEL_DIR/$key"
      printf '%s = %s\n' "$key" "$value" ;;
    *) [[ $# == 1 && -f "$KERNEL_DIR/$1" ]] || return 1; printf '%s = %s\n' "$1" "$(cat "$KERNEL_DIR/$1")" ;;
  esac
}

# Capture prompts that Bash normally hides for redirected input, while letting
# the real builtin consume exactly the supplied menu answers.
read() {
  local prompt_index next_index
  for ((prompt_index=1; prompt_index<=$#; prompt_index++)); do
    if [[ "${!prompt_index}" == -p ]]; then
      next_index=$((prompt_index + 1))
      printf '%s\n' "${!next_index}" >> "$CASE_DIR/prompts"
    fi
  done
  builtin read "$@"
}

# Guard unrelated mutation interfaces even if menu dispatch regresses.
network_interfaces() { fail 'one-click flow must not adjust NIC hardware'; }
modprobe() { fail 'one-click flow must not load modules'; }
iptables() { fail 'one-click flow must not change firewall rules'; }
curl() { fail 'one-click flow must not download or benchmark'; }

assert_default_values() {
  cmp -s "$KERNEL_DIR/net.ipv4.tcp_congestion_control" "$CASE_DIR/original-kernel/net.ipv4.tcp_congestion_control" || fail 'default plan changed the current congestion algorithm'
  cmp -s "$KERNEL_DIR/net.core.default_qdisc" "$CASE_DIR/original-kernel/net.core.default_qdisc" || fail 'default plan changed the current default queue'
  [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf")" == 1 ]] || fail 'receive-buffer autotuning was not enabled'
  local key
  for key in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_ecn; do
    cmp -s "$KERNEL_DIR/$key" "$CASE_DIR/original-kernel/$key" || fail "one-click tuning changed an unspecified value: $key"
  done
  [[ "$(cat "$GAI_FILE")" == '# Original address selection' ]] || fail 'one-click tuning changed IPv4 preference'
}

assert_measured_buffer_values() {
  local key value
  cmp -s "$KERNEL_DIR/net.ipv4.tcp_congestion_control" "$CASE_DIR/original-kernel/net.ipv4.tcp_congestion_control" || fail 'measured manual plan changed the current algorithm'
  cmp -s "$KERNEL_DIR/net.core.default_qdisc" "$CASE_DIR/original-kernel/net.core.default_qdisc" || fail 'measured manual plan changed the default queue'
  [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf")" == 1 ]] || fail 'measured plan skipped receive autotuning'
  for key in net.core.rmem_max net.core.wmem_max; do
    value="$(cat "$KERNEL_DIR/$key")"
    [[ "$value" -gt "$(cat "$CASE_DIR/original-kernel/$key")" && "$value" == "${SYSCTL_TARGETS[$key]:-}" ]] || fail "measured BDP buffer was not applied: $key"
  done
}

assert_backed_up_and_reversible() {
  [[ -f "$STATE_DIR/original-values" && -f "$BACKUP_DIR/sysctl-file" ]] || fail 'tuning did not save its baseline'
  cmp -s "$BACKUP_DIR/sysctl-file" "$CASE_DIR/original.conf" || fail 'backed-up configuration is not the original'
  grep -qx 'net.ipv4.tcp_moderate_rcvbuf=0' "$STATE_DIR/original-values" || fail 'original changed receive setting was not recorded'
  verify_tuning > "$CASE_DIR/verify" || fail 'persisted values do not match their read-back'
  run_mutation rollback_tuning > "$CASE_DIR/rollback" 2>&1 || fail 'tuning changes could not be rolled back'
  diff -r "$KERNEL_DIR" "$CASE_DIR/original-kernel" > "$CASE_DIR/kernel-diff" || fail 'rollback did not restore kernel values'
  cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'rollback did not restore the original configuration'
  [[ ! -e "$STATE_DIR" ]] || fail 'successful rollback retained its state'
}

test_bilingual_default_application() (
  local language
  for language in zh en; do
    setup_case "one-click-$language"
    np_set_language "$language"
    apply_tuning --yes < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'default application failed'
    if [[ "$language" == zh ]]; then
      grep -q '配置档：balanced' "$CASE_DIR/output" || fail 'Chinese one-click flow did not use balanced defaults'
    else
      grep -q 'Profile: balanced' "$CASE_DIR/output" || fail 'English one-click flow did not use balanced defaults'
    fi
    [[ ! -s "$CASE_DIR/prompts" ]] || fail 'explicit --yes application requested extra answers'
    [[ "$PLAN_PROFILE" == balanced && -z "$PLAN_BANDWIDTH" && -z "$PLAN_RTT" ]] || fail 'one-click flow invented path measurements'
    assert_default_values
    assert_backed_up_and_reversible
  done
)

test_manual_tuning_retained() (
  setup_case manual
  np_set_language en
  printf '3\nproxy\n100\n50\ny\n0\n' > "$CASE_DIR/input"
  menu < "$CASE_DIR/input" > "$CASE_DIR/output" 2>&1 || fail 'manual tuning menu failed'
  [[ "$PLAN_PROFILE" == proxy && "$PLAN_BANDWIDTH" == 100 && "$PLAN_RTT" == 50 ]] || fail 'manual tuning ignored path/profile input'
  [[ "$(wc -l < "$CASE_DIR/prompts")" == 6 ]] || fail 'manual tuning no longer asks for its options and confirmation'
  grep -q 'Apply and persist' "$CASE_DIR/prompts" || fail 'manual tuning lost its confirmation'
  assert_measured_buffer_values
  verify_tuning > "$CASE_DIR/verify" || fail 'manual tuning did not persist its chosen plan'
)

test_manual_failure_recovers() (
  local language
  for language in zh en; do
    setup_case "failure-$language"
    np_set_language "$language"
    FAIL_SYSCTL_KEY=net.core.rmem_max
    printf '3\n\n100\n50\ny\n0\n' > "$CASE_DIR/input"
    menu < "$CASE_DIR/input" > "$CASE_DIR/output" 2>&1 || fail 'menu could not continue after a tuning failure'
    grep -q '^net.ipv4.tcp_moderate_rcvbuf=1$' "$CASE_DIR/writes" || fail 'failure case did not exercise a partial receive write'
    if [[ "$language" == zh ]]; then
      grep -q '操作失败。' "$CASE_DIR/output" || fail 'Chinese menu hid the tuning failure'
    else
      grep -q 'Operation failed.' "$CASE_DIR/output" || fail 'English menu hid the tuning failure'
    fi
    ! grep -Eq '计划已应用且读回一致|Plan applied and read back consistently' "$CASE_DIR/output" || fail 'failed one-click flow claimed success'
    diff -r "$KERNEL_DIR" "$CASE_DIR/original-kernel" > "$CASE_DIR/kernel-diff" || fail 'failed one-click flow did not restore partial writes'
    cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'failed one-click flow did not restore its configuration'
    [[ ! -e "$STATE_DIR" ]] || fail 'successful recovery retained stale application state'
  done
)

test_apply_command_defaults_and_language() (
  local language
  for language in zh en; do
    setup_case "command-$language"
    unset NETPILOT_LANG
    if [[ "$language" == zh ]]; then
      main apply --yes < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'apply is not a working independent command'
      grep -q '配置档：balanced' "$CASE_DIR/output" || fail 'tune does not default to Chinese and balanced'
    else
      main --lang en apply --yes < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'English apply command failed'
      grep -q 'Profile: balanced' "$CASE_DIR/output" || fail 'tune ignored English language selection'
    fi
    [[ ! -s "$CASE_DIR/prompts" ]] || fail 'tune required interactive input'
    [[ "$PLAN_PROFILE" == balanced && -z "$PLAN_BANDWIDTH" && -z "$PLAN_RTT" ]] || fail 'tune invented default path inputs'
    assert_default_values
    assert_backed_up_and_reversible
  done
)

test_apply_command_forwards_plan_options() (
  setup_case command-options
  main --lang en apply --yes --profile proxy --bandwidth 100 --rtt 50 < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'apply rejected valid plan options'
  [[ "$PLAN_PROFILE" == proxy && "$PLAN_BANDWIDTH" == 100 && "$PLAN_RTT" == 50 ]] || fail 'tune failed to forward plan options'
  [[ ! -s "$CASE_DIR/prompts" ]] || fail 'tune with plan options asked for confirmation'
  assert_measured_buffer_values
  assert_backed_up_and_reversible
)

test_apply_command_rejects_invalid_options() (
  local variant
  local -a args=()
  for variant in profile path unknown; do
    setup_unloaded_bbr_case "invalid-$variant"
    modprobe() { printf 'called\n' >> "$CASE_DIR/module-calls"; }
    case "$variant" in
      profile) args=(--profile magic) ;;
      path) args=(--bandwidth 100) ;;
      unknown) args=(--unknown) ;;
    esac
    if main --lang en apply --yes "${args[@]}" < /dev/null > "$CASE_DIR/output" 2>&1; then fail "apply accepted invalid $variant options"; fi
    [[ ! -s "$CASE_DIR/module-calls" ]] || fail 'invalid input loaded a kernel module'
    grep -Eq 'profile must be|Provide both|Unknown option' "$CASE_DIR/output" || fail 'invalid tune options did not reach the plan validator'
    [[ ! -s "$CASE_DIR/prompts" && ! -s "$CASE_DIR/writes" && ! -e "$STATE_DIR" ]] || fail 'invalid tune options prompted or changed state'
    diff -r "$KERNEL_DIR" "$CASE_DIR/original-kernel" > "$CASE_DIR/kernel-diff" || fail 'invalid tune options changed kernel values'
    cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'invalid tune options changed persisted configuration'
  done
)


# Match a stock VPS whose BBR module exists but is not loaded, and whose
# buffers already exceed the measured recommendation.
setup_unloaded_bbr_case() {
  setup_case "$1"
  printf 'reno cubic\n' > "$KERNEL_DIR/net.ipv4.tcp_available_congestion_control"
  printf '1\n' > "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf"
  printf '4194304\n' > "$KERNEL_DIR/net.core.rmem_max"
  printf '4194304\n' > "$KERNEL_DIR/net.core.wmem_max"
  cp -a "$KERNEL_DIR/." "$CASE_DIR/original-kernel/"
  : > "$CASE_DIR/module-calls"
}

test_explicit_menu_bbr_loads_installed_module() (
  local language
  for language in zh en; do
    setup_unloaded_bbr_case "unloaded-$language"
    np_set_language "$language"
    modprobe() {
      [[ "$*" == tcp_bbr ]] || fail 'unexpected module requested'
      printf 'called\n' >> "$CASE_DIR/module-calls"
      printf 'reno cubic bbr\n' > "$KERNEL_DIR/net.ipv4.tcp_available_congestion_control"
    }
    printf '2\n0\n' > "$CASE_DIR/input"
    menu < "$CASE_DIR/input" > "$CASE_DIR/output" 2>&1 || fail 'explicit BBR menu failed'
    [[ "$(wc -l < "$CASE_DIR/module-calls")" == 1 ]] || fail 'explicit BBR skipped the installed module'
    [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_congestion_control")" == bbr ]] || fail 'apply did not enable newly available BBR'
    [[ "$(cat "$KERNEL_DIR/net.core.default_qdisc")" == fq ]] || fail 'apply did not select default FQ'
    grep -qx tcp_bbr "$BBR_MODULE_FILE" || fail 'BBR module is not persisted for boot'
    grep -qx 'net.ipv4.tcp_congestion_control=cubic' "$STATE_DIR/original-values" || fail 'original algorithm was not backed up'
    grep -qx 'net.core.default_qdisc=fq_codel' "$STATE_DIR/original-values" || fail 'original default queue was not backed up'
    ! grep -Eq '以上仅为计划|This is a plan only' "$CASE_DIR/output" || fail 'application prints a preview-only footer'
    verify_tuning > "$CASE_DIR/verify" || fail 'new BBR configuration failed read-back verification'
    run_mutation rollback_tuning > "$CASE_DIR/rollback" 2>&1 || fail 'new BBR configuration could not be restored'
    [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_congestion_control")" == cubic ]] || fail 'rollback did not restore cubic'
    [[ "$(cat "$KERNEL_DIR/net.core.default_qdisc")" == fq_codel ]] || fail 'rollback did not restore the default queue'
    [[ ! -e "$BBR_MODULE_FILE" ]] || fail 'rollback retained newly created module persistence'
  done
)

test_default_preserves_unloaded_bbr() (
  local language
  for language in zh en; do
    setup_unloaded_bbr_case "preserve-unloaded-$language"
    np_set_language "$language"
    modprobe() {
      printf 'called\n' >> "$CASE_DIR/module-calls"
      printf 'reno cubic bbr\n' > "$KERNEL_DIR/net.ipv4.tcp_available_congestion_control"
    }
    apply_tuning --yes --bandwidth 1531 --rtt 1.224 < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'default apply failed when BBR is unloaded'
    [[ ! -s "$CASE_DIR/module-calls" ]] || fail 'default apply loaded the unmeasured alternative algorithm'
    diff -r "$KERNEL_DIR" "$CASE_DIR/original-kernel" > "$CASE_DIR/kernel-diff" || fail 'satisfied default plan changed current kernel values'
    [[ ! -e "$BBR_MODULE_FILE" && ! -e "$STATE_DIR" ]] || fail 'satisfied default plan created BBR persistence or rollback state'
    cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'satisfied default plan rewrote its configuration'
    ! grep -Eq '以上仅为计划|This is a plan only' "$CASE_DIR/output" || fail 'application prints a preview-only footer'
  done
)

test_default_preserves_current_algorithm_and_admin_module() (
  local algorithm inode
  for algorithm in cubic bbr reno; do
    setup_case "preserve-current-$algorithm"
    printf '%s\n' "$algorithm" > "$KERNEL_DIR/net.ipv4.tcp_congestion_control"
    if [[ "$algorithm" == cubic ]]; then printf 'reno cubic\n' > "$KERNEL_DIR/net.ipv4.tcp_available_congestion_control"; fi
    : > "$CASE_DIR/module-calls"
    modprobe() { printf 'called\n' >> "$CASE_DIR/module-calls"; return 1; }
    cp -a "$KERNEL_DIR/." "$CASE_DIR/original-kernel/"
    printf '# Administrator module configuration\n' > "$CASE_DIR/admin-module"
    ln "$CASE_DIR/admin-module" "$BBR_MODULE_FILE"
    inode="$(stat -c %i "$BBR_MODULE_FILE")"
    apply_tuning --yes < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'default apply was blocked by unrelated administrator module settings'
    assert_default_values
    [[ ! -s "$CASE_DIR/module-calls" ]] || fail 'default apply attempted module loading beside administrator settings'
    [[ "$(stat -c %i "$BBR_MODULE_FILE")" == "$inode" ]] || fail 'default apply replaced an administrator module inode'
    cmp -s "$BBR_MODULE_FILE" "$CASE_DIR/admin-module" || fail 'default apply changed administrator module settings'
    [[ ! -e "$BACKUP_DIR/bbr-module-file" ]] || fail 'default apply claimed an unchanged module file'
    assert_backed_up_and_reversible
    [[ "$(stat -c %i "$BBR_MODULE_FILE")" == "$inode" ]] || fail 'rollback touched an unrelated administrator module inode'
  done
)

test_explicit_unavailable_bbr_does_not_claim_success() (
  setup_unloaded_bbr_case explicit-unavailable
  modprobe() { printf 'called\n' >> "$CASE_DIR/module-calls"; return 1; }
  if apply_bbr_only > "$CASE_DIR/output" 2>&1; then fail 'explicit BBR claimed success after module load failure'; fi
  [[ "$(wc -l < "$CASE_DIR/module-calls")" == 1 ]] || fail 'explicit BBR did not attempt the supplied kernel module'
  [[ ! -s "$CASE_DIR/writes" && ! -e "$STATE_DIR" && ! -e "$BBR_MODULE_FILE" ]] || fail 'failed explicit module loading claimed or mutated configuration'
  diff -r "$KERNEL_DIR" "$CASE_DIR/original-kernel" > "$CASE_DIR/kernel-diff" || fail 'failed explicit module loading changed kernel settings'
)

test_cancel_does_not_load_bbr() (
  setup_unloaded_bbr_case unloaded-cancel
  modprobe() { printf 'called\n' >> "$CASE_DIR/module-calls"; }
  apply_tuning <<< n > "$CASE_DIR/output" 2>&1 || fail 'cancel failed'
  [[ ! -s "$CASE_DIR/module-calls" && ! -s "$CASE_DIR/writes" && ! -e "$STATE_DIR" ]] || fail 'cancel loaded a module or wrote settings'
)

test_unavailable_bbr_keeps_basic_tuning() (
  setup_unloaded_bbr_case unloaded-unavailable
  printf '0\n' > "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf"
  modprobe() { printf 'called\n' >> "$CASE_DIR/module-calls"; return 1; }
  apply_tuning --yes < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'unavailable BBR blocked supported basic tuning'
  [[ ! -s "$CASE_DIR/module-calls" ]] || fail 'default application attempted a hidden BBR module load'
  [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_congestion_control")" == cubic ]] || fail 'unavailable BBR changed the algorithm'
  [[ "$(cat "$KERNEL_DIR/net.core.default_qdisc")" == fq_codel ]] || fail 'unavailable BBR changed the default queue'
  [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf")" == 1 ]] || fail 'supported basic tuning was skipped'
  [[ ! -e "$BBR_MODULE_FILE" ]] || fail 'unavailable module was persisted'
  ! grep -Eq 'Trying to load|正在尝试加载' "$CASE_DIR/output" || fail 'default application advertised a hidden module attempt'
)


test_explicit_bbr_preflight_preserves_admin_hardlink() (
  setup_unloaded_bbr_case unloaded-file-conflict
  printf '# Administrator module configuration\n' > "$CASE_DIR/admin-module"
  ln "$CASE_DIR/admin-module" "$BBR_MODULE_FILE"
  local inode
  inode="$(stat -c %i "$BBR_MODULE_FILE")"
  modprobe() { printf 'reno cubic bbr\n' > "$KERNEL_DIR/net.ipv4.tcp_available_congestion_control"; }
  if apply_bbr_only > "$CASE_DIR/output" 2>&1; then fail 'explicit BBR accepted an unowned module hardlink'; fi
  [[ "$(cat "$BBR_MODULE_FILE")" == '# Administrator module configuration' ]] || fail 'unowned module configuration was changed'
  [[ "$(stat -c %i "$BBR_MODULE_FILE")" == "$inode" ]] || fail 'failed application replaced an unowned module inode'
  [[ ! -e "$STATE_DIR" ]] || fail 'unowned module configuration was claimed by recovery state'
  [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_congestion_control")" == cubic ]] || fail 'failed persistence changed the algorithm'
  [[ "$(cat "$KERNEL_DIR/net.core.default_qdisc")" == fq_codel ]] || fail 'failed persistence changed the default queue'
  cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'failed module persistence left a rewritten sysctl file'
)


test_advanced_bbr_preflight_preserves_admin_symlink() (
  setup_case advanced-admin-module
  printf '# Administrator module configuration\n' > "$CASE_DIR/admin-module"
  ln -s "$CASE_DIR/admin-module" "$BBR_MODULE_FILE"
  if apply_bbr_only > "$CASE_DIR/output" 2>&1; then fail 'advanced BBR accepted an administrator symlink'; fi
  [[ -L "$BBR_MODULE_FILE" && ! -e "$STATE_DIR" && ! -s "$CASE_DIR/writes" ]] || fail 'advanced BBR claimed or modified an unowned module file'
  cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'advanced BBR preflight changed sysctl configuration'
)

failures=0
for test in test_bilingual_default_application test_manual_tuning_retained test_manual_failure_recovers test_apply_command_defaults_and_language test_apply_command_forwards_plan_options test_apply_command_rejects_invalid_options test_explicit_menu_bbr_loads_installed_module test_default_preserves_unloaded_bbr test_default_preserves_current_algorithm_and_admin_module test_explicit_unavailable_bbr_does_not_claim_success test_cancel_does_not_load_bbr test_unavailable_bbr_keeps_basic_tuning test_explicit_bbr_preflight_preserves_admin_hardlink test_advanced_bbr_preflight_preserves_admin_symlink; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
