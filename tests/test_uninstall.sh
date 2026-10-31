#!/usr/bin/env bash
set -Eeuo pipefail
[[ $(uname -s) == Linux && ${BASH_VERSINFO[0]} -ge 4 ]] || { printf 'Tests require Linux and Bash 4+.\n' >&2; exit 2; }
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
SOURCE_HASH="$(sha256sum "$SCRIPT" | awk '{print $1}')"
# Extracted application functions share the language formatter.
# shellcheck source=/dev/null
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
for name in installed_script_owned uninstall_own_script remove_automatic_reports uninstall_menu resolve_source_path need_root need_command main menu run_mutation rollback_internal restore_rps restore_nic_ring remove_mss_rule restore_original_values managed_file_path restore_file remove_state_files sysctl_matches sysctl_value normalize_sysctl_value; do
  sed -n "/^${name}() {/,/^}/p" "$SCRIPT" >> "$TEST_DIR/functions.sh"
done
# The embedded Python contains unindented braces; delimit this function using
# the next shell function instead of the first closing brace.
sed -n '/^auto_report() {/,/^auto_tune() {/p' "$SCRIPT" | sed '$d' >> "$TEST_DIR/functions.sh"
# The real mutation wrapper may only lock this test's private directory.
sed -i "s@/run/netpilot.lock@$TEST_DIR/operation.lock@g" "$TEST_DIR/functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/functions.sh"
# Keep the canonical recovery implementation available for metadata readiness
# and file-only backups, even while individual fault cases replace its entry.
# shellcheck source=/dev/null
source <(declare -f rollback_internal | sed '1s/rollback_internal/fixture_canonical_rollback_internal/')
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { fail "$@"; }
show_menu() { :; }
# Every mutation path below is relocated to this test's private directory.
# Real CLI privilege checks are covered separately by container integration.
need_root() { :; }
# Routing and the mutation wrapper remain real; kernel effects are controlled,
# while removal and data preservation are observed on actual temporary files.
# shellcheck disable=SC2034
setup() {
  CASE_DIR="$TEST_DIR/$1"; mkdir -p "$CASE_DIR"
  INSTALL_PATH="$CASE_DIR/netpilot.sh"; SCRIPT_PATH="$CASE_DIR/download.sh"
  SHORTCUT_PATH="$CASE_DIR/netpilot"
  STATE_DIR="$CASE_DIR/state"; BACKUP_DIR="$STATE_DIR/backup"; SOURCE_SNAPSHOT=''
  SOURCE_PATH="$SCRIPT_PATH"; RESOLVED_SOURCE=''
  SYSCTL_FILE="$CASE_DIR/config/99-netpilot.conf"
  BBR_FILE="$CASE_DIR/config/10-netpilot-bbr.conf"
  BBR_MODULE_FILE="$CASE_DIR/config/modules.conf"
  LIMITS_FILE="$CASE_DIR/config/limits.conf"
  GAI_FILE="$CASE_DIR/config/gai.conf"
  KERNEL_STATE="$CASE_DIR/kernel-algorithm"
  REPORT_ROOT="$CASE_DIR/reports"
  AUTO_REPORT_ROOT="$REPORT_ROOT"; AUTO_LEGACY_REPORT_ROOT="$CASE_DIR/legacy-reports"
  UPDATE_URL='https://github.com/luckiestultra/netpilot/raw/refs/heads/main/netpilot.sh'
  cp "$SCRIPT" "$INSTALL_PATH"; cp "$SCRIPT" "$SCRIPT_PATH"
  ln -s "$INSTALL_PATH" "$SHORTCUT_PATH"
  : > "$CASE_DIR/prompts"; : > "$CASE_DIR/rollback-calls"
  : > "$CASE_DIR/kernel-writes"; printf 'bbr\n' > "$KERNEL_STATE"
  rollback_internal() { printf 'called\n' >> "$CASE_DIR/rollback-calls"; return 1; }
  np_set_language zh
}
sysctl() {
  case "${1:-}" in
    -n) [[ "${2:-}" == net.ipv4.tcp_congestion_control ]] || fail 'recovery tried to read an unexpected kernel parameter'; cat "$KERNEL_STATE" ;;
    -w)
      [[ "${2:-}" == net.ipv4.tcp_congestion_control=* ]] || fail 'recovery tried to write an unexpected kernel parameter'
      printf '%s\n' "$2" >> "$CASE_DIR/kernel-writes"
      printf '%s\n' "${2#*=}" > "$KERNEL_STATE" ;;
    *) fail 'recovery used an unexpected sysctl operation' ;;
  esac
}
read() {
  local n next
  for ((n=1;n<=$#;n++)); do
    if [[ "${!n}" == -p ]]; then next=$((n+1)); printf '%s\n' "${!next}" >> "$CASE_DIR/prompts"; fi
  done
  builtin read "$@"
}
invoke() {
  local answer="${1-y}"
  if (($#)); then shift; fi
  (uninstall_own_script "$@" <<< "$answer") > "$CASE_DIR/output" 2>&1
}
invoke_cli() {
  local input="$1"; shift
  (main uninstall "$@" <<< "$input") > "$CASE_DIR/output" 2>&1
}
invoke_menu() {
  local input="$1"
  SOURCE_PATH="$INSTALL_PATH"
  (main menu <<< "$input") > "$CASE_DIR/output" 2>&1
}
require_uninstall_menu() { declare -F uninstall_menu >/dev/null || fail 'uninstall_menu choice helper is missing'; }
saved_data() {
  mkdir -p "$BACKUP_DIR" "$CASE_DIR/config" "$REPORT_ROOT/run.previous"
  printf 'net.ipv4.tcp_congestion_control=cubic\n' > "$STATE_DIR/original-values"
  printf '# Original kernel configuration\n' > "$BACKUP_DIR/sysctl-file"
  printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$SYSCTL_FILE"
  printf 'precedence ::ffff:0:0/96 100\n' > "$GAI_FILE"
  printf '{"type":"unrelated-user-data","download_bps":100000000}\n' > "$REPORT_ROOT/run.previous/summary.json"
}
protected_snapshot() {
  python3 - "$STATE_DIR" "$CASE_DIR/config" "$REPORT_ROOT" "$CASE_DIR/foreign" "$KERNEL_STATE" <<'PY'
import hashlib,json,os,stat,sys
entries=[]
def capture(path):
    try: info=os.lstat(path)
    except FileNotFoundError:
        entries.append((path,'missing'));return
    mode=stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode): entries.append((path,'symlink',mode,os.readlink(path)))
    elif stat.S_ISDIR(info.st_mode):
        entries.append((path,'directory',mode))
        for name in sorted(os.listdir(path)): capture(os.path.join(path,name))
    else:
        with open(path,'rb') as stream: digest=hashlib.sha256(stream.read()).hexdigest()
        entries.append((path,'file',mode,digest))
for root in sys.argv[1:]: capture(root)
print(json.dumps(entries))
PY
}
assert_protected_unchanged() {
  protected_snapshot > "$CASE_DIR/after-snapshot"
  cmp -s "$CASE_DIR/before-snapshot" "$CASE_DIR/after-snapshot" || fail 'uninstall modified retained configuration, state, backup or reports'
}
assert_installed() {
  [[ -f "$INSTALL_PATH" && -f "$SCRIPT_PATH" && -L "$SHORTCUT_PATH" ]] || fail 'cancelled or failed uninstall changed installed artifacts'
}
assert_removed() {
  [[ ! -e "$INSTALL_PATH" && ! -L "$INSTALL_PATH" ]] || fail 'installed script remains'
  [[ ! -L "$SHORTCUT_PATH" ]] || fail 'owned shortcut remains'
}
assert_no_success() {
  if grep -Eq '程序、自有快捷命令和可识别的默认报告已清理|The tool, its owned shortcut and recognized default reports were removed|回退已完成|Rollback completed' "$CASE_DIR/output"; then fail 'failure reported success'; fi
}

test_completion_assertion_rejects_actual_success() (
  local language
  for language in zh en; do
    setup "completion-assertion-$language"; np_set_language "$language"
    invoke_cli y || fail 'success fixture could not uninstall'
    if (assert_no_success) > "$CASE_DIR/assertion-result" 2>&1; then
      fail 'failure assertion accepted the actual success message'
    fi
  done
)

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
  # Extracted resolve_source_path reads these runtime globals.
  # shellcheck disable=SC2034
  SOURCE_PATH='/dev/fd/999'
  # shellcheck disable=SC2034
  RESOLVED_SOURCE=''
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
  printf '\n# Another installed revision\n' >> "$INSTALL_PATH"
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
  setup shortcut-file
  rm -f -- "$SHORTCUT_PATH"
  printf 'other executable\n' > "$SHORTCUT_PATH"
  invoke || fail 'uninstall with unrelated shortcut file failed'
  [[ ! -e "$INSTALL_PATH" && -f "$SCRIPT_PATH" ]] || fail 'wrong installed/source result'
  [[ "$(cat "$SHORTCUT_PATH")" == 'other executable' ]] || fail 'unrelated shortcut file removed'
  setup shortcut-link
  rm -f -- "$SHORTCUT_PATH"
  ln -s "$CASE_DIR/other" "$SHORTCUT_PATH"
  invoke || fail 'uninstall with unrelated shortcut link failed'
  [[ ! -e "$INSTALL_PATH" && -f "$SCRIPT_PATH" ]] || fail 'wrong installed/source result'
  [[ "$(readlink "$SHORTCUT_PATH")" == "$CASE_DIR/other" ]] || fail 'unrelated shortcut link removed'
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
  saved_data
  protected_snapshot > "$CASE_DIR/before-snapshot"
  rollback_internal() { printf 'called\n' >> "$CASE_DIR/rollback-calls"; return 1; }
  if invoke y --rollback; then fail 'rollback failure ignored'; fi
  [[ -f "$INSTALL_PATH" && -f "$SCRIPT_PATH" && -L "$SHORTCUT_PATH" ]] || fail 'failed rollback removed installed artifacts'
  [[ "$(wc -l < "$CASE_DIR/rollback-calls")" == 1 ]] || fail 'explicit failed rollback was not attempted exactly once'
  assert_protected_unchanged
  assert_no_success
)
test_residual_state_failure_keeps_installation() (
  setup residual-state
  mkdir -p "$STATE_DIR"; : > "$STATE_DIR/original-values"
  printf 'retained\n' > "$STATE_DIR/unknown"
  rollback_internal() { printf 'called\n' > "$CASE_DIR/rollback-called"; return 1; }
  if invoke y --rollback; then fail 'residual state cleanup failure ignored'; fi
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

test_default_uninstall_keeps_configuration_backup_and_unrelated_files() (
  local language
  for language in zh en; do
    setup "keep-$language"; np_set_language "$language"
    saved_data
    protected_snapshot > "$CASE_DIR/before-snapshot"
    # The default must succeed even though restoring this fixture would fail.
    invoke_cli y || fail 'default uninstall tried to restore saved configuration'
    assert_removed
    [[ ! -s "$CASE_DIR/rollback-calls" ]] || fail 'default uninstall invoked rollback'
    assert_protected_unchanged
    [[ -f "$SCRIPT_PATH" ]] || fail 'default uninstall deleted its download source'
  done
)

test_uninstall_cleans_only_managed_default_reports() (
  local language route run_dir legacy custom
  for language in zh en; do
    for route in keep rollback cancel failure; do
      setup "report-cleanup-$language-$route"; saved_data; np_set_language "$language"
      run_dir="$(auto_report prepare "$AUTO_REPORT_ROOT" "$STATE_DIR")"
      # Even a damaged or unfinished new report is ours when its private marker
      # survives. Older reports are recognized by their original JSON type.
      printf '{broken\n' > "$run_dir/summary.json"
      legacy="$AUTO_LEGACY_REPORT_ROOT/run.previous"; mkdir -p "$legacy"
      printf '{"type":"netpilot-tune-report","version":1}\n' > "$legacy/summary.json"
      custom="$CASE_DIR/custom-reports"
      mkdir -p "$custom"; printf 'user-managed output\n' > "$custom/summary.json"
      case "$route" in
        keep) invoke_cli y || fail 'default uninstall report cleanup failed' ;;
        rollback)
          rollback_internal() { printf 'called\n' >> "$CASE_DIR/rollback-calls"; rm -rf -- "$STATE_DIR"; }
          invoke_cli y --rollback || fail 'rollback uninstall report cleanup failed' ;;
        cancel) invoke_cli n || fail 'cancelled uninstall failed' ;;
        failure) if invoke_cli y --rollback; then fail 'failed restoration unexpectedly uninstalled'; fi ;;
      esac
      case "$route" in
        keep|rollback)
          assert_removed
          [[ ! -e "$run_dir" && ! -e "$legacy" ]] || fail 'uninstall retained managed default reports'
          [[ "$route" != keep || -f "$STATE_DIR/original-values" ]] || fail 'report cleanup discarded recovery records' ;;
        *) assert_installed; [[ -f "$run_dir/summary.json" && -f "$legacy/summary.json" ]] || fail 'cancelled or failed uninstall removed reports' ;;
      esac
      [[ -f "$REPORT_ROOT/run.previous/summary.json" && -f "$custom/summary.json" ]] || fail 'report cleanup removed unrelated or custom data'
    done
  done
)

