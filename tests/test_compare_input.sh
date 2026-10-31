#!/usr/bin/env bash
# Report comparison must reject invalid input files without blocking or writing.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_OVERRIDE:-$ROOT/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject_input() {
  local path="$1" rc=0
  timeout --kill-after=1 3 bash "$SCRIPT" compare "$path" "$TMP/after.json" > "$TMP/output" 2>&1 || rc=$?
  [[ "$rc" == 1 ]] || fail "invalid report must fail promptly with 1, got $rc: $path"
  grep -q '无法对比' "$TMP/output" || fail 'invalid input needs a clear comparison error'
  ! grep -q 'Traceback' "$TMP/output" || fail 'invalid input leaked an unhandled Python traceback'
}

printf '{}\n' > "$TMP/after.json"
mkfifo "$TMP/pipe.json"
reject_input "$TMP/pipe.json"
reject_input "$TMP"
printf '%s\n' 'PASS: comparison rejects FIFOs and directories without blocking'

python3 - "$TMP/large.json" "$TMP/deep.json" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b' ' * (1048576 + 1))
Path(sys.argv[2]).write_text('[' * 2000 + '0' + ']' * 2000)
PY
reject_input "$TMP/large.json"
reject_input "$TMP/deep.json"
printf '%s\n' 'PASS: comparison rejects oversized and excessively nested JSON without a traceback'
