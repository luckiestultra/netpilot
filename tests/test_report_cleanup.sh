#!/usr/bin/env bash
# Adversarial cleanup cases use only the uninstall fixture's private paths.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export SCRIPT_OVERRIDE="${SCRIPT_OVERRIDE:-$ROOT/netpilot.sh}"
source <(sed '/^failures=0$/,$d' "$ROOT/tests/test_uninstall.sh")
source <(sed -n '/^# BEGIN RUN RECOVERY$/,/^# END RUN RECOVERY$/p' "$SCRIPT_OVERRIDE")

test_unknown_temporary_prefixes_are_not_ownership() (
  local prefix run_dir
  for prefix in .summary.user-notes .http-report-notes; do
    setup "unknown-$prefix"
    run_dir="$(auto_report prepare "$AUTO_REPORT_ROOT" "$STATE_DIR")"
    printf 'private user notes\n' > "$run_dir/$prefix"
    invoke_cli y || fail 'unrelated files blocked uninstall'
    assert_removed
    [[ -f "$run_dir/$prefix" && "$(cat "$run_dir/$prefix")" == 'private user notes' ]] || fail 'temporary prefix caused deletion of user data'
  done
)

test_unsupported_versions_are_preserved() (
  local value kind run_dir
  for value in true 1.0; do
    for kind in marker summary; do
      setup "version-$kind-$value"
      run_dir="$AUTO_REPORT_ROOT/run.unknown"; mkdir -p "$run_dir"
      if [[ "$kind" == marker ]]; then
        printf '{"type":"netpilot-report-directory","version":%s}\n' "$value" > "$run_dir/.netpilot-report"
      else
        printf '{"type":"netpilot-tune-report","version":%s}\n' "$value" > "$run_dir/summary.json"
      fi
      invoke_cli y || fail 'unsupported metadata blocked uninstall'
      [[ -d "$run_dir" && -n "$(ls -A "$run_dir")" ]] || fail 'unsupported metadata was treated as version 1'
    done
  done
)

test_cleanup_does_not_follow_ancestor_links() (
  setup ancestor-link
  mkdir "$CASE_DIR/custom-storage"
  ln -s "$CASE_DIR/custom-storage" "$CASE_DIR/alias"
  AUTO_REPORT_ROOT="$CASE_DIR/alias/reports"
  local run_dir
  run_dir="$(auto_report prepare "$CASE_DIR/custom-storage/reports" "$STATE_DIR")"
  printf 'unmodified\n' > "$run_dir/before.json"
  if invoke_cli y; then fail 'ancestor symlink was followed during cleanup'; fi
  assert_installed
  [[ -f "$run_dir/before.json" && "$(cat "$run_dir/before.json")" == unmodified ]] || fail 'ancestor link target was modified'
)

test_replaced_directory_is_rejected_before_deletion() (
  local target run_dir archived
  for target in root run; do
    setup "replace-$target"
    run_dir="$(auto_report prepare "$AUTO_REPORT_ROOT" "$STATE_DIR")"
    printf 'unmodified\n' > "$run_dir/before.json"
    mkdir "$CASE_DIR/hooks"
    cat > "$CASE_DIR/hooks/sitecustomize.py" <<'PY'
import os, sys
from pathlib import Path
def schedule(frame, event, arg):
    if event != 'line' or frame.f_code.co_filename != '<stdin>':
        return schedule
    state = frame.f_locals
    if state.get('op') != 'cleanup':
        return schedule
    target = os.environ['REPLACE_TARGET']
    if target == 'root' and 'root_fd' in state and 'root_info' not in state:
        path = str(state['root'])
    elif target == 'run' and 'run_fd' in state:
        path = str(Path(state['root']) / state['name'])
    else:
        return schedule
    sys.settrace(None)
    os.rename(path, path + '-archive')
    os.symlink(path + '-archive', path)
    return None
if os.environ.get('REPLACE_TARGET'):
    sys.settrace(schedule)
PY
    if PYTHONPATH="$CASE_DIR/hooks" REPLACE_TARGET="$target" invoke_cli y; then
      fail 'directory replacement did not stop cleanup'
    fi
    assert_installed
    if [[ "$target" == root ]]; then archived="$AUTO_REPORT_ROOT-archive/${run_dir##*/}"
    else archived="$run_dir-archive"; fi
    [[ -f "$archived/before.json" && "$(cat "$archived/before.json")" == unmodified ]] || fail 'replacement was detected after deleting archived data'
  done
)

# Create a genuine per-run snapshot and mark an actual managed-file write.
pending_recovery_report() {
  local temporary
  mkdir -p "$CASE_DIR/config" "$BACKUP_DIR"
  printf 'net.ipv4.tcp_congestion_control=cubic\n' > "$STATE_DIR/original-values"
  printf 'first-ever backup\n' > "$BACKUP_DIR/sysctl-file"
  printf '# Managed by netpilot.sh.\n# Before this run\n' > "$SYSCTL_FILE"
  if [[ "${RECOVERY_LARGE:-0}" == 1 ]]; then
    python3 - "$SYSCTL_FILE" <<'PYCASE'
from pathlib import Path
import sys
with Path(sys.argv[1]).open('a') as stream: stream.write('#' + 'x' * 900000 + '\n')
PYCASE
  fi
  RECOVERY_RUN="$(auto_report prepare "$AUTO_REPORT_ROOT" "$STATE_DIR")"
  tuning_run_begin "$RECOVERY_RUN"
  temporary="$(mktemp "${SYSCTL_FILE}.planned.XXXXXX")"
  printf '# Managed by netpilot.sh.\n# Applied by this run\n' > "$temporary"
  tuning_run_file_prepare "$SYSCTL_FILE" "$temporary"
  mv -- "$temporary" "$SYSCTL_FILE"
  tuning_run_record file "$SYSCTL_FILE"
}