test_report_cleanup_does_not_follow_links_or_delete_user_files() (
  local kind run_dir
  for kind in root-link report-link fifo mixed; do
    setup "unsafe-report-$kind"
    run_dir="$(auto_report prepare "$AUTO_REPORT_ROOT" "$STATE_DIR")"
    printf 'private user file\n' > "$CASE_DIR/user-file"
    case "$kind" in
      root-link) mv "$AUTO_REPORT_ROOT" "$CASE_DIR/linked-reports"; ln -s "$CASE_DIR/linked-reports" "$AUTO_REPORT_ROOT" ;;
      report-link) ln -s "$CASE_DIR/user-file" "$run_dir/before.json" ;;
      fifo) mkfifo "$run_dir/before.json" ;;
      mixed) printf 'user notes\n' > "$run_dir/notes.txt" ;;
    esac
    if [[ "$kind" == mixed ]]; then
      invoke_cli y || fail 'unrelated files blocked tool removal'
      assert_removed
      [[ -f "$run_dir/notes.txt" && -f "$run_dir/.netpilot-report" ]] || fail 'mixed directory was deleted'
    else
      if invoke_cli y; then fail "unsafe report path was accepted: $kind"; fi
      assert_installed
    fi
    [[ "$(cat "$CASE_DIR/user-file")" == 'private user file' ]] || fail 'cleanup followed a symbolic link'
  done
)

