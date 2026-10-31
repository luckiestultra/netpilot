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
ORIGINAL_CC="$(sysctl -n net.ipv4.tcp_congestion_control)"
ORIGINAL_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
bash "$SCRIPT" apply --profile bulk --bandwidth 50 --rtt 100 --yes > "$TMP/first"
# Compare the per-run starting state with the separately retained first-ever
# baseline, using actual namespaced TCP values and real managed files.
source "$SCRIPT"
RUN_START="$(sysctl -n net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_moderate_rcvbuf)"
FIRST_WMEM="$(sysctl -n net.ipv4.tcp_wmem)"
cp -p "$SYSCTL_FILE" "$TMP/run-start.conf"
find "$STATE_DIR" -type f -print0 | sort -z | xargs -0 sha256sum > "$TMP/run-start-state.sha256"
mkdir -m 0700 "$TMP/run"
tuning_run_begin "$TMP/run"
run_mutation apply_tuning --profile bulk --bandwidth 100 --rtt 100 --yes > "$TMP/run-apply"
[[ "$(sysctl -n net.ipv4.tcp_wmem)" != "$FIRST_WMEM" ]] || { echo 'FAIL: run fixture never changed the real TCP send ceiling'; exit 1; }
tuning_run_restore > "$TMP/run-restore"
RESTORED_RUN="$(sysctl -n net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_moderate_rcvbuf)"
[[ "$RESTORED_RUN" == "$RUN_START" && "$RESTORED_RUN" != "$ORIGINAL" ]] || { echo 'FAIL: run restore did not retain the real starting state distinct from the first-ever baseline'; exit 1; }
cmp -s "$SYSCTL_FILE" "$TMP/run-start.conf" || { echo 'FAIL: run restore changed prior managed configuration'; exit 1; }
sha256sum --check --status "$TMP/run-start-state.sha256" || { echo 'FAIL: run restore changed prior applied metadata or first-ever recovery records'; exit 1; }
verify_tuning > "$TMP/run-verify"
TUNING_RUN_DIR=''
printf '%s\n' 'PASS: actual Linux TCP send ceiling changes and restores this run, retaining prior configuration and first-ever backups'
bash "$SCRIPT" apply --profile bulk --bandwidth 100 --rtt 100 --yes > "$TMP/second"
bash "$SCRIPT" verify > "$TMP/verify"
grep -q '一致' "$TMP/verify"
[[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "$ORIGINAL_CC" && "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" == "$ORIGINAL_QDISC" ]] || { echo 'FAIL: manual apply changed the original algorithm or default queue'; exit 1; }
# A real external parameter change must make verification fail.
sysctl -w net.ipv4.tcp_wmem='4096 16384 4194304' > /dev/null
if bash "$SCRIPT" verify > "$TMP/drift"; then echo 'FAIL: actual drift not detected'; exit 1; fi
grep -q '偏离' "$TMP/drift"
bash "$SCRIPT" rollback > "$TMP/rollback"
RESTORED="$(sysctl -n net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_moderate_rcvbuf)"
[[ "$ORIGINAL" == "$RESTORED" ]] || { echo 'FAIL: original sysctls not restored'; exit 1; }
[[ ! -e /etc/sysctl.d/99-netpilot.conf ]] || { echo 'FAIL: created config remained after rollback'; exit 1; }
printf '%s\n' 'PASS: real Linux apply, repeated persistence, drift detection and exact sysctl restoration'
