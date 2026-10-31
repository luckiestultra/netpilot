#!/usr/bin/env bash
# Per-run restoration uses actual temporary files and a file-backed sysctl command.
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'command rm -rf -- "$TMP"' EXIT
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
source <(sed -n '/^# BEGIN RUN RECOVERY$/,/^# END RUN RECOVERY$/p' "$SCRIPT")
declare -F tuning_run_begin >/dev/null || { echo 'FAIL: per-run recovery backend is missing'; exit 1; }
mkdir "$TMP/bin"
cat > "$TMP/bin/sysctl" <<'SYSCTL'
#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['RUN_RECOVERY_KERNEL'])
d = json.loads(p.read_text())
if sys.argv[1] == '-n' and len(sys.argv) == 3:
    if sys.argv[2] not in d: sys.exit(1)
    print(d[sys.argv[2]])
elif sys.argv[1] == '-w' and len(sys.argv) == 3:
    k, value = sys.argv[2].split('=', 1)
    if k not in d or os.environ.get('RUN_RECOVERY_WRITE_FAILURE') == k: sys.exit(1)
    d[k] = value
    p.write_text(json.dumps(d))
    if os.environ.get('RUN_RECOVERY_RACE_FILE'):
        pathlib.Path(os.environ['RUN_RECOVERY_RACE_FILE']).write_text('# administrator concurrent edit\n')
