#!/usr/bin/env bash
# Exercise the actual CLI and reader with private temporary reports; no system writes.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/netpilot.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() {
  local expected="$1"; shift
  local rc=0
  "$@" > "$TMP/out" 2>&1 || rc=$?
  [[ "$rc" == "$expected" ]] || fail "expected status $expected, got $rc: $*"
}

# Generate real summaries through the same writer used by automatic tuning.
make_report() {
  mkdir -p -- "$1"
  bash -c 'source "$1"; auto_report summary "$2" failed before 1 134217728 balanced 0 0 0 not-needed not-needed "$3"' \
    _ "$SCRIPT" "$1" "$2" > /dev/null
}

reports="$TMP/reports with spaces"
make_report "$reports/run.zzz" 'older report'
make_report "$reports/run.aaa" 'latest report'
mkdir -p "$reports/run.incomplete"
python3 - "$reports" <<'PY'
import os, sys
from pathlib import Path
root = Path(sys.argv[1])
os.utime(root / 'run.zzz/summary.json', ns=(1000000000, 1000000000))
os.utime(root / 'run.aaa/summary.json', ns=(2000000000, 2000000000))
os.utime(root / 'run.zzz', ns=(9000000000, 9000000000))
PY

bash "$SCRIPT" report --report-dir "$reports" > "$TMP/out" 2>&1 || fail 'report CLI cannot display the newest report'
grep -q 'latest report' "$TMP/out" || fail 'latest summary was not displayed'
! grep -q 'older report' "$TMP/out" || fail 'directory name or directory time overrode summary modification time'
grep -q 'run.aaa/summary.json' "$TMP/out" || fail 'selected path was not shown'
grep -q '最新报告' "$TMP/out" || fail 'Chinese report heading is missing'
printf '%s\n' 'PASS: actual report CLI selects latest summary by file time, including paths with spaces'

grep -q '流程：失败' "$TMP/out" || fail 'default report needs a readable flow status'
! grep -q '"type"' "$TMP/out" || fail 'default report should not dump raw JSON'
python3 - "$TMP/out" "$SCRIPT" "$reports" <<'PY'
import json, shlex, subprocess, sys
from pathlib import Path
line = next(line for line in Path(sys.argv[1]).read_text().splitlines() if line.startswith('完整数据：'))
command = shlex.split(line.split('：', 1)[1])
assert command[0] == 'netpilot' and '--json' in command
data = subprocess.check_output(['bash', sys.argv[2], *command[1:]], text=True)
assert json.loads(data) == json.loads((Path(sys.argv[3]) / 'run.aaa/summary.json').read_text())
PY
bash "$SCRIPT" report --json --report-dir "$reports" > "$TMP/raw"
python3 - "$TMP/raw" "$reports/run.aaa/summary.json" <<'PY'
import json, sys
from pathlib import Path
assert json.loads(Path(sys.argv[1]).read_text()) == json.loads(Path(sys.argv[2]).read_text())
PY
printf '%s\n' 'PASS: readable report by default; --json emits the complete original data without a banner'

NETPILOT_LANG=zh bash "$SCRIPT" --lang en report --report-dir "$reports" > "$TMP/out" 2>&1
grep -q 'Latest report:' "$TMP/out" || fail 'English report heading is missing'
bash "$SCRIPT" report --help > "$TMP/out" 2>&1
grep -q 'report' "$TMP/out" || fail 'report help is unavailable'
expect_failure 2 bash "$SCRIPT" report --unknown
expect_failure 2 bash "$SCRIPT" report --report-dir
expect_failure 2 bash "$SCRIPT" report --report-dir ''
printf '%s\n' 'PASS: report language, help and argument validation'

for phase in before after; do
  folder="$TMP/measurement-$phase/run.fixture"
  mkdir -p "$folder"
  python3 - "$folder/$phase.json" <<'PY'
