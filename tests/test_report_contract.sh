#!/usr/bin/env bash
# Validate report semantics using real summaries and the actual read-only CLI.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_OVERRIDE:-$ROOT/netpilot.sh}"
python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import copy, json, subprocess, sys, tempfile

script = str(Path(sys.argv[1]).resolve())
temporary = tempfile.TemporaryDirectory()
root = Path(temporary.name)

def write_measurements(folder):
    for phase, down, up, latency in [('before', 100e6, 40e6, 50), ('after', 125e6, 50e6, 40)]:
        budget = 67108864
        data = dict(type='netpilot-http-measurement', version=1, ok=True, phase=phase,
                    endpoint='https://speed.cloudflare.com', address='1.1.1.1', port=443,
                    node='NRT', family='IPv4', node_verified=True, connection_policy='pinned-preconnected',
                    latency_method='tcp-connect-estimate', latency_ms=latency, budget_bytes=budget,
                    reserved_bytes=budget, timeout_seconds=30, download_bps=down, upload_bps=up)
        for direction, rate in [('download', down), ('upload', up)]:
            size = budget // 2
            duration = size * 8 / rate
            data[direction] = dict(request_sizes=[size], payload_bytes=size, duration_seconds=duration,
                                   bits_per_second=rate, quality='sampled' if duration >= 3 else 'budget-limited')
        (folder / (phase + '.json')).write_text(json.dumps(data))

def make_summary(name, status='failed', stage='before', code=1, changed=0, applied=0, verified=0,
                 verify_status='not-needed', rollback_status='not-needed'):
    folder = root / name / 'run.fixture'
    folder.mkdir(parents=True)
    if status == 'completed':
        write_measurements(folder)
    subprocess.run(['bash', '-c', 'source "$1"; auto_report summary "${@:2}"', '_', script,
                    str(folder), status, stage, str(code), '134217728', 'balanced', str(changed),
                    str(applied), str(verified), verify_status, rollback_status,
                    '' if status == 'completed' else 'fixture failure'],
                   capture_output=True, text=True, check=True)
    return folder / 'summary.json'

def read(path, json_mode=True):
    command = ['bash', script, '--lang', 'en', 'report', '--report-dir', str(path.parent.parent)]
    if json_mode:
        command.append('--json')
    return subprocess.run(command, capture_output=True, text=True, timeout=5)

# These states are emitted by auto_tune; stricter validation must retain them.
valid = [
    make_summary('baseline-failed'),
    make_summary('apply-restored', stage='apply', rollback_status='completed'),
    make_summary('apply-restore-failed', stage='apply', rollback_status='failed'),
    make_summary('verify-existing-failed', stage='verify', verify_status='failed'),
    make_summary('verify-new-restore-failed', stage='verify', changed=1, applied=1,
                 verify_status='failed', rollback_status='failed'),
    make_summary('partial-verified', status='partial', stage='after', changed=1, applied=1,
                 verified=1, verify_status='verified'),
    make_summary('partial-no-change', status='partial', stage='after'),
    make_summary('partial-existing-verified', status='partial', stage='after',
                 verified=1, verify_status='verified'),
    make_summary('cancel-before', status='cancelled', code=130),
    make_summary('cancel-apply-restored', status='cancelled', stage='apply', code=143,
                 rollback_status='completed'),
    make_summary('cancel-after-verified', status='cancelled', stage='after', code=130,
                 changed=1, applied=1, verified=1, verify_status='verified'),
    make_summary('cancel-just-finished', status='cancelled', stage='completed', code=143),
    make_summary('completed-new', status='completed', stage='completed', code=0,
                 changed=1, applied=1, verified=1, verify_status='verified'),
    make_summary('completed-existing', status='completed', stage='completed', code=0,
                 verified=1, verify_status='verified'),
    make_summary('completed-no-config', status='completed', stage='completed', code=0),
]
for path in valid:
    result = read(path)
    assert result.returncode == 0, (path.parent.parent.name, result.stderr)
    assert json.loads(result.stdout) == json.loads(path.read_text())
print('PASS: report validation preserves real failure, cancellation, unchanged and completed states')