test_unfinished_recovery_survives_default_uninstall() (
  local mode language ordinary
  for mode in failed missing corrupt invalid-completed corrupt-snapshot oversized-snapshot; do
    for language in zh en; do
      setup "unfinished-recovery-$mode-$language"; np_set_language "$language"
      pending_recovery_report
      printf '# Concurrent administrator change\n' >> "$SYSCTL_FILE"
      if tuning_run_restore > "$CASE_DIR/restore-output" 2>&1; then fail 'recovery conflict fixture restored over an administrator edit'; fi
      auto_report summary "$RECOVERY_RUN" failed apply 1 1048576 balanced 1 1 0 not-needed failed 'recovery conflict' > /dev/null
      case "$mode" in
        missing) rm -- "$RECOVERY_RUN/summary.json" ;;
        corrupt) printf 'invalid JSON\n' > "$RECOVERY_RUN/summary.json" ;;
        corrupt-snapshot) printf 'invalid snapshot JSON\n' > "$RECOVERY_RUN/run-snapshot.json" ;;
        oversized-snapshot) truncate -s 16777217 "$RECOVERY_RUN/run-snapshot.json" ;;
        invalid-completed)
          python3 - "$RECOVERY_RUN/summary.json" <<'PYCASE'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); data = json.loads(path.read_text())
data['status'] = 'completed'
path.write_text(json.dumps(data))
PYCASE
          ;;
      esac
      cp -a "$RECOVERY_RUN" "$CASE_DIR/expected-run"
      cp "$SYSCTL_FILE" "$CASE_DIR/expected-config"
      ordinary="$(auto_report prepare "$AUTO_REPORT_ROOT" "$STATE_DIR")"
      printf 'ordinary report\n' > "$ordinary/before.json"
      invoke_cli y || fail 'retained recovery materials blocked default uninstall'
      assert_removed
      diff -r "$CASE_DIR/expected-run" "$RECOVERY_RUN" || fail 'default uninstall removed unfinished recovery materials'
      [[ ! -e "$ordinary" ]] || fail 'ordinary automatic report was not removed'
      cmp -s "$SYSCTL_FILE" "$CASE_DIR/expected-config" || fail 'default uninstall modified the retained configuration'
      grep -Fqx 'first-ever backup' "$BACKUP_DIR/sysctl-file" || fail 'default uninstall modified the first-ever backup'
      grep -Eq '恢复尚未确认|recovery is not confirmed' "$CASE_DIR/output" || fail 'retained recovery materials were not explained'
      grep -Fq "$RECOVERY_RUN" "$CASE_DIR/output" || fail 'retained recovery path was not shown'
    done
  done
)

test_settled_recovery_snapshots_are_cleaned() (
  local mode
  for mode in restored restored-large completed; do
    setup "settled-recovery-$mode"
    RECOVERY_LARGE=0
    [[ "$mode" != restored-large ]] || RECOVERY_LARGE=1
    pending_recovery_report
    if [[ "$mode" == restored* ]]; then
      if [[ "$mode" == restored-large ]]; then
        [[ "$(stat -c %s "$RECOVERY_RUN/run-snapshot.json")" -gt 1048576 ]] || fail 'large snapshot fixture did not exceed the report identity limit'
      fi
      tuning_run_restore || fail 'completed restoration fixture could not restore its actual file'
      grep -Fqx '# Before this run' "$SYSCTL_FILE" || fail 'completed restoration did not restore file contents'
    else
      python3 - "$RECOVERY_RUN" <<'PYCASE'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for phase in ('before', 'after'):
    stream = dict(request_sizes=[65536], payload_bytes=65536, duration_seconds=1.,
                  bits_per_second=524288., quality='budget-limited')
    data = dict(type='netpilot-http-measurement', version=1, ok=True, phase=phase,
                endpoint='https://speed.cloudflare.com', address='1.1.1.1', port=443,
                node='NRT', family='IPv4', latency_method='tcp-connect-estimate', latency_ms=1.,
                budget_bytes=524288, budget_mode='fixed', reserved_bytes=131072, timeout_seconds=5,
                download_bps=524288., upload_bps=524288., download=stream, upload=stream)
    (root / (phase + '.json')).write_text(json.dumps(data))
PYCASE
      auto_report summary "$RECOVERY_RUN" completed completed 0 1048576 balanced 1 1 1 verified not-needed '' > /dev/null || fail 'successful summary fixture was invalid'
    fi
    invoke_cli y || fail 'settled recovery snapshot blocked default uninstall'
    assert_removed
    [[ ! -e "$RECOVERY_RUN" ]] || fail 'settled recovery snapshot was retained unnecessarily'
    grep -Fqx 'first-ever backup' "$BACKUP_DIR/sysctl-file" || fail 'cleanup removed the first-ever backup'
  done
)

failures=0
for test in test_unfinished_recovery_survives_default_uninstall test_settled_recovery_snapshots_are_cleaned test_unknown_temporary_prefixes_are_not_ownership test_unsupported_versions_are_preserved test_cleanup_does_not_follow_ancestor_links test_replaced_directory_is_rejected_before_deletion; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