from pathlib import Path
import json, sys
Path(sys.argv[1]).write_text(json.dumps(dict(ok=False, error='HTTP 403: download request, 16777216 bytes; literal \x1b[31m')))
PY
  if [[ "$phase" == before ]]; then flow=failed; else flow=partial; fi
  bash -c 'source "$1"; auto_report summary "$2" "$3" "$4" 1 134217728 balanced 0 0 0 not-needed not-needed "measurement failed"' \
    _ "$SCRIPT" "$folder" "$flow" "$phase" > /dev/null
  for lang in zh en; do
    bash "$SCRIPT" --lang "$lang" report --report-dir "${folder%/*}" > "$TMP/out"
    grep -q 'HTTP 403.*16777216' "$TMP/out" || fail 'readable report hides the concrete measurement error'
    if [[ "$lang" == zh ]]; then grep -q '测速错误：' "$TMP/out" || fail 'Chinese measurement error label is missing'
    else grep -q 'Measurement error:' "$TMP/out" || fail 'English measurement error label is missing'; fi
    ! grep -q $'\033' "$TMP/out" || fail 'measurement error emitted a terminal control character'
  done
done
printf '%s\n' 'PASS: readable reports show bounded escaped before/after measurement errors in both languages'

expect_failure 1 bash "$SCRIPT" report --report-dir "$TMP/missing"
grep -q '暂无' "$TMP/out" || fail 'missing reports need a clear message'
[[ ! -e "$TMP/missing" ]] || fail 'read-only report command created a directory'
mkdir "$TMP/empty"
expect_failure 1 bash "$SCRIPT" report --report-dir "$TMP/empty"
grep -q '暂无' "$TMP/out" || fail 'empty reports need a clear message'
printf '%s\n' 'PASS: missing and empty report roots do not create state'

# A corrupt latest summary must not silently display an older successful run.
printf '{invalid JSON\n' > "$reports/run.aaa/summary.json"
expect_failure 1 bash "$SCRIPT" report --report-dir "$reports"
grep -q '无法读取最新报告' "$TMP/out" || fail 'corrupt latest report needs a clear error'
! grep -q 'older report' "$TMP/out" || fail 'corruption silently fell back to an old report'
printf '{"type":"foreign","version":1}\n' > "$reports/run.aaa/summary.json"
expect_failure 1 bash "$SCRIPT" report --report-dir "$reports"
printf '%s\n' 'PASS: corrupt and unrelated latest JSON are rejected without fallback'

printf '{"type":"netpilot-tune-report","version":1,"status":"completed"}\n' > "$reports/run.aaa/summary.json"
expect_failure 1 bash "$SCRIPT" report --report-dir "$reports"
grep -q '无法读取最新报告' "$TMP/out" || fail 'incomplete completed report was accepted'
printf '%s\n' 'PASS: a completed status alone cannot make an incomplete report valid'

# Build a completed report using the actual measurement validator and summary writer.
complete="$TMP/complete/run.success"
mkdir -p "$complete"
python3 - "$complete" <<'PY'
from pathlib import Path
import json, sys
root = Path(sys.argv[1])
for phase, down, up, latency in [('before', 100e6, 40e6, 50), ('after', 125e6, 50e6, 40)]:
    budget = 67108864
    data = dict(type='netpilot-http-measurement', version=1, ok=True, phase=phase,
                endpoint='https://speed.cloudflare.com', address='1.1.1.1', port=443, node='NRT',
                latency_method='tcp-connect-estimate', latency_ms=latency, budget_bytes=budget,
                reserved_bytes=budget, timeout_seconds=30, download_bps=down, upload_bps=up)
    for direction, rate in [('download', down), ('upload', up)]:
        size = budget // 2
        data[direction] = dict(request_sizes=[size], payload_bytes=size, duration_seconds=size*8/rate,
                               bits_per_second=rate, quality='sampled' if size*8/rate >= 3 else 'budget-limited')
    (root / (phase+'.json')).write_text(json.dumps(data))
PY
bash -c 'source "$1"; auto_report summary "$2" completed completed 0 134217728 balanced 1 1 1 verified not-needed ""' \
  _ "$SCRIPT" "$complete" > /dev/null
