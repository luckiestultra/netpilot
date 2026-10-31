#!/usr/bin/env bash
# Exercise concise outcomes through the real summary writer, reader and menu.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_OVERRIDE:-$ROOT/netpilot.sh}"
python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import json, os, re, subprocess, sys, tempfile

script = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)

    def measurements(folder):
        for phase, rate in [('before', 100e6), ('after', 125e6)]:
            size = 33554432
            data = dict(type='netpilot-http-measurement', version=1, ok=True, phase=phase,
                        endpoint='https://speed.cloudflare.com', address='1.1.1.1', port=443,
                        node='NRT', latency_method='tcp-connect-estimate', latency_ms=50,
                        budget_bytes=67108864, reserved_bytes=67108864, timeout_seconds=30,
                        download_bps=rate, upload_bps=rate)
            for direction in ('download', 'upload'):
                data[direction] = dict(request_sizes=[size], payload_bytes=size,
                                       duration_seconds=size*8/rate, bits_per_second=rate,
                                       quality='sampled' if size*8/rate >= 3 else 'budget-limited')
            (folder / (phase + '.json')).write_text(json.dumps(data))

    cases = [
        ('completed-new', 'completed', 'completed', 0, 1, 1, 1, 'verified', 'not-needed', False,
         '已调整并核验。', 'Adjusted and verified.'),
        ('completed-existing', 'completed', 'completed', 0, 0, 0, 1, 'verified', 'not-needed', False,
         '保留原配置。', 'Kept the original configuration.'),
        ('completed-no-change', 'completed', 'completed', 0, 0, 0, 0, 'not-needed', 'not-needed', False,
         '保留原配置。', 'Kept the original configuration.'),
        ('failed-restored-run', 'failed', 'after', 1, 1, 0, 0, 'restored', 'completed', True,
         '已恢复原配置。', 'Restored the original configuration.'),
        ('cancelled-restored-run', 'cancelled', 'apply', 130, 1, 0, 0, 'restored', 'completed', True,
         '已恢复原配置。', 'Restored the original configuration.'),
        ('legacy-restored-first', 'failed', 'apply', 1, 1, 0, 0, 'restored', 'completed', False,
         '已恢复首次原值。', 'Restored the first saved baseline.'),
        ('baseline-failed', 'failed', 'before', 1, 0, 0, 0, 'not-needed', 'not-needed', False,
         '未完成，配置未修改。', 'Incomplete; configuration unchanged.'),
        ('cancelled-unchanged', 'cancelled', 'before', 130, 0, 0, 0, 'not-needed', 'not-needed', False,
         '已取消，配置未修改。', 'Cancelled; configuration unchanged.'),
        ('restoration-failed', 'failed', 'apply', 1, 1, 0, 0, 'failed', 'failed', True,
         '未完成，配置恢复失败，需要处理。', 'Incomplete; configuration restoration failed, action required.'),
        ('legacy-partial-applied', 'partial', 'after', 1, 1, 1, 1, 'verified', 'not-needed', False,
         '配置已应用，效果检查未完成。', 'Configuration applied; effect checks incomplete.'),
        ('cancelled-applied', 'cancelled', 'after', 130, 1, 1, 1, 'verified', 'not-needed', False,
         '已取消，已应用配置仍保留。', 'Cancelled; applied configuration retained.'),
        ('unverified-applied', 'failed', 'verify', 1, 1, 1, 0, 'failed', 'not-needed', False,
         '未完成，配置已应用但未核验，需要处理。', 'Incomplete; configuration applied but unverified, action required.'),
        ('uncertain-write', 'failed', 'apply', 1, 1, 0, 0, 'not-needed', 'not-needed', False,
         '未完成，配置状态未确认，需要处理。', 'Incomplete; configuration state unknown, action required.'),
    ]
    forbidden = re.compile(r'^(?:流程|阶段|配置|核验|回滚|最终配置|Flow|Stage|Configuration|Verification|Rollback|Final configuration)[:：]', re.M)
    for name, status, stage, code, changed, applied, verified, verify, rollback, run_scope, zh, en in cases:
        for lang, outcome in [('zh', zh), ('en', en)]:
            folder = root / (name + '-' + lang) / 'run.fixture'
            folder.mkdir(parents=True)
            if status == 'completed':
                measurements(folder)
                (folder / 'algorithm.json').write_text(json.dumps(dict(
                    type='netpilot-algorithm-selection', version=1, status='preserved',
                    reason_code='no_consistent_gain', original='bbr', selected='bbr',
                    reserved_bytes=0, trials=[])))
            else:
                (folder / (('confirmation' if stage == 'confirm' else 'after' if stage == 'after' else 'before') + '.json')).write_text(
                    json.dumps(dict(ok=False, reserved_bytes=0, error='HTTP 403: fixture request; literal \x1b[31m')))
            if run_scope:
                (folder / 'run-snapshot.json').write_text('{}')
            error = '' if status == 'completed' else 'fixture interruption; literal \x1b[31m'
            writer = subprocess.run(['bash', '-c', 'source "$1"; auto_report summary "${@:2}"', '_', script,
                                     str(folder), status, stage, str(code), '134217728', 'balanced',
                                     str(changed), str(applied), str(verified), verify, rollback, error],
                                    env={**os.environ, 'NETPILOT_LANG': lang}, capture_output=True, text=True)
            assert writer.returncode == 0, (name, lang, writer.stdout, writer.stderr)
            saved = (folder / 'summary.json').read_bytes()
            data = json.loads(saved)
            cli = ['bash', script, '--lang', lang, 'report', '--report-dir', str(folder.parent)]
            reader = subprocess.run(cli, capture_output=True, text=True, timeout=5)
            assert reader.returncode == 0, (name, lang, reader.stdout, reader.stderr)
            expected = ('结果：' if lang == 'zh' else 'Result: ') + outcome
            for mode, output in [('writer', writer.stdout), ('reader', reader.stdout)]:
                assert output.splitlines()[0] == expected, (name, lang, mode, 'outcome must be first', output)
                assert not forbidden.search(output), (name, lang, mode, 'duplicate status panels', output)
                assert ('预算' in output if lang == 'zh' else 'Budget:' in output), output
                assert '\x1b' not in output, (name, mode, 'terminal control exposed', output)
                if status == 'completed':
                    assert ('算法：' in output if lang == 'zh' else 'Algorithm:' in output), output
                    assert ('持续收益' in output if lang == 'zh' else 'no consistent gain' in output), output
                    assert ('观测下载：' in output if lang == 'zh' else 'Observed download:' in output), output
                    if not changed:
                        assert ('不能归因于调优' in output if lang == 'zh' else 'cannot be attributed to tuning' in output), output
                        assert '最优' not in output and '无需调优' not in output, output
                else:
                    assert 'fixture interruption' in output, (name, mode, 'missing actual error', output)
                    assert 'HTTP 403' in output, (name, mode, 'missing actual measurement error', output)
            raw = subprocess.run(cli + ['--json'], capture_output=True, text=True, timeout=5)
            assert raw.returncode == 0 and json.loads(raw.stdout) == data, (name, raw.stderr)
            assert (folder / 'summary.json').read_bytes() == saved, (name, 'reader changed source data')
            if name == 'legacy-partial-applied':
                menu = subprocess.run(['bash', '-c', 'source "$1"; report_fixture="$2"; report_command() { auto_report view "$report_fixture"; }; menu', '_', script, str(folder.parent)],
                                      input='10\n0\n', env={**os.environ, 'NETPILOT_LANG': lang}, capture_output=True, text=True, timeout=5)
                assert menu.returncode == 0 and expected in menu.stdout, (lang, menu.stdout, menu.stderr)
                result_lines = [line for line in menu.stdout.splitlines() if line.startswith(('结果：', 'Result: '))]
                assert result_lines == [expected] and not forbidden.search(menu.stdout), menu.stdout
    print('PASS: real summary writer, report reader and menu share one truthful bilingual outcome and retain original JSON')
PY
