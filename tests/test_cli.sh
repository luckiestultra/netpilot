#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/netpilot.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
bash "$SCRIPT" help > "$TMP/help"
grep -q 'doctor' "$TMP/help"
bash "$SCRIPT" doctor > "$TMP/doctor"
grep -q '只读' "$TMP/doctor"
bash "$SCRIPT" plan --profile proxy --bandwidth 1000 --rtt 100 > "$TMP/plan"
grep -q 'proxy' "$TMP/plan"
grep -q '尚未应用' "$TMP/plan"
bash "$SCRIPT" diagnose > "$TMP/diagnose"
grep -q 'tcp_retrans_segs' "$TMP/diagnose"
if bash "$SCRIPT" plan --rtt '1;touch /tmp/should-not-exist' > /dev/null 2>&1; then echo 'FAIL: unsafe input accepted'; exit 1; fi
if bash "$SCRIPT" apply --profile unknown --yes > /dev/null 2>&1; then echo 'FAIL: invalid apply profile accepted'; exit 1; fi
[[ ! -e /var/lib/vps-tcp-full-tune && ! -e /usr/local/bin/tcp.sh ]] || { echo 'FAIL: read-only commands installed or wrote state'; exit 1; }
printf '%s\n' 'PASS: integrated CLI and zero-write read-only commands'