else: sys.exit(1)
SYSCTL
chmod 0755 "$TMP/bin/sysctl"
export PATH="$TMP/bin:$PATH"
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
setup() {
  CASE_DIR="$(mktemp -d "$TMP/case.XXXXXX")"
  export RUN_RECOVERY_KERNEL="$CASE_DIR/kernel.json"
  printf '{"net.ipv4.tcp_congestion_control":"bbr","net.core.default_qdisc":"fq","net.core.rmem_max":"4194304"}\n' > "$RUN_RECOVERY_KERNEL"
  STATE_DIR="$CASE_DIR/state"; BACKUP_DIR="$STATE_DIR/backup"
  mkdir -m 0700 "$STATE_DIR" "$BACKUP_DIR" "$CASE_DIR/run"
  printf 'net.ipv4.tcp_congestion_control=cubic\n' > "$STATE_DIR/original-values"
  printf 'keep-first-backup\n' > "$BACKUP_DIR/bbr-file"
  BBR_FILE="$CASE_DIR/bbr.conf"; BBR_MODULE_FILE="$CASE_DIR/module.conf"; SYSCTL_FILE="$CASE_DIR/sysctl.conf"
  printf '# Managed by netpilot.sh.\nnet.ipv4.tcp_congestion_control = bbr\n' > "$SYSCTL_FILE"
  chmod 0640 "$SYSCTL_FILE"
  cp -p "$SYSCTL_FILE" "$CASE_DIR/original.conf"
  unset TUNING_RUN_DIR
}
set_key() { sysctl -w "$1=$2"; }
write_owned() {
  local target="$1" value="$2" temporary
  temporary="$(mktemp "$CASE_DIR/planned.XXXXXX")"
  printf '# Managed by netpilot.sh.\n%s\n' "$value" > "$temporary"
  chmod 0644 "$temporary"
  tuning_run_file_prepare "$target" "$temporary" || return 1
  mv -f -- "$temporary" "$target" || return 1
  tuning_run_record file "$target"
}
test_restore_this_run_not_first_ever() (
  setup
  tuning_run_begin "$CASE_DIR/run"
  tuning_run_validate
  tuning_run_record sysctl net.ipv4.tcp_congestion_control cubic
  set_key net.ipv4.tcp_congestion_control cubic
  write_owned "$SYSCTL_FILE" 'net.ipv4.tcp_congestion_control = cubic'
  write_owned "$BBR_MODULE_FILE" 'tcp_bbr'
  tuning_run_restore
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || fail 'restored initial-ever CUBIC instead of current-run BBR'
  cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'persistent bytes not restored'
  [[ "$(stat -c %a "$SYSCTL_FILE")" == 640 ]] || fail 'file mode not restored'
  [[ ! -e "$BBR_MODULE_FILE" ]] || fail 'new file was not removed'
  grep -Fxq 'net.ipv4.tcp_congestion_control=cubic' "$STATE_DIR/original-values" || fail 'first-ever baseline changed'
  [[ "$(cat "$BACKUP_DIR/bbr-file")" == keep-first-backup ]] || fail 'first-ever backup changed'
  tuning_run_restore || fail 'repeated restoration was not idempotent'
)
test_early_snapshot_rejects_drift() (
  setup; tuning_run_begin "$CASE_DIR/run"
  set_key net.core.rmem_max 8388608
  if tuning_run_validate; then fail 'pre-apply sysctl drift accepted'; fi
  [[ "$(sysctl -n net.core.rmem_max)" == 8388608 ]] || fail 'validation wrote sysctl'
)
test_external_changes_are_not_blessed_or_overwritten() (
  setup; tuning_run_begin "$CASE_DIR/run"
  write_owned "$SYSCTL_FILE" 'net.ipv4.tcp_congestion_control = cubic'
  printf '# administrator edit\n' > "$SYSCTL_FILE"
  if tuning_run_record file "$SYSCTL_FILE"; then fail 'record accepted external bytes'; fi
  if tuning_run_restore; then fail 'restore ignored external file'; fi
  grep -Fxq '# administrator edit' "$SYSCTL_FILE" || fail 'administrator edit was overwritten'
)
test_partial_sysctl_write_and_failed_restore() (
  setup; tuning_run_begin "$CASE_DIR/run"
  tuning_run_record sysctl net.core.rmem_max 8388608
  set_key net.core.rmem_max 8388608
  tuning_run_record sysctl net.ipv4.tcp_congestion_control cubic
  # Simulate the second write failing before changing its key.
  export RUN_RECOVERY_WRITE_FAILURE=net.ipv4.tcp_congestion_control
  tuning_run_restore
  [[ "$(sysctl -n net.core.rmem_max)" == 4194304 ]] || fail 'partial write not restored'
  unset RUN_RECOVERY_WRITE_FAILURE
  tuning_run_record sysctl net.core.rmem_max 8388608
  set_key net.core.rmem_max 8388608
  export RUN_RECOVERY_WRITE_FAILURE=net.core.rmem_max
  if tuning_run_restore; then fail 'failed sysctl restoration reported success'; fi
  [[ -f "$TUNING_RUN_DIR/run-snapshot.json" ]] || fail 'failure erased recovery material'
)
test_planned_file_race_is_rejected() (
  setup; tuning_run_begin "$CASE_DIR/run"
  printf '# administrator edit\n' > "$SYSCTL_FILE"
  if write_owned "$SYSCTL_FILE" 'replacement'; then fail 'pre-write conflict was ignored'; fi
  grep -Fxq '# administrator edit' "$SYSCTL_FILE" || fail 'pre-write conflict overwritten'
)
test_unsafe_snapshot_paths_rejected() (
  setup
  ln -s "$CASE_DIR/run" "$CASE_DIR/run-link"
  if tuning_run_begin "$CASE_DIR/run-link"; then fail 'symlink run directory accepted'; fi
  chmod 0777 "$CASE_DIR/run"
  if tuning_run_begin "$CASE_DIR/run"; then fail 'shared writable run directory accepted'; fi
)
test_applied_metadata_restored_without_losing_first_backup() (
  setup
  printf 'previous applied parameters\n' > "$STATE_DIR/applied-values"
  chmod 0600 "$STATE_DIR/applied-values"
  tuning_run_begin "$CASE_DIR/run"
  temporary="$(mktemp "$CASE_DIR/metadata.XXXXXX")"
  printf 'new applied parameters\n' > "$temporary"
  chmod 0600 "$temporary"
  tuning_run_file_prepare "$STATE_DIR/applied-values" "$temporary"
  mv -f -- "$temporary" "$STATE_DIR/applied-values"
  tuning_run_record file "$STATE_DIR/applied-values"
  tuning_run_restore
  [[ "$(cat "$STATE_DIR/applied-values")" == 'previous applied parameters' ]] || fail 'applied metadata not restored'
)
test_external_edit_between_restore_steps_is_preserved() (
  setup; tuning_run_begin "$CASE_DIR/run"
  tuning_run_record sysctl net.core.rmem_max 8388608
  set_key net.core.rmem_max 8388608
  write_owned "$SYSCTL_FILE" 'new planned configuration'
  export RUN_RECOVERY_RACE_FILE="$SYSCTL_FILE"
  if tuning_run_restore; then fail 'interleaved administrator edit was ignored'; fi
  grep -Fxq '# administrator concurrent edit' "$SYSCTL_FILE" || fail 'recovery overwrote an interleaved edit'
  [[ "$(sysctl -n net.core.rmem_max)" == 4194304 ]] || fail 'already restored sysctl was misreported'
)
test_restoration_checkpoint_failure_is_retryable() (
  setup; tuning_run_begin "$CASE_DIR/run"
  write_owned "$SYSCTL_FILE" 'new planned configuration'
  python3 - "$SCRIPT" "$TUNING_RUN_DIR" "$SYSCTL_FILE" "$BBR_FILE" "$BBR_MODULE_FILE" "$STATE_DIR/applied-values" <<'PY'
import pathlib, subprocess, sys
source = pathlib.Path(sys.argv[1]).read_text()
backend = source.split('tuning_run_backend() {\n', 1)[1].split("<<'PYRUN'\n", 1)[1].split('\nPYRUN\n', 1)[0]
checkpoint = 'entry.update(expected=current, touched=False); save(state)'
assert backend.count(checkpoint) == 1
fault = backend.replace(checkpoint, "entry.update(expected=current, touched=False); raise OSError('injected checkpoint failure')")
result = subprocess.run([sys.executable, '-', 'restore', *sys.argv[2:]], input=fault, text=True)
assert result.returncode != 0
PY
  cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'fault was injected before the file was actually restored'
  tuning_run_restore || fail 'retry rejected the tool-owned restored inode'
  cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'retry changed restored bytes'
)
for test in test_external_edit_between_restore_steps_is_preserved test_restoration_checkpoint_failure_is_retryable; do
  "$test"
  printf 'PASS: %s\n' "$test"
done
for test in test_restore_this_run_not_first_ever test_early_snapshot_rejects_drift test_external_changes_are_not_blessed_or_overwritten test_partial_sysctl_write_and_failed_restore test_planned_file_race_is_rejected test_unsafe_snapshot_paths_rejected test_applied_metadata_restored_without_losing_first_backup; do
  "$test"
  printf 'PASS: %s\n' "$test"
done
