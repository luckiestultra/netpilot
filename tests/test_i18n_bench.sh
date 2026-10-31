#!/usr/bin/env bash
# All traffic stays on a real loopback iperf3 server.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/netpilot.sh"
TMP="$(mktemp -d)"
server_pid=''
cleanup() {
  local status=$?
  if ((status != 0)); then
    for log in "$TMP"/live-*.log "$TMP"/server.log; do
      [[ ! -f "$log" ]] || { printf '\nFailure details: %s\n' "${log##*/}" >&2; cat "$log" >&2; }
    done
  fi
  if [[ -n "$server_pid" ]]; then kill -TERM "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf -- "$TMP"
  return "$status"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

NETPILOT_LANG=en
bench_usage > "$TMP/en-help"
grep -q 'NetPilot benchmark usage:' "$TMP/en-help" || fail 'English benchmark help missing'
if bench_command --peer 'host;touch bad' --yes > "$TMP/en-invalid" 2>&1; then fail 'unsafe peer accepted'; fi
grep -q 'valid peer' "$TMP/en-invalid" || fail 'English peer validation missing'

python3 - "$TMP" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
report = {'schema_version': 1, 'kind': 'netpilot-benchmark', 'peer': '127.0.0.1',
          'port': 5201, 'streams': 1, 'budget_bytes': 2097152, 'timeout_seconds': 5,
          'latency_enabled': False, 'direction': 'send', 'bytes_per_run_target': 1966080,
          'runs': [{'status': 'ok', 'direction': 'send', 'mbps': 10.0, 'seconds': 4.0,
                    'bytes': 2097152, 'sample_quality': 'bounded_sample',
                    'remote_endpoints': [{'address': '127.0.0.1', 'port': 5201}],
                    'retransmits': 0, 'cpu_host_percent': 2.0}]}
for name in ('before', 'after'):
    (root / (name + '.json')).write_text(json.dumps(report))
(root / 'invalid.json').write_text('{}')
PY
bench_summary "$TMP/before.json" > "$TMP/en-summary"
grep -q 'retransmits=' "$TMP/en-summary" || fail 'English benchmark summary missing'
bench_compare "$TMP/before.json" "$TMP/after.json" > "$TMP/en-compare"
grep -q 'change' "$TMP/en-compare" || fail 'English comparison missing'
if bench_compare "$TMP/invalid.json" "$TMP/invalid.json" > "$TMP/en-error" 2>&1; then fail 'invalid report accepted'; fi
grep -q 'Cannot compare:' "$TMP/en-error" || fail 'English comparison validation missing'

NETPILOT_LANG=zh
bench_usage > "$TMP/zh-help"
grep -q '测速用法' "$TMP/zh-help" || fail 'Chinese benchmark help regressed'
bench_summary "$TMP/before.json" > "$TMP/zh-summary"
grep -q '重传=' "$TMP/zh-summary" || fail 'Chinese benchmark summary regressed'
bench_compare "$TMP/before.json" "$TMP/after.json" > "$TMP/zh-compare"
grep -q '变化' "$TMP/zh-compare" || fail 'Chinese comparison regressed'

for dep in iperf3 python3 timeout ss; do command -v "$dep" >/dev/null || fail "missing live test dependency: $dep"; done
port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
iperf3 -s -B 127.0.0.1 -p "$port" > "$TMP/server.log" 2>&1 &
server_pid=$!
for attempt in {1..50}; do
  if ss -H -ltn "sport = :$port" | grep -q .; then break; fi
  kill -0 "$server_pid" 2>/dev/null || { cat "$TMP/server.log"; fail 'loopback server exited'; }
  sleep 0.05
done
ss -H -ltn "sport = :$port" | grep -q . || fail 'loopback server did not listen'
for language in en zh; do
  NETPILOT_LANG="$language"
  bench_command --peer 127.0.0.1 --port "$port" --direction send --streams 1 \
    --budget-mib 2 --timeout 5 --output "$TMP/live-$language.json" --yes > "$TMP/live-$language.log"
done
grep -q 'Benchmark peer:' "$TMP/live-en.log" || fail 'live benchmark ignored English language'
grep -q '测速对端：' "$TMP/live-zh.log" || fail 'live benchmark ignored Chinese language'
python3 - "$TMP" <<'PY'
import json, pathlib, stat, sys
root = pathlib.Path(sys.argv[1])
def shape(value):
    if isinstance(value, dict): return {key: shape(item) for key, item in value.items()}
    if isinstance(value, list): return [shape(item) for item in value]
    # JSON has one number category; real iperf3 can encode 0 and 0.0 differently.
    if type(value) in (int, float): return 'number'
    return type(value).__name__
reports = [json.loads((root / ('live-' + lang + '.json')).read_text()) for lang in ('en', 'zh')]
assert shape(reports[0]) == shape(reports[1]), 'language changed report schema'
for language, report in zip(('en', 'zh'), reports):
    assert report['schema_version'] == 1 and report['kind'] == 'netpilot-benchmark'
    assert report['direction'] == 'send' and report['runs'][0]['status'] == 'ok'
    assert report['runs'][0]['remote_endpoints'] == [{'address':'127.0.0.1','port':report['port']}]
    assert 0 < report['runs'][0]['bytes'] <= 2097152
    assert stat.S_IMODE((root / ('live-' + language + '.json')).stat().st_mode) == 0o600
for name in ('en-help', 'en-summary', 'en-compare', 'en-error', 'en-invalid', 'live-en.log'):
    text = (root / name).read_text()
    assert not any('\u3400' <= char <= '\u9fff' for char in text), name + ': untranslated Chinese output'
PY
printf '%s\n' 'PASS: bilingual benchmark help, validation, summaries, comparisons and real loopback schema stability'
