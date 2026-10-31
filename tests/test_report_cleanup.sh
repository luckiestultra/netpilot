#!/usr/bin/env bash
# Adversarial cleanup cases use only the uninstall fixture's private paths.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export SCRIPT_OVERRIDE="${SCRIPT_OVERRIDE:-$ROOT/netpilot.sh}"
source <(sed '/^failures=0$/,$d' "$ROOT/tests/test_uninstall.sh")

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

failures=0
for test in test_unknown_temporary_prefixes_are_not_ownership test_unsupported_versions_are_preserved test_cleanup_does_not_follow_ancestor_links test_replaced_directory_is_rejected_before_deletion; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
