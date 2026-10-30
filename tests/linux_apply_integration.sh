#!/usr/bin/env bash
# Run only inside a disposable Linux container with a private network namespace.
set -Eeuo pipefail
[[ -f /.dockerenv && -w /proc/sys/net/ipv4/tcp_wmem ]] || {
  echo 'Requires a disposable Docker container with writable namespaced sysctls.' >&2; exit 2;
}
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/netpilot.sh"
# Containers may cap core socket maxima at their parent namespace's ceiling.
# Use smaller real TCP maxima so both plans fit inside that inherited ceiling.
sysctl -w net.ipv4.tcp_rmem='4096 131072 1048576' > /dev/null
sysctl -w net.ipv4.tcp_wmem='4096 16384 1048576' > /dev/null
sysctl -w net.ipv4.tcp_moderate_rcvbuf=0 > /dev/null
ORIGINAL="$(sysctl -n net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_moderate_rcvbuf)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
bash "$SCRIPT" apply --profile bulk --bandwidth 50 --rtt 100 --yes > "$TMP/first"
bash "$SCRIPT" apply --profile bulk --bandwidth 100 --rtt 100 --yes > "$TMP/second"
bash "$SCRIPT" verify > "$TMP/verify"
grep -q '一致' "$TMP/verify"
# A real external parameter change must make verification fail.
sysctl -w net.ipv4.tcp_wmem='4096 16384 4194304' > /dev/null
if bash "$SCRIPT" verify > "$TMP/drift"; then echo 'FAIL: actual drift not detected'; exit 1; fi
grep -q '偏离' "$TMP/drift"
bash "$SCRIPT" rollback > "$TMP/rollback"
RESTORED="$(sysctl -n net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_moderate_rcvbuf)"
[[ "$ORIGINAL" == "$RESTORED" ]] || { echo 'FAIL: original sysctls not restored'; exit 1; }
[[ ! -e /etc/sysctl.d/99-network-performance.conf ]] || { echo 'FAIL: created config remained after rollback'; exit 1; }
printf '%s\n' 'PASS: real Linux apply, repeated persistence, drift detection and exact sysctl restoration'
