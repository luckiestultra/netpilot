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
  [[ "$(stat -c '%a' "$parent/reports")" == 700 ]] || fail "report root is not private below $mode parent"
  [[ "$(stat -c '%a' "$parent")" == "${mode#0}" ]] || fail "report creation changed $mode parent permissions"
done
printf 'PASS: private report creation accepts protected and sticky parent directories\n'

for lang in zh en; do
  np_set_language "$lang"
  for mode in 1777 0775; do
    root="$TMP/rejected-root-$lang-$mode"
    mkdir -m "$mode" "$root"
    mkdir -m 0700 "$root/run.previous"
    printf '{"type":"netpilot-tune-report","version":1}\n' > "$root/run.previous/summary.json"
    printf 'existing user data\n' > "$root/keep"
    find "$root" -printf '%P %m %u %g\n' | sort > "$TMP/before-tree"
    sha256sum "$root/run.previous/summary.json" "$root/keep" > "$TMP/before-hashes"
    status=0
    auto_report prepare "$root" "$TMP/state" > "$TMP/result" 2> "$TMP/error" || status=$?
    [[ "$status" == 1 ]] || fail "unsafe $mode final report root was accepted"
    find "$root" -printf '%P %m %u %g\n' | sort > "$TMP/after-tree"
    cmp -s "$TMP/before-tree" "$TMP/after-tree" || fail "rejection changed $mode report root contents or permissions"
    sha256sum --check --status "$TMP/before-hashes" || fail "rejection changed existing data in $mode report root"
    grep -Fq "$root" "$TMP/error" || fail 'report-root rejection does not identify the failing path'
    grep -Eq "(权限|mode) $mode([,，)）]|$)" "$TMP/error" || fail 'report-root rejection does not identify the failing permissions'
    if [[ "$lang" == zh ]]; then
      grep -q '目录权限不安全' "$TMP/error" || fail 'Chinese report-root diagnosis is missing'
    else
      grep -q 'Unsafe report path directory' "$TMP/error" || fail 'English report-root diagnosis is missing'
    fi
  done
done
printf 'PASS: writable final report roots are rejected without changing permissions or existing data\n'

for lang in zh en; do
  np_set_language "$lang"
  for mode in 0775 2775 0777; do
    parent="$TMP/rejected-$lang-$mode"
    mkdir -m "$mode" "$parent"
    status=0
    auto_report prepare "$parent/reports" "$TMP/state" > "$TMP/result" 2> "$TMP/error" || status=$?
    [[ "$status" == 1 && ! -e "$parent/reports" ]] || fail "unsafe $mode parent was accepted"
    grep -Fq "$parent" "$TMP/error" || fail 'directory rejection does not identify the failing path'
    grep -Eq "(权限|mode) $mode([,，)）]|$)" "$TMP/error" || fail 'directory rejection does not identify the failing permissions'
    if [[ "$lang" == zh ]]; then
      grep -q '目录权限不安全' "$TMP/error" || fail 'Chinese directory diagnosis is missing'
    else
      grep -q 'Unsafe report path directory' "$TMP/error" || fail 'English directory diagnosis is missing'
    fi
  done
done
printf 'PASS: writable nonsticky report parents remain rejected with a specific bilingual diagnosis\n'