bash "$SCRIPT" report --report-dir "$TMP/complete" > "$TMP/out"
grep -q '流程：完成' "$TMP/out" || fail 'completed report status is missing'
grep -q '配置：已应用并核验' "$TMP/out" || fail 'verified configuration is not distinct from flow completion'
grep -q '100.00.*125.00' "$TMP/out" || fail 'download observations are missing'
grep -q '40.00.*50.00' "$TMP/out" || fail 'upload observations are missing'
grep -q '50.000.*40.000' "$TMP/out" || fail 'TCP-connect latency observations are missing'
grep -q '预算' "$TMP/out" || fail 'limited sample warning is missing'
NETPILOT_LANG=en bash "$SCRIPT" report --report-dir "$TMP/complete" > "$TMP/out"
grep -q 'Flow: Completed' "$TMP/out" || fail 'English readable result is missing'
printf '%s\n' 'PASS: completed summary separates flow, configuration, measurements and sample limits in both languages'

# Unfinished runs must distinguish recorded bytes from a complete transfer total.
python3 - "$SCRIPT" "$TMP" "$complete/summary.json" <<'PY'
from pathlib import Path
import copy, json, os, re, subprocess, sys

script, temporary, completed = sys.argv[1:]
original = Path(completed).read_bytes()
baseline = json.loads(original)

def unfinished(name, status, variant, lang):
    folder = Path(temporary) / ('payload-' + name + '-' + lang) / 'run.fixture'
    folder.mkdir(parents=True)
    before = copy.deepcopy(baseline['before'])
    after = None
    if status == 'failed':
        before.update(ok=False, error='synthetic transfer interruption')
    else:
        after = copy.deepcopy(baseline['after'])
        after.update(ok=False, error='synthetic transfer interruption', reserved_bytes=524288)
        for direction in ('download', 'upload'):
            after[direction].update(request_sizes=[262144], payload_bytes=131072)
    stream = before['upload']
    if variant == 'missing': stream.pop('payload_bytes')
    elif variant == 'missing-direction': before.pop('upload')
    elif variant == 'bool': stream['payload_bytes'] = True
    elif variant == 'negative': stream['payload_bytes'] = -1
    elif variant == 'float': stream['payload_bytes'] = 1.0
    elif variant == 'string': stream['payload_bytes'] = '1024'
    elif variant == 'over-cap': stream['payload_bytes'] = baseline['budget_bytes'] + 1
    elif variant == 'invalid-direction': before['upload'] = []
    elif variant == 'no-measurements': before = after = None
    elif variant == 'zero':
        for direction in ('download', 'upload'): before[direction]['payload_bytes'] = 0
    for phase, value in [('before', before), ('after', after)]:
        if value is not None:
            (folder / (phase + '.json')).write_text(json.dumps(value))
    stage, code = ('before', 1) if status == 'failed' else ('after', 130 if status == 'cancelled' else 1)
    changed = '0' if status == 'failed' else '1'
    verified = 'not-needed' if status == 'failed' else 'verified'
    command = ['bash', '-c', 'source "$1"; auto_report summary "${@:2}"', '_', script,
               str(folder), status, stage, str(code), str(baseline['budget_bytes']), 'balanced',
               changed, changed, changed, verified, 'not-needed', 'synthetic interruption']
    writer = subprocess.run(command, env={**os.environ, 'NETPILOT_LANG': lang},
                            capture_output=True, text=True, timeout=5)
    assert writer.returncode == 0, (name, lang, 'writer failed', writer.stdout, writer.stderr)
    cli = ['bash', script, '--lang', lang, 'report', '--report-dir', str(folder.parent)]
    reader = subprocess.run(cli, capture_output=True, text=True, timeout=5)
    assert reader.returncode == 0, (name, lang, 'reader failed', reader.stdout, reader.stderr)
    label, complete_label = ('已记录测试数据：', '已完成测试数据：') if lang == 'zh' else ('Recorded test payload:', 'Completed test payload:')
    for output in (writer.stdout, reader.stdout):
        assert 'Traceback' not in output and complete_label not in output, (name, lang, output)
        lines = [line for line in output.splitlines() if line.startswith(label)]
        assert len(lines) == 1, (name, lang, 'recorded payload label missing', output)
        line = lines[0]
        if variant in ('valid', 'zero'):
            expected = '0.00 MiB' if variant == 'zero' else ('64.00 MiB' if status == 'failed' else '64.25 MiB')
            assert expected in line, (name, lang, 'recorded sum is wrong', line)
            warnings = ('运行未完成', '记录可能不完整', '协议开销另计') if lang == 'zh' else ('unfinished', 'incomplete', 'overhead')
            assert all(word in line.lower() for word in warnings), (name, lang, 'missing limits', line)
        else:
            assert ('不可用' in line if lang == 'zh' else 'unavailable' in line.lower()), (name, lang, line)
            assert re.search(r'\d+(?:\.\d+)?\s*MiB', line) is None, (name, lang, 'invented a transfer total', line)
    raw = subprocess.run(cli + ['--json'], capture_output=True, text=True, timeout=5)
    assert raw.returncode == 0 and json.loads(raw.stdout) == json.loads((folder / 'summary.json').read_text())