test_default_uninstall_does_not_validate_or_follow_damaged_state() (
  local kind
  for kind in symlink dangling file incomplete; do
    setup "keep-state-$kind"; saved_data
    case "$kind" in
      symlink) mv "$STATE_DIR" "$CASE_DIR/foreign"; ln -s "$CASE_DIR/foreign" "$STATE_DIR" ;;
      dangling)
        rm -rf -- "$STATE_DIR"; mkdir "$CASE_DIR/foreign"
        printf 'retain this foreign data\n' > "$CASE_DIR/foreign/keep"
        ln -s "$CASE_DIR/foreign/absent" "$STATE_DIR" ;;
      file) rm -rf -- "$STATE_DIR"; printf 'damaged state path\n' > "$STATE_DIR" ;;
      incomplete) rm -f -- "$STATE_DIR/original-values"; printf 'unrecognized state\n' > "$STATE_DIR/unknown" ;;
    esac
    protected_snapshot > "$CASE_DIR/before-snapshot"
    invoke_cli y || fail "default uninstall refused damaged state: $kind"
    assert_removed
    [[ ! -s "$CASE_DIR/rollback-calls" ]] || fail "default uninstall followed state: $kind"
    assert_protected_unchanged
  done
)

test_explicit_rollback_uninstall_runs_before_removal() (
  setup rollback-success; saved_data
  local report_hash
  report_hash="$(sha256sum "$REPORT_ROOT/run.previous/summary.json" | awk '{print $1}')"
  rollback_internal() {
    [[ -f "$INSTALL_PATH" && -L "$SHORTCUT_PATH" ]] || fail 'tool was removed before restoration completed'
    printf 'called\n' >> "$CASE_DIR/rollback-calls"
    printf '# restored configuration\n' > "$SYSCTL_FILE"
    rm -rf -- "$STATE_DIR"
  }
  invoke_cli y --rollback || fail 'explicit rollback uninstall failed'
  assert_removed
  [[ "$(wc -l < "$CASE_DIR/rollback-calls")" == 1 && ! -e "$STATE_DIR" ]] || fail 'explicit rollback was skipped or repeated'
  [[ "$(cat "$SYSCTL_FILE")" == '# restored configuration' ]] || fail 'explicit rollback result was lost'
  [[ "$(sha256sum "$REPORT_ROOT/run.previous/summary.json" | awk '{print $1}')" == "$report_hash" ]] || fail 'rollback uninstall removed reports'
)

