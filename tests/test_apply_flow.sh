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
      if [[ "$key" == "$FAIL_SYSCTL_KEY" && "$value" == fq ]]; then return 1; fi
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
  [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_congestion_control")" == bbr ]] || fail 'default plan was not applied'
  [[ "$(cat "$KERNEL_DIR/net.core.default_qdisc")" == fq ]] || fail 'default qdisc was not applied'
  [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf")" == 1 ]] || fail 'receive-buffer autotuning was not enabled'
  local key
  for key in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_ecn; do
    cmp -s "$KERNEL_DIR/$key" "$CASE_DIR/original-kernel/$key" || fail "one-click tuning changed an unspecified value: $key"
  done
  [[ "$(cat "$GAI_FILE")" == '# Original address selection' ]] || fail 'one-click tuning changed IPv4 preference'
}

assert_backed_up_and_reversible() {
  [[ -f "$STATE_DIR/original-values" && -f "$BACKUP_DIR/sysctl-file" ]] || fail 'tuning did not save its baseline'
  cmp -s "$BACKUP_DIR/sysctl-file" "$CASE_DIR/original.conf" || fail 'backed-up configuration is not the original'
  grep -qx 'net.ipv4.tcp_congestion_control=cubic' "$STATE_DIR/original-values" || fail 'original algorithm was not recorded'
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
  verify_tuning > "$CASE_DIR/verify" || fail 'manual tuning did not persist its chosen plan'
)

test_manual_failure_recovers() (
  local language
  for language in zh en; do
    setup_case "failure-$language"
    np_set_language "$language"
    FAIL_SYSCTL_KEY=net.core.default_qdisc
    printf '3\n\n\ny\n0\n' > "$CASE_DIR/input"
    menu < "$CASE_DIR/input" > "$CASE_DIR/output" 2>&1 || fail 'menu could not continue after a tuning failure'
    grep -q '^net.ipv4.tcp_congestion_control=bbr$' "$CASE_DIR/writes" || fail 'failure case did not exercise a partial write'
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
  assert_backed_up_and_reversible
)

test_apply_command_rejects_invalid_options() (
  local variant
  local -a args=()
  for variant in profile path unknown; do
    setup_case "invalid-$variant"
    case "$variant" in
      profile) args=(--profile magic) ;;
      path) args=(--bandwidth 100) ;;
      unknown) args=(--unknown) ;;
    esac
    if main --lang en apply --yes "${args[@]}" < /dev/null > "$CASE_DIR/output" 2>&1; then fail "apply accepted invalid $variant options"; fi
    grep -Eq 'profile must be|Provide both|Unknown option' "$CASE_DIR/output" || fail 'invalid tune options did not reach the plan validator'
    [[ ! -s "$CASE_DIR/prompts" && ! -s "$CASE_DIR/writes" && ! -e "$STATE_DIR" ]] || fail 'invalid tune options prompted or changed state'
    diff -r "$KERNEL_DIR" "$CASE_DIR/original-kernel" > "$CASE_DIR/kernel-diff" || fail 'invalid tune options changed kernel values'
    cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'invalid tune options changed persisted configuration'
  done
)

failures=0
for test in test_bilingual_default_application test_manual_tuning_retained test_manual_failure_recovers test_apply_command_defaults_and_language test_apply_command_forwards_plan_options test_apply_command_rejects_invalid_options; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
