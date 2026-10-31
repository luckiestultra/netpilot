#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SNIPPET="${INSPECTION_OVERRIDE:-$ROOT/netpilot.sh}"
[[ -f "$SNIPPET" ]] || { echo 'FAIL: inspection functions missing'; exit 1; }
# Extracted application functions share the language formatter.
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SNIPPET")
source <(sed -n '/^# BEGIN INSPECTION$/,/^# END INSPECTION$/p' "$SNIPPET")
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
BBR_FILE="$TMP/bbr.conf"
SYSCTL_FILE="$TMP/network.conf"
warn() { printf '%s\n' "$*" >&2; }
sysctl_value() {
  case "$1" in
    net.core.default_qdisc) echo fq ;;
    net.ipv4.tcp_congestion_control) echo cubic ;;
    net.ipv4.tcp_rmem) printf '4096\t131072\t8388608\n' ;;
    *) return 1 ;;
  esac
}
printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_rmem = 4096 131072 8388608\n' > "$BBR_FILE"
verify_tuning > "$TMP/verify"
grep -q '一致' "$TMP/verify"
printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$SYSCTL_FILE"
if verify_tuning > "$TMP/verify"; then echo 'FAIL: drift must fail verification'; exit 1; fi
grep -q '偏离' "$TMP/verify"
printf 'net.ipv4.unknown = 7\n' >> "$SYSCTL_FILE"
if verify_tuning > "$TMP/verify"; then echo 'FAIL: unavailable key must fail'; exit 1; fi
grep -q '不可读取' "$TMP/verify"
mkdir -p "$TMP/proc/net"
printf '00000001 0000000a 00000003 0\n000000ff 00000001 00000002 0\n' > "$TMP/proc/net/softnet_stat"
printf 'TcpExt: ListenOverflows ListenDrops\nTcpExt: 7 9\n' > "$TMP/proc/net/netstat"
printf 'Tcp: OutSegs RetransSegs\nTcp: 100 4\n' > "$TMP/proc/net/snmp"
network_counter_snapshot "$TMP/proc" > "$TMP/counters"
grep -q $'softnet_dropped\t11' "$TMP/counters"
grep -q $'softnet_squeezed\t5' "$TMP/counters"
grep -q $'listen_drops\t9' "$TMP/counters"
grep -q $'tcp_retrans_segs\t4' "$TMP/counters"
if diagnose_command --seconds '1;echo bad' >/dev/null 2>&1; then echo 'FAIL: invalid interval accepted'; exit 1; fi
if diagnose_command --bogus >/dev/null 2>&1; then echo 'FAIL: unknown argument accepted'; exit 1; fi
printf '%s\n' 'PASS: drift verification, counter diagnostics and input validation'
