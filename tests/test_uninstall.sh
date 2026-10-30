#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
for name in installed_script_owned uninstall_own_script resolve_source_path; do
  sed -n "/^${name}() {/,/^}/p" "$SCRIPT" >> "$TEST_DIR/functions.sh"
done
source "$TEST_DIR/functions.sh"
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
setup() {
  CASE_DIR="$TEST_DIR/$1"; mkdir -p "$CASE_DIR"
  INSTALL_PATH="$CASE_DIR/tcp.sh"; SCRIPT_PATH="$CASE_DIR/download.sh"
  SHORTCUT_PATH="$CASE_DIR/tcp"; NETPILOT_SHORTCUT_PATH="$CASE_DIR/netpilot"; LEGACY_SHORTCUT_PATH="$CASE_DIR/t"
  STATE_DIR="$CASE_DIR/state"; SOURCE_SNAPSHOT=''
  UPDATE_URL='https://github.com/liuxr0814/netpilot/raw/refs/heads/main/netpilot.sh'
  cp "$SCRIPT" "$INSTALL_PATH"; cp "$SCRIPT" "$SCRIPT_PATH"
  ln -s "$INSTALL_PATH" "$SHORTCUT_PATH"
  ln -s "$INSTALL_PATH" "$LEGACY_SHORTCUT_PATH"
  rollback_internal() { :; }
}
invoke() { (uninstall_own_script <<< "${1:-y}") > "$CASE_DIR/output" 2>&1; }
assert_removed() {
  [[ ! -e "$INSTALL_PATH" && ! -L "$INSTALL_PATH" ]] || fail 'installed script remains'
  [[ ! -L "$SHORTCUT_PATH" && ! -L "$LEGACY_SHORTCUT_PATH" ]] || fail 'owned shortcut remains'
}
assert_no_success() {
  if grep -q '本调优脚本及其快捷命令已移除' "$CASE_DIR/output"; then fail 'failure reported success'; fi
}

