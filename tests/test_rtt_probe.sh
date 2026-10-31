#!/usr/bin/env bash
set -Eeuo pipefail
[[ $(uname -s) == Linux && ${BASH_VERSINFO[0]} -ge 4 ]] || { printf 'Tests require Linux and Bash 4+.\n' >&2; exit 2; }
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
REAL_PATH="$PATH"
NETPILOT_TEST_REAL_TIMEOUT="$(command -v timeout)"
export NETPILOT_TEST_REAL_TIMEOUT
REAL_PING="$(command -v ping)"
[[ -n "$NETPILOT_TEST_REAL_TIMEOUT" && -n "$REAL_PING" ]] || { printf 'Real timeout and ping are required.\n' >&2; exit 2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Runtime extraction keeps production parsing, planning and mutation guards.
# shellcheck source=/dev/null
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
awk '/^log\(\)/ {p=1} /^# CLI entry point/ {exit} p {print}' "$SCRIPT" |
  sed "s@/etc/sysctl.d@$TMP/sysctl.d@g; s@/run/netpilot.lock@$TMP/operation.lock@g" > "$TMP/functions.sh"
# shellcheck source=/dev/null
source "$TMP/functions.sh"
# shellcheck source=/dev/null
source <(sed -n '/^main() {/,/^}/p' "$SCRIPT")
# Globals consumed by dynamically loaded production functions.
# shellcheck disable=SC2034
{
  declare -a SYSCTL_KEYS=()
  declare -A SYSCTL_TARGETS=()
  RED=''; GREEN=''; YELLOW=''; NC=''; NIC_IFACE=''
}

mkdir "$TMP/bin"
cat > "$TMP/bin/ping" <<'PING'
#!/bin/bash
printf 'LC_ALL=%s\n' "${LC_ALL:-unset}" >> "$RTT_PING_LOG"
printf 'ARG:%s\n' "$@" >> "$RTT_PING_LOG"
case "$RTT_SCENARIO" in
  wall-timeout)
    printf '5 packets transmitted, 5 received, 0%% packet loss\nrtt min/avg/max/mdev = 1/2/3/1 ms\n'
    exec /bin/sleep 30 ;;
  busybox)
    printf '5 packets transmitted, 5 packets received, 0%% packet loss\nround-trip min/avg/max = 11.000/12.345/14.000 ms\n'
    exit 0 ;;
  unavailable) printf 'ping: unavailable\n' >&2; exit 2 ;;
  no-answer) printf '5 packets transmitted, 0 received, 100%% packet loss\n'; exit 1 ;;
  few) received=2; average=12.345 ;;
  too-many) received=6; average=12.345 ;;
  parse) received=5; average=broken ;;
  zero) received=5; average=0.000 ;;
  huge) received=5; average=60000.001 ;;
  *) received=3; average=12.345 ;;
esac
printf '%s\n' '--- target ping statistics ---'
printf '5 packets transmitted, %s received, 40%% packet loss, time 4001ms\n' "$received"
printf 'rtt min/avg/max/mdev = 11.000/%s/14.000/1.000 ms\n' "$average"
PING
cat > "$TMP/bin/timeout" <<'TIMEOUT'
#!/bin/bash
printf 'LC_ALL=%s\n' "${LC_ALL:-unset}" >> "$RTT_TIMEOUT_LOG"
printf 'ARG:%s\n' "$@" >> "$RTT_TIMEOUT_LOG"
if [[ "$RTT_SCENARIO" == timeout ]]; then
  printf '5 packets transmitted, 5 received, 0%% packet loss\nrtt min/avg/max/mdev = 1/2/3/1 ms\n'
  exit 124
fi
if [[ "$RTT_SCENARIO" == wall-timeout ]]; then
  # Keep the original production argv in the log, but use a short deadline to
  # exercise a real GNU timeout without delaying every test run by eight seconds.
  program=(); found=0
  for argument in "$@"; do
    if ((found)); then program+=("$argument")
    elif [[ "$argument" == ping || "$argument" == */ping ]]; then program+=("$argument"); found=1; fi
  done
  ((found)) || exit 2
  exec "$NETPILOT_TEST_REAL_TIMEOUT" --foreground --kill-after=0.1s 0.2s "${program[@]}"
