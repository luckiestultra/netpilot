#!/usr/bin/env bash
# Real directory permission checks, confined to private temporary fixtures.
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
source "$SCRIPT"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for mode in 0700 0755 1777; do
  parent="$TMP/accepted-$mode"
  mkdir -m "$mode" "$parent"
  run_dir="$(auto_report prepare "$parent/reports" "$TMP/state")"
  [[ -d "$run_dir" && "$(stat -c '%a' "$run_dir")" == 700 ]] || fail "private run creation failed below $mode parent"
done
printf 'PASS: private report creation accepts protected and sticky parent directories\n'

for lang in zh en; do
  np_set_language "$lang"
  for mode in 0775 2775 0777; do
    parent="$TMP/rejected-$lang-$mode"
    mkdir -m "$mode" "$parent"
    status=0
    auto_report prepare "$parent/reports" "$TMP/state" > "$TMP/result" 2> "$TMP/error" || status=$?
    [[ "$status" == 1 && ! -e "$parent/reports" ]] || fail "unsafe $mode parent was accepted"
    grep -Fq "$parent" "$TMP/error" || fail 'directory rejection does not identify the failing path'
    grep -Fq "$mode" "$TMP/error" || fail 'directory rejection does not identify the failing permissions'
    if [[ "$lang" == zh ]]; then
      grep -q '目录权限不安全' "$TMP/error" || fail 'Chinese directory diagnosis is missing'
    else
      grep -q 'Unsafe report path directory' "$TMP/error" || fail 'English directory diagnosis is missing'
    fi
  done
done
printf 'PASS: writable nonsticky report parents remain rejected with a specific bilingual diagnosis\n'
