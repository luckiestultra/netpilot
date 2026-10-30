#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
source <(awk '/^log\(\)/ {p=1} /^# CLI entry point/ {exit} p {print}' "$SCRIPT")
declare -a SYSCTL_KEYS=()
declare -A SYSCTL_TARGETS=()
SYSCTL_FILE="$TMP/managed.conf"
GAI_FILE="$TMP/gai.conf"
warn() { printf '%s\n' "$*" >&2; }
log() { :; }
printf '# Managed by vps-tcp-full-tune.sh.\nnet.ipv4.tcp_congestion_control = bbr\n' > "$SYSCTL_FILE"
SYSCTL_KEYS=(net.ipv4.tcp_rmem)
SYSCTL_TARGETS[net.ipv4.tcp_rmem]='4096 131072 33554432'
write_sysctl_file
grep -qx 'net.ipv4.tcp_congestion_control = bbr' "$SYSCTL_FILE" || { echo 'FAIL: repeated apply lost persisted intent'; exit 1; }
printf 'net.ipv4.tcp_ecn = 0\n' > "$SYSCTL_FILE"
cp "$SYSCTL_FILE" "$TMP/unowned"
if write_sysctl_file; then echo 'FAIL: unowned config was overwritten'; exit 1; fi
cmp -s "$SYSCTL_FILE" "$TMP/unowned"
prepare_state() { [[ ${#SYSCTL_KEYS[@]} == 0 ]] || { echo 'FAIL: unrelated sysctl backed up'; return 1; }; }
build_targets() { SYSCTL_KEYS=(net.unrelated); }
default_interface() { echo eth0; }
apply_gai_preference() { :; }
apply_nic_ring() { :; }
apply_rps() { :; }
show_nic_dashboard() { :; }
apply_ipv4_preference_only
apply_nic_only
printf '%s\n' 'PASS: repeated persistence, unowned configuration and mutation ownership'
