#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/netpilot.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run_menu() {
  # Menu translations can be exercised without invoking first-run installation.
  bash -c 'source "$1"; np_set_language "${NETPILOT_LANG:-zh}"; menu' _ "$SCRIPT"
}

# Invoke the actual Linux entry point. Language selection must not install or tune.
NETPILOT_LANG=zh bash "$SCRIPT" --lang en help > "$TMP/en-help"
grep -q 'Usage: netpilot' "$TMP/en-help" || fail 'English help is unavailable'
NETPILOT_LANG=en bash "$SCRIPT" --lang zh help > "$TMP/zh-help"
grep -q '用法：netpilot' "$TMP/zh-help" || fail 'Chinese flag does not override environment'
NETPILOT_LANG=en bash "$SCRIPT" help > "$TMP/env-help"
grep -q 'Usage: netpilot' "$TMP/env-help" || fail 'language environment is ignored'
NETPILOT_LANG=zh bash "$SCRIPT" help > "$TMP/default-help"
grep -q '用法：netpilot' "$TMP/default-help" || fail 'Chinese help regressed'
env -u NETPILOT_LANG bash "$SCRIPT" help > "$TMP/unset-help"
grep -q '用法：netpilot' "$TMP/unset-help" || fail 'unset language does not default to Chinese'
NETPILOT_LANG=invalid bash "$SCRIPT" --lang=en help > "$TMP/equals-help"
grep -q 'Usage: netpilot' "$TMP/equals-help" || fail 'explicit flag did not override invalid environment'

for command in doctor plan diagnose; do
  bash "$SCRIPT" --lang en "$command" > "$TMP/en-$command" 2>&1
done
grep -qi 'read.only' "$TMP/en-doctor" || fail 'English doctor heading is missing'
grep -qi 'not applied' "$TMP/en-plan" || fail 'English plan status is missing'
grep -q 'tcp_retrans_segs' "$TMP/en-diagnose" || fail 'counter identifiers changed'

# These outputs are owned by NetPilot, rather than raw output from external tools.
python3 - "$TMP/en-help" "$TMP/en-plan" <<'PY'
import pathlib, sys
for name in sys.argv[1:]:
    text = pathlib.Path(name).read_text()
    assert not any('\u3400' <= c <= '\u9fff' for c in text), name + ': untranslated Chinese output'
PY

printf 'l\n0\n' | NETPILOT_LANG=zh run_menu > "$TMP/toggle" 2>&1
grep -q '网络诊断与调优' "$TMP/toggle" || fail 'initial Chinese menu missing'
grep -q 'Network Diagnostics' "$TMP/toggle" || fail 'menu language switch did not take effect'
printf '8\n1\n0\n' | NETPILOT_LANG=en run_menu > "$TMP/en-feature" 2>&1
grep -qi 'read.only' "$TMP/en-feature" || fail 'English feature submenu did not run doctor'

# Force an operation failure without executing a system mutation; the actual menu
# must localize its error summary too, including after switching back to Chinese.
for language in zh en; do
  printf '1\n2\n3\n4\n5\n0\n' | NETPILOT_LANG="$language" bash -c '
    source "$1"
    run_mutation() { return 1; }
    menu
  ' _ "$SCRIPT" > "$TMP/$language-failed-menu" 2>&1
done
[[ "$(grep -c '操作失败。' "$TMP/zh-failed-menu")" == 4 ]] || fail 'Chinese operation failure summaries are missing'
grep -q '回退未完成。' "$TMP/zh-failed-menu" || fail 'Chinese rollback failure summary is missing'
[[ "$(grep -c 'Operation failed.' "$TMP/en-failed-menu")" == 4 ]] || fail 'English operation failure summaries regressed'
grep -q 'Rollback incomplete.' "$TMP/en-failed-menu" || fail 'English rollback failure summary regressed'
printf 'L\nL\n0\n' | NETPILOT_LANG=zh run_menu > "$TMP/roundtrip-menu" 2>&1
[[ "$(grep -c '网络诊断与调优' "$TMP/roundtrip-menu")" == 2 ]] || fail 'switching back to Chinese did not restore the menu'

if bash "$SCRIPT" --lang 'en;touch bad' help > "$TMP/invalid" 2>&1; then
  fail 'invalid language accepted'
fi
if bash "$SCRIPT" --lang > "$TMP/missing" 2>&1; then
  fail 'missing language accepted'
fi
if NETPILOT_LANG=xx bash "$SCRIPT" help > "$TMP/env-invalid" 2>&1; then
  fail 'invalid language environment accepted'
fi

# Both languages must verify the same persisted numeric data and return the same
# failure status on drift. Only the human-readable labels should change.
for language in zh en; do
  for expected in 1 2; do
    printf 'net.ipv4.tcp_moderate_rcvbuf = %s\n' "$expected" > "$TMP/verify.conf"
    result=0
    NETPILOT_LANG="$language" bash -c '
      source <(sed -n "/^# BEGIN I18N$/,/^# END I18N$/p" "$1")
      source <(sed -n "/^# BEGIN INSPECTION$/,/^# END INSPECTION$/p" "$1")
      BBR_FILE="$2"; SYSCTL_FILE="$2.absent"
      sysctl_value() { printf "1\n"; }
      verify_tuning
    ' _ "$SCRIPT" "$TMP/verify.conf" > "$TMP/$language-verify-$expected" || result=$?
    [[ "$result" == "$((expected - 1))" ]] || fail 'language changed verification exit status'
  done
done
grep -q '一致' "$TMP/zh-verify-1" || fail 'Chinese verification result missing'
grep -qi 'match' "$TMP/en-verify-1" || fail 'English verification result missing'
grep -qi 'drift' "$TMP/en-verify-2" || fail 'English drift result missing'

source "$SCRIPT"
NETPILOT_LANG=en
[[ "$(np_msg '值：%s' 'Value: %s' 'literal %s')" == 'Value: literal %s' ]] || fail 'format argument was interpreted as a template'
NETPILOT_LANG=zh
[[ "$(np_msg '值：%s' 'Value: %s' 'test')" == '值：test' ]] || fail 'Chinese formatting failed'

[[ ! -e /var/lib/netpilot && ! -e /usr/local/bin/netpilot.sh && ! -e /usr/local/bin/netpilot && ! -L /usr/local/bin/netpilot ]] || fail 'read-only language paths wrote installation or state'
printf '%s\n' 'PASS: bilingual help, diagnostics, plans, menu switching, validation and read-only behavior'