test_download_uninstall_removes_installed_copy_only() (
  setup download
  invoke || fail 'download uninstall failed'
  assert_removed
  [[ -f "$SCRIPT_PATH" ]] || fail 'download source was deleted'
)
test_installed_path_uninstalls() (
  setup installed
  SCRIPT_PATH="$INSTALL_PATH"
  invoke || fail 'installed-path uninstall failed'
  assert_removed
)
test_menu_uninstall_without_resolved_source() (
  setup menu
  SCRIPT_PATH=''
  invoke || fail 'menu uninstall failed with unresolved source'
  assert_removed
  [[ -f "$CASE_DIR/download.sh" ]] || fail 'menu removed local source'
)
test_process_substitution_resolves_then_uninstalls() (
  setup process-substitution
  SOURCE_PATH='/dev/fd/999'; RESOLVED_SOURCE=''
  curl() {
    while (($#)); do
      if [[ "$1" == --output ]]; then command cp "$SCRIPT" "$2"; return; fi
      shift
    done
    return 1
  }
  resolve_source_path || fail 'process-substitution snapshot failed'
  [[ -n "$SOURCE_SNAPSHOT" && "$SCRIPT_PATH" == "$SOURCE_SNAPSHOT" ]] || fail 'snapshot was not used'
  invoke || fail 'snapshot uninstall failed'
  assert_removed
  command rm -f -- "$SOURCE_SNAPSHOT"
)
test_changed_owned_version_is_recognized() (
  setup older-version
  printf '\n# Older installed revision\n' >> "$INSTALL_PATH"
  invoke || fail 'different owned revision was refused'
  assert_removed
)
test_unrelated_installed_file_is_preserved() (
  setup unrelated
  printf '#!/bin/bash\nprintf unrelated\n' > "$INSTALL_PATH"
  if invoke; then fail 'unrelated installed file accepted'; fi
  [[ "$(cat "$INSTALL_PATH")" == $'#!/bin/bash\nprintf unrelated' ]] || fail 'unrelated installed file changed'
  [[ -L "$SHORTCUT_PATH" && -f "$SCRIPT_PATH" ]] || fail 'refusal mutated source or shortcut'
  assert_no_success
)
test_installed_symlink_is_preserved() (
  setup symlink
  mv "$INSTALL_PATH" "$CASE_DIR/victim"
  ln -s "$CASE_DIR/victim" "$INSTALL_PATH"
  if invoke; then fail 'installed symlink accepted'; fi
  [[ -L "$INSTALL_PATH" && -f "$CASE_DIR/victim" && -L "$SHORTCUT_PATH" ]] || fail 'symlink refusal changed files'
  assert_no_success
)
test_dangling_installed_symlink_is_preserved() (
  setup dangling
  rm -f -- "$INSTALL_PATH"; ln -s "$CASE_DIR/absent" "$INSTALL_PATH"
  if invoke; then fail 'dangling installed symlink accepted'; fi
  [[ -L "$INSTALL_PATH" && -L "$SHORTCUT_PATH" ]] || fail 'dangling symlink was removed'
  assert_no_success
)
test_unrelated_shortcuts_are_preserved() (
  setup shortcut
  rm -f -- "$SHORTCUT_PATH" "$LEGACY_SHORTCUT_PATH"
  printf 'other executable\n' > "$SHORTCUT_PATH"
  ln -s "$CASE_DIR/other" "$LEGACY_SHORTCUT_PATH"
  invoke || fail 'uninstall with unrelated shortcuts failed'
  [[ ! -e "$INSTALL_PATH" && -f "$SCRIPT_PATH" ]] || fail 'wrong installed/source result'
  [[ "$(cat "$SHORTCUT_PATH")" == 'other executable' ]] || fail 'unrelated shortcut file removed'
  [[ "$(readlink "$LEGACY_SHORTCUT_PATH")" == "$CASE_DIR/other" ]] || fail 'unrelated shortcut link removed'
)
test_absent_installation_keeps_source() (
  setup absent
  rm -f -- "$INSTALL_PATH"
  invoke || fail 'absent installation uninstall failed'
  assert_removed
  [[ -f "$SCRIPT_PATH" ]] || fail 'source removed when no installation exists'
)
test_failed_rollback_keeps_installation() (
  setup rollback
  mkdir -p "$STATE_DIR"; printf 'saved\n' > "$STATE_DIR/original-values"
  rollback_internal() { return 1; }
  if invoke; then fail 'rollback failure ignored'; fi
  [[ -f "$INSTALL_PATH" && -f "$SCRIPT_PATH" && -L "$SHORTCUT_PATH" ]] || fail 'failed rollback removed installed artifacts'
  assert_no_success
)
test_residual_state_failure_keeps_installation() (
  setup residual-state
  mkdir -p "$STATE_DIR"; printf 'retained\n' > "$STATE_DIR/unknown"
  rollback_internal() { printf 'called\n' > "$CASE_DIR/rollback-called"; return 1; }
  if invoke; then fail 'residual state cleanup failure ignored'; fi
  [[ -f "$CASE_DIR/rollback-called" && -f "$INSTALL_PATH" && -L "$SHORTCUT_PATH" ]] || fail 'residual state was skipped'
  assert_no_success
)
test_shortcut_remove_failure_is_reported() (
  setup shortcut-failure
  rm() { [[ "${*: -1}" != "$SHORTCUT_PATH" ]] || return 1; command rm "$@"; }
  if invoke; then fail 'shortcut remove failure ignored'; fi
  [[ -f "$INSTALL_PATH" && -f "$SCRIPT_PATH" && -L "$SHORTCUT_PATH" ]] || fail 'remove failure damaged installed/source artifacts'
  assert_no_success
)
test_install_remove_failure_is_reported() (
  setup install-failure
  rm() { [[ "${*: -1}" != "$INSTALL_PATH" ]] || return 1; command rm "$@"; }
  if invoke; then fail 'installed remove failure ignored'; fi
  [[ -f "$INSTALL_PATH" && -f "$SCRIPT_PATH" ]] || fail 'failed removal damaged installed/source artifacts'
  assert_no_success
)
test_cancel_does_not_mutate() (
  setup cancel
  invoke n || fail 'cancellation failed'
  [[ -f "$INSTALL_PATH" && -f "$SCRIPT_PATH" && -L "$SHORTCUT_PATH" ]] || fail 'cancellation changed artifacts'
)

failures=0
for test in test_download_uninstall_removes_installed_copy_only test_installed_path_uninstalls test_menu_uninstall_without_resolved_source test_process_substitution_resolves_then_uninstalls test_changed_owned_version_is_recognized test_unrelated_installed_file_is_preserved test_installed_symlink_is_preserved test_dangling_installed_symlink_is_preserved test_unrelated_shortcuts_are_preserved test_absent_installation_keeps_source test_failed_rollback_keeps_installation test_residual_state_failure_keeps_installation test_shortcut_remove_failure_is_reported test_install_remove_failure_is_reported test_cancel_does_not_mutate; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