fi
exec "$NETPILOT_TEST_REAL_TIMEOUT" "$@"
TIMEOUT
chmod 0755 "$TMP/bin/ping" "$TMP/bin/timeout"

# All fixture paths are private, including paths only the extracted code reads.
# shellcheck disable=SC2034
setup_case() {
  CASE_DIR="$TMP/$1"; mkdir -p "$CASE_DIR/sysctl.d"
  STATE_DIR="$CASE_DIR/state"; BACKUP_DIR="$STATE_DIR/backup"
  SYSCTL_FILE="$CASE_DIR/sysctl.d/99-netpilot.conf"; BBR_FILE="$CASE_DIR/sysctl.d/10-netpilot-bbr.conf"
  BBR_MODULE_FILE="$CASE_DIR/modules.conf"; LIMITS_FILE="$CASE_DIR/limits.conf"; GAI_FILE="$CASE_DIR/gai.conf"
  INSTALL_PATH="$CASE_DIR/netpilot.sh"; SHORTCUT_PATH="$CASE_DIR/netpilot"
  SOURCE_PATH="$SCRIPT"; SOURCE_SNAPSHOT=''; SCRIPT_PATH=''; RESOLVED_SOURCE=''
  UPDATE_URL='https://github.com/luckiestultra/netpilot/raw/refs/heads/main/netpilot.sh'
  MSS_COMMENT=netpilot
  export PATH="$TMP/bin:$REAL_PATH" RTT_SCENARIO=success
  export RTT_PING_LOG="$CASE_DIR/ping.log" RTT_TIMEOUT_LOG="$CASE_DIR/timeout.log"
  : > "$RTT_PING_LOG"; : > "$RTT_TIMEOUT_LOG"
  printf '# Managed by netpilot.sh.\nnet.ipv4.tcp_ecn = 0\n' > "$SYSCTL_FILE"
  cp "$SYSCTL_FILE" "$CASE_DIR/original.conf"
  np_set_language en
}

# Read-only kernel fixture: any accidental write is recorded and rejected.
sysctl() {
  if [[ "${1:-}" == -w ]]; then printf '%s\n' "$*" >> "$CASE_DIR/kernel-writes"; return 1; fi
  [[ "${1:-}" == -n && $# == 2 ]] || return 1
  case "$2" in
    net.ipv4.tcp_available_congestion_control) printf 'reno cubic bbr\n' ;;
    net.ipv4.tcp_congestion_control) printf 'cubic\n' ;;
    net.core.default_qdisc) printf 'fq_codel\n' ;;
    net.ipv4.tcp_moderate_rcvbuf) printf '0\n' ;;
    net.core.rmem_max|net.core.wmem_max) printf '212992\n' ;;
    net.ipv4.tcp_rmem) printf '4096 131072 6291456\n' ;;
    net.ipv4.tcp_wmem) printf '4096 16384 4194304\n' ;;
    *) return 1 ;;
  esac
}

assert_no_writes() {
  [[ ! -e "$STATE_DIR" && ! -e "$CASE_DIR/kernel-writes" ]] || fail 'RTT processing wrote state or kernel settings'
  cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'RTT processing modified persistent settings'
}

assert_measurement_failed() {
  if adaptive_measure_rtt 127.0.0.1 > "$CASE_DIR/value" 2> "$CASE_DIR/error"; then fail "RTT failure accepted: $RTT_SCENARIO"; fi
  [[ ! -s "$CASE_DIR/value" && -s "$CASE_DIR/error" ]] || fail 'failed RTT probe returned a value or omitted its error'
}