for status in ('failed', 'partial', 'cancelled'):
    for lang in ('zh', 'en'):
        unfinished(status, status, 'valid', lang)
for lang in ('zh', 'en'):
    unfinished('recorded-zero', 'failed', 'zero', lang)
for variant in ('missing', 'missing-direction', 'bool', 'negative', 'float', 'string',
                'over-cap', 'invalid-direction', 'no-measurements'):
    for lang in ('zh', 'en'):
        unfinished(variant, 'failed', variant, lang)

# Historical completed reports keep their existing label and original JSON.
legacy = Path(temporary) / 'payload-legacy' / 'run.fixture'
legacy.mkdir(parents=True)
data = copy.deepcopy(baseline)
for value in (data, data['before'], data['after']): value.pop('budget_mode', None)
path = legacy / 'summary.json'
path.write_text(json.dumps(data))
saved = path.read_bytes()
for lang, label in [('zh', '已完成测试数据：'), ('en', 'Completed test payload:')]:
    cli = ['bash', script, '--lang', lang, 'report', '--report-dir', str(legacy.parent)]
    output = subprocess.check_output(cli, text=True, timeout=5)
    assert label + ('128.00 MiB' if lang == 'zh' else ' 128.00 MiB') in output
    assert '已记录测试数据：' not in output and 'Recorded test payload:' not in output
    assert json.loads(subprocess.check_output(cli + ['--json'], text=True, timeout=5)) == data
assert path.read_bytes() == saved and Path(completed).read_bytes() == original
print('PASS: unfinished payload totals and unavailable metrics stay honest in both languages; legacy completed JSON is unchanged')
PY

for state in partial cancelled failed; do
  state_code=1
  case "$state" in
    partial) stage=after; applied=1; verified=1; verify_status=verified; rollback_status=not-needed; expected='已应用并核验' ;;
    cancelled) stage=apply; state_code=130; applied=0; verified=0; verify_status=not-needed; rollback_status=completed; expected='已恢复首次原值' ;;
    failed) stage=apply; applied=0; verified=0; verify_status=failed; rollback_status=failed; expected='状态未确认' ;;
  esac
  folder="$TMP/states/run.$state"
  mkdir -p "$folder"
  bash -c 'source "$1"; auto_report summary "${@:2}"' _ "$SCRIPT" "$folder" "$state" "$stage" "$state_code" \
    134217728 balanced 1 "$applied" "$verified" "$verify_status" "$rollback_status" 'example failure' > /dev/null
  bash "$SCRIPT" report --report-dir "$TMP/states" > "$TMP/out"
  grep -q "配置：$expected" "$TMP/out" || fail "$state configuration state was misrepresented"
  ! grep -q '观测下载' "$TMP/out" || fail 'unfinished flow displayed a performance comparison'
done
printf '%s\n' 'PASS: partial, cancelled and failed restoration results retain distinct configuration states'