test_explicit_rollback_without_state_preserves_installation() (
  setup rollback-no-state
  if invoke_cli y --rollback; then fail 'requested rollback without saved state silently removed the tool'; fi
  assert_installed
  [[ ! -e "$STATE_DIR" && ! -s "$CASE_DIR/rollback-calls" ]] || fail 'missing rollback state was created or passed to restoration'
  assert_no_success
)

test_explicit_rollback_rejects_empty_and_unknown_only_state() (
  local kind failures=0
  for kind in empty unknown-only; do
    (
      setup "rollback-unrecognized-$kind"; saved_data
      rm -rf -- "$STATE_DIR"; mkdir "$STATE_DIR"
      if [[ "$kind" == unknown-only ]]; then printf 'unowned state data\n' > "$STATE_DIR/unknown"; fi
      protected_snapshot > "$CASE_DIR/before-snapshot"
      rollback_internal() {
        printf 'called\n' >> "$CASE_DIR/rollback-calls"
        fixture_canonical_rollback_internal "$@"
      }
      if invoke_cli y --rollback; then fail "unrecognized rollback state falsely reported restored and removed the tool: $kind"; fi
      assert_installed
      assert_protected_unchanged
      [[ ! -s "$CASE_DIR/rollback-calls" && ! -s "$CASE_DIR/kernel-writes" ]] || fail "unrecognized rollback metadata entered restoration: $kind"
      assert_no_success
    ) || failures=$((failures+1))
  done
  [[ "$failures" == 0 ]] || fail 'explicit rollback accepted state without recovery metadata'
)