test_probe_contract_and_addresses() (
  declare -F adaptive_measure_rtt >/dev/null || fail 'adaptive_measure_rtt is missing'
  local target value
  for target in 127.0.0.1 ::1 example.com busybox.example; do
    setup_case "target-${target//:/_}"
    [[ "$target" != busybox.example ]] || export RTT_SCENARIO=busybox
    value="$(adaptive_measure_rtt "$target" 2> "$CASE_DIR/error")" || fail "valid RTT target rejected: $target"
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v value="$value" 'BEGIN {exit !(value==12.345)}' || fail 'RTT stdout was not the measured average alone'
    grep -qx 'LC_ALL=C' "$RTT_PING_LOG" || fail 'ping locale was not fixed to C'
    grep -qx 'LC_ALL=C' "$RTT_TIMEOUT_LOG" || fail 'timeout locale was not fixed to C'
    python3 - "$RTT_TIMEOUT_LOG" "$RTT_PING_LOG" "$target" <<'PY' || fail 'ping/timeout argument contract was violated'
from pathlib import Path
import sys
args = [s[4:] for s in Path(sys.argv[1]).read_text().splitlines() if s.startswith('ARG:')]
assert args.count('--foreground') == 1, args
args.remove('--foreground')
kill = None
if args[0].startswith('--kill-after='):
    kill = args.pop(0).split('=', 1)[1]
elif args[0] in ('--kill-after', '-k'):
    args.pop(0); kill = args.pop(0)
elif args[0].startswith('-k'):
    kill = args.pop(0)[2:]
assert kill in ('1', '1s'), ('kill-after', kill)
assert args.pop(0) in ('8', '8s'), args
assert Path(args.pop(0)).name == 'ping', args
ping_args = [s[4:] for s in Path(sys.argv[2]).read_text().splitlines() if s.startswith('ARG:')]
assert args == ping_args
assert ping_args[-2:] == ['--', sys.argv[3]], ping_args
options = ping_args[:-2]
assert options.pop(0) == '-n', options
for flag, value in (('-c', '5'), ('-W', '1')):
    actual = options.pop(0)
    if actual == flag:
        assert options.pop(0) == value
    else:
        assert actual == flag + value, actual
assert not options, options
PY
    [[ ! -s "$CASE_DIR/error" ]] || fail 'successful RTT probe printed an error'
    assert_no_writes
  done
)

test_probe_failure_states() (
  declare -F adaptive_measure_rtt >/dev/null || fail 'RTT probe failure handler is missing'
  local scenario missing dep
  for scenario in timeout wall-timeout unavailable no-answer few too-many parse zero huge; do
    setup_case "probe-$scenario"; export RTT_SCENARIO="$scenario"
    assert_measurement_failed
    assert_no_writes
  done
  for missing in ping timeout; do
    setup_case "missing-$missing"
    mkdir "$CASE_DIR/bin"
    for dep in awk sed grep tr cat head tail basename; do ln -s "$(command -v "$dep")" "$CASE_DIR/bin/$dep"; done
    if [[ "$missing" == ping ]]; then ln -s "$TMP/bin/timeout" "$CASE_DIR/bin/timeout"
    else ln -s "$TMP/bin/ping" "$CASE_DIR/bin/ping"; fi
    PATH="$CASE_DIR/bin" assert_measurement_failed
    [[ ! -s "$RTT_PING_LOG" ]] || fail 'missing dependency still invoked ping'
    assert_no_writes
  done
)

test_default_and_numeric_paths_never_probe() (
  setup_case numeric
  adaptive_show_plan > "$CASE_DIR/default" || fail 'default plan failed'
  [[ -z "${SYSCTL_TARGETS[net.core.rmem_max]+exists}" ]] || fail 'default plan changed buffer ceilings'
  adaptive_show_plan --bandwidth 100 --rtt 50 > "$CASE_DIR/numeric" || fail 'numeric RTT compatibility failed'
  [[ "$PLAN_RTT" == 50 ]] || fail 'numeric RTT was changed'
  [[ ! -s "$RTT_PING_LOG" && ! -s "$RTT_TIMEOUT_LOG" ]] || fail 'default or numeric RTT plan probed the network'
  assert_no_writes
)

