#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_OVERRIDE:-$SCRIPT_DIR/vps-tcp-full-tune.sh}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

printf '%s\n' 'reno cubic' > "$TEST_DIR/cc"
printf '%s\n' 'pfifo_fast' > "$TEST_DIR/qdisc"
printf '%s\n' 0 > "$TEST_DIR/modprobe-calls"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

warn() {
  :
}

sysctl() {
  case "$*" in
    '-n net.ipv4.tcp_available_congestion_control')
      cat "$TEST_DIR/cc"
      ;;
    '-n net.ipv4.tcp_congestion_control')
      awk '{print $NF}' "$TEST_DIR/cc"
      ;;
    '-n net.core.default_qdisc')
      cat "$TEST_DIR/qdisc"
      ;;
    '-w net.core.default_qdisc=fq')
      printf '%s\n' 'fq' > "$TEST_DIR/qdisc"
      ;;
    '-w net.ipv4.tcp_congestion_control=bbr')
      printf '%s\n' 'reno cubic bbr' > "$TEST_DIR/cc"
      ;;
    *)
      return 1
      ;;
  esac
}

modprobe() {
  local calls
  calls="$(cat "$TEST_DIR/modprobe-calls")"
  printf '%s\n' "$((calls + 1))" > "$TEST_DIR/modprobe-calls"
  printf '%s\n' 'reno cubic bbr' > "$TEST_DIR/cc"
}

# Load only the pure BBR detection/loading functions from the production script.
sed -n '/^sysctl_supported()/,/^show_status()/p' "$SCRIPT" | sed '$d' > "$TEST_DIR/functions.sh"
source "$TEST_DIR/functions.sh"

load_bbr_module || fail 'load_bbr_module should load an available tcp_bbr module'
[[ "$(cat "$TEST_DIR/modprobe-calls")" -eq 1 ]] || fail 'tcp_bbr should be requested exactly once'
grep -q ' bbr$' "$TEST_DIR/cc" || fail 'BBR should be advertised after module load'

sysctl -w net.core.default_qdisc=fq >/dev/null
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
bbr_fq_active || fail 'BBR + FQ should be reported active after both values are applied'

printf 'PASS: BBR module loading and BBR/FQ verification\n'