test_file_only_backups_are_restored_without_original_values_marker() (
  local name kind target report_hash expected_hash
  for name in bbr-file bbr-module-file sysctl-file limits-file gai-file; do
    for kind in existing missing; do
      setup "rollback-file-only-$name-$kind"
      mkdir -p "$BACKUP_DIR" "$CASE_DIR/config" "$REPORT_ROOT/run.previous"
      printf 'cubic\n' > "$KERNEL_STATE"
      target="$(managed_file_path "$name")" || fail 'could not resolve canonical managed file'
      printf '# current configuration\n' > "$target"
      printf '{"status":"completed"}\n' > "$REPORT_ROOT/run.previous/summary.json"
      report_hash="$(sha256sum "$REPORT_ROOT/run.previous/summary.json" | awk '{print $1}')"
      if [[ "$kind" == existing ]]; then
        printf '# original %s configuration\n' "$name" > "$BACKUP_DIR/$name"
        expected_hash="$(sha256sum "$BACKUP_DIR/$name" | awk '{print $1}')"
      else
        : > "$BACKUP_DIR/$name.missing"
      fi
      [[ ! -e "$STATE_DIR/original-values" ]] || fail 'file-only fixture accidentally has a kernel recovery marker'
      rollback_internal() {
        [[ -f "$INSTALL_PATH" && -L "$SHORTCUT_PATH" ]] || fail 'file-only rollback started after deleting the tool'
        printf 'called\n' >> "$CASE_DIR/rollback-calls"
        fixture_canonical_rollback_internal "$@"
      }
      invoke_cli y --rollback || fail "legitimate file-only backup was refused: $name/$kind"
      assert_removed
      [[ "$(wc -l < "$CASE_DIR/rollback-calls")" == 1 && ! -e "$STATE_DIR" ]] || fail 'canonical file-only recovery was skipped, repeated or left owned metadata'
      if [[ "$kind" == existing ]]; then
        [[ -f "$target" && "$(sha256sum "$target" | awk '{print $1}')" == "$expected_hash" ]] || fail 'canonical file-only recovery did not restore backup bytes'
      else
        [[ ! -e "$target" && ! -L "$target" ]] || fail 'canonical missing-file backup did not restore initial absence'
      fi
      [[ "$(cat "$KERNEL_STATE")" == cubic && ! -s "$CASE_DIR/kernel-writes" ]] || fail 'file-only rollback changed a kernel value without recorded original values'
      [[ "$(sha256sum "$REPORT_ROOT/run.previous/summary.json" | awk '{print $1}')" == "$report_hash" ]] || fail 'file-only recovery changed measurement reports'
    done
  done
)