test_auto_plan_and_menu_options() (
  setup_case auto-plan
  adaptive_show_plan --bandwidth 100 --rtt-target ::1 > "$CASE_DIR/plan" 2>&1 || fail 'automatic RTT plan was rejected'
  [[ "$PLAN_BANDWIDTH" == 100 ]] && awk -v value="$PLAN_RTT" 'BEGIN {exit !(value==12.345)}' || fail 'automatic RTT was not used by the planner'
  [[ -n "${SYSCTL_TARGETS[net.core.rmem_max]+exists}" ]] || fail 'measured RTT did not influence buffer recommendations'
  grep -Eiq 'RTT.*measur|measur.*RTT' "$CASE_DIR/plan" || fail 'plan does not identify measured RTT'
  grep -Eiq 'bandwidth.*user|user.*bandwidth' "$CASE_DIR/plan" || fail 'plan misrepresents the user-provided bandwidth'
  assert_no_writes

  setup_case menu-auto
  read_plan_options < <(printf 'proxy\n100\n\n::1\n') || fail 'blank RTT did not accept an automatic target'
  [[ "${MENU_PLAN_ARGS[*]}" == '--profile proxy --bandwidth 100 --rtt-target ::1' ]] || fail 'menu did not defer automatic RTT to the planner'
  [[ ! -s "$RTT_PING_LOG" && ! -s "$RTT_TIMEOUT_LOG" ]] || fail 'reading menu options measured RTT prematurely'
  read_plan_options < <(printf 'balanced\n\n') || fail 'blank bandwidth compatibility failed'
  [[ "${MENU_PLAN_ARGS[*]}" == '--profile balanced' ]] || fail 'blank bandwidth unexpectedly added RTT inputs'
  read_plan_options < <(printf 'proxy\n100\n50\n') || fail 'numeric menu RTT compatibility failed'
  [[ "${MENU_PLAN_ARGS[*]}" == '--profile proxy --bandwidth 100 --rtt 50' ]] || fail 'numeric menu RTT was not preserved'
  assert_no_writes
)

test_invalid_auto_options_are_zero_traffic() (
  local variant
  local -a args=()
  for variant in mutual no-bandwidth profile bandwidth target-space target-flag target-url target-newline; do
    setup_case "invalid-$variant"
    case "$variant" in
      mutual) args=(--bandwidth 100 --rtt 50 --rtt-target example.com) ;;
      no-bandwidth) args=(--rtt-target example.com) ;;
      profile) args=(--profile invalid --bandwidth 100 --rtt-target example.com) ;;
      bandwidth) args=(--bandwidth 0 --rtt-target example.com) ;;
      target-space) args=(--bandwidth 100 --rtt-target 'bad host') ;;
      target-flag) args=(--bandwidth 100 --rtt-target '-host') ;;
      target-url) args=(--bandwidth 100 --rtt-target 'https://example.com/path') ;;
      target-newline) args=(--bandwidth 100 --rtt-target $'bad\nhost') ;;
    esac
    if adaptive_plan "${args[@]}" > "$CASE_DIR/output" 2>&1; then fail "invalid auto plan accepted: $variant"; fi
    [[ ! -s "$RTT_PING_LOG" && ! -s "$RTT_TIMEOUT_LOG" ]] || fail "invalid $variant options started a network probe"
    assert_no_writes
  done
)

test_failed_measurement_never_reaches_apply() (
  setup_case apply-failure
  export RTT_SCENARIO=no-answer
  if main --lang en apply --yes --bandwidth 100 --rtt-target 127.0.0.1 > "$CASE_DIR/command" 2>&1; then fail 'apply accepted a failed RTT measurement'; fi
  [[ -s "$RTT_PING_LOG" ]] || fail 'command did not reach RTT measurement'
  assert_no_writes
  ! grep -Eq 'Plan applied and read back consistently|计划已应用且读回一致' "$CASE_DIR/command" || fail 'failed measurement claimed application success'
  : > "$RTT_PING_LOG"
  if menu_apply_tuning < <(printf 'proxy\n100\n\n::1\n') > "$CASE_DIR/menu" 2>&1; then fail 'menu apply accepted a failed RTT measurement'; fi
  [[ -s "$RTT_PING_LOG" ]] || fail 'menu apply did not reach RTT measurement'
  assert_no_writes
  ! grep -Eq 'Plan applied and read back consistently|计划已应用且读回一致' "$CASE_DIR/menu" || fail 'failed menu measurement claimed application success'
)