base = json.loads(valid[12].read_text())
failure = json.loads(valid[2].read_text())

def rejected(name, original, update):
    folder = root / ('invalid-' + name) / 'run.fixture'
    folder.mkdir(parents=True)
    value = copy.deepcopy(original)
    update(value)
    path = folder / 'summary.json'
    path.write_text(json.dumps(value))
    for json_mode in (False, True):
        result = read(path, json_mode)
        assert result.returncode == 1, (name, 'accepted corrupt report', result.stdout, result.stderr)
        assert not result.stdout, (name, 'partial misleading output', result.stdout)
        assert 'Cannot read the latest report:' in result.stderr, (name, result.stderr)

for name, original, update in [
    ('restoration-marked-verified', failure, lambda d: d.update(configuration_state='verified')),
    ('verified-flag-disagrees', base, lambda d: d.update(verified=False)),
    ('applied-without-change', base, lambda d: d.update(changed=False)),
    ('completed-failure-code', base, lambda d: d.update(exit_code=1)),
    ('completed-wrong-stage', base, lambda d: d.update(stage='before')),
    ('cancelled-with-failure-code', json.loads(valid[8].read_text()), lambda d: d.update(exit_code=1)),
    ('partial-wrong-stage', json.loads(valid[5].read_text()), lambda d: d.update(stage='before')),
    ('completed-verify-failed', json.loads(valid[14].read_text()), lambda d: d.update(verify_status='failed')),
    ('partial-verify-failed', json.loads(valid[6].read_text()), lambda d: d.update(verify_status='failed')),
    ('baseline-marked-changed', json.loads(valid[0].read_text()), lambda d: d.update(changed=True)),
    ('baseline-marked-applied', json.loads(valid[0].read_text()),
     lambda d: d.update(changed=True, applied=True, configuration_state='applied')),
    ('baseline-marked-verified', json.loads(valid[0].read_text()),
     lambda d: d.update(verified=True, verify_status='verified')),
    ('baseline-verification-failed', json.loads(valid[0].read_text()), lambda d: d.update(verify_status='failed')),
    ('baseline-marked-restored', json.loads(valid[0].read_text()),
     lambda d: d.update(rollback_status='completed', configuration_state='restored')),
    ('baseline-restoration-failed', json.loads(valid[0].read_text()),
     lambda d: d.update(rollback_status='failed', configuration_state='unknown')),
]:
    rejected(name, original, update)
print('PASS: contradictory flow, configuration and restoration claims are rejected')

for name, update in [
    ('peer-changed', lambda d: d['after'].update(address='1.0.0.1')),
    ('node-changed', lambda d: d['after'].update(node='SIN')),
    ('family-changed', lambda d: d['after'].update(family='IPv6')),
    ('connection-policy-changed', lambda d: d['after'].update(connection_policy='reconnected')),
    ('node-verification-changed', lambda d: d['after'].update(node_verified=False)),
    ('timeout-changed', lambda d: d['after'].update(timeout_seconds=31)),
    ('request-schedule-changed', lambda d: d['after']['download'].update(request_sizes=[16777216,16777216])),
    ('reported-rate-inconsistent', lambda d: d['after'].update(download_bps=1.0)),
    ('percentage-invented', lambda d: d['comparison'].update(download_change_pct=9999)),
    ('latency-delta-invented', lambda d: d['comparison'].update(latency_delta_ms=9999)),
    ('sample-limit-hidden', lambda d: d['comparison'].update(budget_limited=False)),
    ('sample-quality-inconsistent', lambda d: d['before']['upload'].update(quality='budget-limited')),
    ('whole-budget-mismatch', lambda d: d.update(budget_bytes=67108864)),
]:
    rejected(name, base, update)
print('PASS: completed reports revalidate embedded measurements, matching conditions and derived comparisons')

result = read(valid[12], json_mode=False)
assert result.returncode == 0, result.stderr
assert 'Report updated:' in result.stdout and 'Historical run record' in result.stdout, result.stdout
assert 'Report updated:' not in read(valid[12]).stdout
print('PASS: readable results identify a dated historical snapshot without changing JSON output')
temporary.cleanup()
PY