test_uninstall_rejects_unknown_options_before_confirmation() (
  local route variant status
  local -a options=()
  for route in helper cli; do
    for variant in unknown operand mixed; do
      setup "bad-option-$route-$variant"; saved_data
      protected_snapshot > "$CASE_DIR/before-snapshot"
      case "$variant" in
        unknown) options=(--not-a-real-option) ;;
        operand) options=(unexpected) ;;
        mixed) options=(--rollback --not-a-real-option) ;;
      esac
      status=0
      if [[ "$route" == helper ]]; then invoke y "${options[@]}" || status=$?
      else invoke_cli y "${options[@]}" || status=$?; fi
      [[ "$status" == 2 ]] || fail "invalid uninstall options did not return usage error: $route/$variant"
      [[ ! -s "$CASE_DIR/prompts" && ! -s "$CASE_DIR/rollback-calls" ]] || fail 'invalid uninstall options prompted or attempted restoration'
      assert_installed
      assert_protected_unchanged
      assert_no_success
    done
  done
)

test_uninstall_confirmation_defaults_to_cancel() (
  local route answer
  for route in helper cli; do
    for answer in n N '' invalid eof; do
      setup "cancel-$route-${answer:-empty}"; saved_data
      protected_snapshot > "$CASE_DIR/before-snapshot"
      if [[ "$answer" == eof ]]; then
        if [[ "$route" == helper ]]; then
          (uninstall_own_script < /dev/null) > "$CASE_DIR/output" 2>&1 || fail 'EOF did not cancel uninstall cleanly'
        else
          (main uninstall < /dev/null) > "$CASE_DIR/output" 2>&1 || fail 'CLI EOF did not cancel uninstall cleanly'
        fi
      elif [[ "$route" == helper ]]; then invoke "$answer" || fail 'uninstall cancellation failed'
      else invoke_cli "$answer" || fail 'CLI uninstall cancellation failed'; fi
      assert_installed
      assert_protected_unchanged
      [[ ! -s "$CASE_DIR/rollback-calls" ]] || fail 'cancelled uninstall restored configuration'
      assert_no_success
    done
  done
)