python3 - "$complete/summary.json" <<'PY'
from pathlib import Path
import json, sys
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.update(changed=False, applied=False, configuration_state='unchanged')
path.write_text(json.dumps(data))
PY
bash "$SCRIPT" report --report-dir "$TMP/complete" > "$TMP/out"
grep -q '本轮未修改' "$TMP/out" || fail 'unchanged run was shown as a new application'
grep -q '测量波动不能归因于调优' "$TMP/out" || fail 'unchanged run needs a clear measurement limit'
python3 - "$complete/summary.json" <<'PY'
from pathlib import Path
import json, sys
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['comparison'] = None
path.write_text(json.dumps(data))
PY
expect_failure 1 bash "$SCRIPT" report --report-dir "$TMP/complete"
grep -q '无法读取最新报告' "$TMP/out" || fail 'completed report without a comparison was accepted'
printf '%s\n' 'PASS: unchanged runs are identified; completed reports require a comparison'

mkdir -p "$TMP/linked/run.file" "$TMP/external/run.external" "$TMP/dir-linked"
make_report "$TMP/external/run.external" 'DO_NOT_DISCLOSE'
ln -s "$TMP/external" "$TMP/root-link"
expect_failure 1 bash "$SCRIPT" report --report-dir "$TMP/root-link"
! grep -q 'DO_NOT_DISCLOSE' "$TMP/out" || fail 'report-root symlink exposed another report'
ln -s "$TMP/external/run.external/summary.json" "$TMP/linked/run.file/summary.json"
expect_failure 1 bash "$SCRIPT" report --report-dir "$TMP/linked"
! grep -q 'DO_NOT_DISCLOSE' "$TMP/out" || fail 'summary symlink exposed another file'
ln -s "$TMP/external/run.external" "$TMP/dir-linked/run.link"
expect_failure 1 bash "$SCRIPT" report --report-dir "$TMP/dir-linked"
! grep -q 'DO_NOT_DISCLOSE' "$TMP/out" || fail 'run-directory symlink exposed another report'
mkdir -p "$TMP/fifo/run.pipe"
mkfifo "$TMP/fifo/run.pipe/summary.json"
expect_failure 1 timeout 5 bash "$SCRIPT" report --report-dir "$TMP/fifo"
printf '%s\n' 'PASS: report and directory symlinks and non-regular files are not followed or blocked on'

mkdir -p "$TMP/large/run.large"
python3 - "$TMP/large/run.large/summary.json" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b' ' * (1048576 + 1))
PY
expect_failure 1 bash "$SCRIPT" report --report-dir "$TMP/large"
printf '%s\n' 'PASS: oversized reports are rejected'

make_report "$TMP/controls/run.control" $'literal \033[31m \u009b31m terminal text'
bash "$SCRIPT" report --report-dir "$TMP/controls" > "$TMP/out" 2>&1
python3 - "$TMP/out" <<'PY'
from pathlib import Path
import sys
output = Path(sys.argv[1]).read_bytes()
assert b'\x1b' not in output and b'\xc2\x9b' not in output, 'raw terminal escape in report output'
PY
printf '%s\n' 'PASS: report strings are displayed as data, without raw terminal escapes'

# Redirect only the test's default report location, keeping the real reader/menu.
for lang in zh en; do
  printf '10\n0\n' | NETPILOT_LANG="$lang" bash -c '
    source "$1"
    report_fixture="$2"
    report_command() { auto_report view "$report_fixture"; }
    menu
  ' _ "$SCRIPT" "$TMP/controls" > "$TMP/out" 2>&1 || fail 'menu report action failed'
  grep -q 'run.control/summary.json' "$TMP/out" || fail 'main-menu 10 did not display the report'
  ! grep -q 'Invalid option.\|无效选项' "$TMP/out" || fail 'menu rejected the new report action'
done
printf '%s\n' 'PASS: Chinese and English main-menu report action returns to menu'

expect_failure 1 bash "$SCRIPT" report --report-dir "$TMP/default-absent"
[[ ! -e /var/lib/netpilot && ! -e /usr/local/bin/netpilot.sh && ! -e /usr/local/bin/netpilot && ! -L /usr/local/bin/netpilot ]] || fail 'report display installed or tuned the system'
printf '%s\n' 'PASS: report viewing never installs or writes tuning state'
