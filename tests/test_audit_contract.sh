#!/usr/bin/env bash
# Main dispatch and parser regression tests use spies; no real system writes.
# shellcheck disable=SC1090
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${NETPILOT_AUDIT_SCRIPT:-$ROOT/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
failures=0
checks=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

# A root guard exits its subshell, so a help/validation failure cannot fall
# through to the mutation dispatcher even when this file is sourced in tests.
spy_main() (
  source "$SCRIPT"
  need_root() { printf 'root\n' > "$TMP/guard"; exit 99; }
  need_command() { :; }
  default_interface() { :; }
  adaptive_doctor() { printf 'doctor\n' > "$TMP/dispatched"; }
  show_status() { printf 'status\n' > "$TMP/dispatched"; }
  verify_tuning() { printf 'verify\n' > "$TMP/dispatched"; }
  menu() { printf 'menu\n' > "$TMP/dispatched"; }
  install_from_source() { printf 'install\n' > "$TMP/dispatched"; }
  resolve_source_path() { printf 'resolve\n' > "$TMP/dispatched"; }
  run_mutation() { printf '%s\n' "$*" > "$TMP/dispatched"; }
  main "$@"
)

for cmd in help doctor status verify menu rollback update install; do
  rm -f -- "$TMP/guard" "$TMP/dispatched"
  spy_main "$cmd" --bogus > "$TMP/out" 2>&1
  rc=$?
  checks=$((checks + 1))
  if [[ $rc != 2 || -e "$TMP/guard" || -e "$TMP/dispatched" ]]; then
    fail "$cmd --bogus must fail with 2 before root checks, installation or dispatch (rc=$rc)"
  fi
done

# In particular, rollback/update/install/menu --help must never perform work.
# These checks also establish that tune/uninstall help works without root.
for cmd in menu doctor plan apply status verify diagnose bench compare report rollback install update uninstall tune; do
  for flag in --help -h; do
    rm -f -- "$TMP/guard" "$TMP/dispatched"
    spy_main --lang en "$cmd" "$flag" > "$TMP/out" 2>&1
    rc=$?
    checks=$((checks + 1))
    if [[ $rc != 0 || -e "$TMP/guard" || -e "$TMP/dispatched" ]] || ! grep -q 'NetPilot' "$TMP/out"; then
      fail "$cmd $flag must print help without root checks or work (rc=$rc)"
    fi
  done
done

# Positive controls prevent a dispatcher that rejects all commands from passing.
for cmd in doctor status verify; do
  rm -f -- "$TMP/guard" "$TMP/dispatched"
  spy_main "$cmd" > "$TMP/out" 2>&1
  rc=$?
  checks=$((checks + 1))
  if [[ $rc != 0 || -e "$TMP/guard" || "$(cat "$TMP/dispatched" 2>/dev/null)" != "$cmd" ]]; then
    fail "$cmd without arguments must reach its read-only handler (rc=$rc)"
  fi
done

for cmd in plan apply; do
  rm -f -- "$TMP/prepared"
  (
    source "$SCRIPT"
    adaptive_memory_bytes() { printf '1048576\n'; }
    sysctl_value() {
      if [[ $1 == net.ipv4.tcp_available_congestion_control ]]; then printf 'cubic\n'
      else printf '0\n'; fi
    }
    default_interface() { :; }
    prepare_state() { printf 'called\n' > "$TMP/prepared"; return 1; }
    if [[ $cmd == plan ]]; then adaptive_show_plan --bandwidth ''
    else apply_tuning --bandwidth '' --yes; fi
  ) > "$TMP/out" 2>&1
  rc=$?
  checks=$((checks + 1))
  if [[ $rc != 2 || -e "$TMP/prepared" ]]; then
    fail "$cmd must reject an explicit empty --bandwidth before state preparation (rc=$rc)"
  fi
done

# Omitting both path inputs is still a valid conservative plan.
(
  source "$SCRIPT"
  adaptive_memory_bytes() { printf '1048576\n'; }
  sysctl_value() {
    if [[ $1 == net.ipv4.tcp_available_congestion_control ]]; then printf 'cubic\n'
    else printf '1\n'; fi
  }
  adaptive_plan
) > "$TMP/out" 2>&1
rc=$?
checks=$((checks + 1))
[[ $rc == 0 ]] || fail "omitting bandwidth and RTT must remain valid (rc=$rc)"

for lang in zh en; do
  (
    source "$SCRIPT"
    export NETPILOT_LANG="$lang"
    usage
  ) > "$TMP/out" 2>&1
  checks=$((checks + 1))
  if ! sed -n '/bench --peer/,/compare BEFORE/p' "$TMP/out" | grep -q -- '--timeout 30'; then
    fail "$lang main help must list the supported benchmark timeout option"
  fi
done

if ((failures)); then
  printf 'Contract audit: %s failed checks of %s\n' "$failures" "$checks" >&2
  exit 1
fi
printf 'PASS: %s CLI contract checks; all installation and mutation paths isolated by spies\n' "$checks"