test_bilingual_menu_default_and_keep_choice_route() (
  require_uninstall_menu
  local language choice
  for language in zh en; do
    for choice in '' 1; do
      setup "menu-keep-$language-${choice:-default}"; saved_data; np_set_language "$language"
      protected_snapshot > "$CASE_DIR/before-snapshot"
      invoke_menu $'7\n'"$choice"$'\ny' || fail 'menu keep/default selection did not uninstall'
      assert_removed
      assert_protected_unchanged
      [[ ! -s "$CASE_DIR/rollback-calls" ]] || fail 'menu keep/default selection invoked restoration'
    done
  done
)

test_bilingual_menu_rollback_choice_route() (
  require_uninstall_menu
  local language
  for language in zh en; do
    setup "menu-rollback-$language"; saved_data; np_set_language "$language"
    rollback_internal() { printf 'called\n' >> "$CASE_DIR/rollback-calls"; rm -rf -- "$STATE_DIR"; }
    invoke_menu $'7\n2\ny' || fail 'menu rollback selection failed'
    assert_removed
    [[ "$(wc -l < "$CASE_DIR/rollback-calls")" == 1 && ! -e "$STATE_DIR" ]] || fail 'menu selection 2 did not request rollback exactly once'
    [[ -f "$REPORT_ROOT/run.previous/summary.json" ]] || fail 'menu rollback removed reports'
  done
)

test_bilingual_menu_cancellation_and_eof() (
  require_uninstall_menu
  local language input
  for language in zh en; do
    for input in $'7\n0\n0' '7' $'7\n1' $'7\n2' $'7\ninvalid\n0\n0'; do
      setup "menu-cancel-$language-$(printf '%s' "$input" | tr -cd 'a-z0-9')"; saved_data; np_set_language "$language"
      protected_snapshot > "$CASE_DIR/before-snapshot"
      invoke_menu "$input" || fail 'menu cancellation or EOF failed'
      assert_installed
      assert_protected_unchanged
      [[ ! -s "$CASE_DIR/rollback-calls" ]] || fail 'cancelled menu operation invoked rollback'
      assert_no_success
    done
  done
)

failures=0
for test in test_completion_assertion_rejects_actual_success test_download_uninstall_removes_installed_copy_only test_installed_path_uninstalls test_menu_uninstall_without_resolved_source test_process_substitution_resolves_then_uninstalls test_changed_owned_version_is_recognized test_unrelated_installed_file_is_preserved test_installed_symlink_is_preserved test_dangling_installed_symlink_is_preserved test_unrelated_shortcuts_are_preserved test_absent_installation_keeps_source test_failed_rollback_keeps_installation test_residual_state_failure_keeps_installation test_shortcut_remove_failure_is_reported test_install_remove_failure_is_reported test_cancel_does_not_mutate test_default_uninstall_keeps_configuration_backup_and_unrelated_files test_uninstall_cleans_only_managed_default_reports test_report_cleanup_does_not_follow_links_or_delete_user_files test_default_uninstall_does_not_validate_or_follow_damaged_state test_explicit_rollback_uninstall_runs_before_removal test_explicit_rollback_without_state_preserves_installation test_explicit_rollback_rejects_empty_and_unknown_only_state test_file_only_backups_are_restored_without_original_values_marker test_uninstall_rejects_unknown_options_before_confirmation test_uninstall_confirmation_defaults_to_cancel test_bilingual_menu_default_and_keep_choice_route test_bilingual_menu_rollback_choice_route test_bilingual_menu_cancellation_and_eof; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$(sha256sum "$SCRIPT" | awk '{print $1}')" == "$SOURCE_HASH" ]] || fail 'uninstall tests modified source bytes'
[[ "$failures" == 0 ]]