test_real_loopback_measurement() (
  declare -F adaptive_measure_rtt >/dev/null || fail 'real RTT measurement helper is missing'
  setup_case loopback
  PATH="$REAL_PATH"
  local target value
  for target in 127.0.0.1 ::1; do
    if [[ "$target" == ::1 ]] && ! awk '$1=="00000000000000000000000000000001" && $6=="lo" {found=1} END {exit !found}' /proc/net/if_inet6; then
      printf 'SKIP: IPv6 loopback is not configured in this container.\n'
      continue
    fi
    value="$(adaptive_measure_rtt "$target" 2> "$CASE_DIR/real-error")" || { cat "$CASE_DIR/real-error" >&2; fail "configured loopback RTT probe failed: $target"; }
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v value="$value" 'BEGIN {exit !(value>0 && value<=60000)}' || fail 'real loopback probe did not return a positive bounded average'
    printf 'PASS: real loopback RTT %s = %s ms\n' "$target" "$value"
  done
  assert_no_writes
)

test_probe_cancellation_no_orphans() (
  declare -F adaptive_measure_rtt >/dev/null || fail 'cancellable RTT helper is missing'
  setup_case cancellation
  mkdir "$CASE_DIR/cancel-bin"
  cat > "$CASE_DIR/cancel-bin/ping" <<'PING'
#!/bin/bash
printf '%s\n' "$$" > "$RTT_PID_FILE"
exec /bin/sleep 30
PING
  chmod 0755 "$CASE_DIR/cancel-bin/ping"
  export PATH="$CASE_DIR/cancel-bin:$REAL_PATH" RTT_PID_FILE="$CASE_DIR/ping.pid"
  python3 - "$SCRIPT" "$TMP/functions.sh" "$CASE_DIR" <<'PY' || fail 'probe cancellation or child cleanup failed'
from pathlib import Path
import os
import signal
import subprocess
import sys
import time

root = Path(sys.argv[3])
driver = 'source <(sed -n "/^# BEGIN I18N$/,/^# END I18N$/p" "$1"); source "$2"; adaptive_measure_rtt 127.0.0.1'
groups = set()
def alive(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0] != 'Z'
    except FileNotFoundError:
        return False

with (root / 'cancel.out').open('w') as out, (root / 'cancel.err').open('w') as err:
    process = subprocess.Popen(['bash', '-c', driver, '_', sys.argv[1], sys.argv[2]],
                               stdout=out, stderr=err, start_new_session=True)
    groups.add(process.pid)
    try:
        deadline = time.monotonic() + 3
        while not Path(os.environ['RTT_PID_FILE']).exists():
            assert process.poll() is None, 'probe exited before starting ping'
            assert time.monotonic() < deadline, 'probe did not start ping'
            time.sleep(0.02)
        ping_pid = int(Path(os.environ['RTT_PID_FILE']).read_text())
        timeout_pid = int(Path(f'/proc/{ping_pid}/stat').read_text().rsplit(')', 1)[1].split()[1])
        ping_group = os.getpgid(ping_pid)
        groups.add(ping_group)
        assert ping_group == process.pid, 'ping escaped the terminal process group'
        os.killpg(process.pid, signal.SIGINT)
        assert process.wait(timeout=3) != 0, 'interrupted probe reported success'
        deadline = time.monotonic() + 1
        while (alive(ping_pid) or alive(timeout_pid)) and time.monotonic() < deadline:
            time.sleep(0.02)
        assert not alive(ping_pid) and not alive(timeout_pid), 'cancelled probe left ping/timeout running'
    finally:
        for group in groups:
            if group != os.getpgrp():
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        process.wait(timeout=3)
print('PASS: SIGINT cancels the probe without live ping or timeout children')
PY
  assert_no_writes
)

failures=0
for test in test_probe_contract_and_addresses test_probe_failure_states test_default_and_numeric_paths_never_probe test_auto_plan_and_menu_options test_invalid_auto_options_are_zero_traffic test_failed_measurement_never_reaches_apply test_real_loopback_measurement test_probe_cancellation_no_orphans; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
