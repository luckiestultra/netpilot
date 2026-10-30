#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FRAGMENT="${BENCH_FUNCTIONS_OVERRIDE:-$ROOT/netpilot.sh}"
source "$FRAGMENT"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir "$TEST_DIR/bin"
export TEST_DIR
cat > "$TEST_DIR/bin/iperf3" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_DIR/calls"
if [[ "${FAIL_IPERF:-0}" == 1 ]]; then printf 'peer busy\n' >&2; exit 1; fi
if [[ "${WAIT_IPERF:-0}" == 1 ]]; then printf '%s\n' "$$" > "$TEST_DIR/iperf-pid"; exec python3 -c 'import time; time.sleep(120)'; fi
if [[ "${INVALID_IPERF:-0}" == 1 ]]; then printf '{}\n'; exit 0; fi
cat <<'JSON'
{"start":{"version":"iperf 3.test"},"end":{"sum_sent":{"bytes":524288,"bits_per_second":1048576,"seconds":4,"retransmits":3},"sum_received":{"bytes":524288,"bits_per_second":1000000,"seconds":4},"cpu_utilization_percent":{"host_total":12,"remote_total":20},"streams":[{"sender":{"mean_rtt":10000}}]}}
JSON
MOCK
cat > "$TEST_DIR/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
[[ "${TIMEOUT_IPERF:-0}" != 1 ]] || exit 124
while [[ "$1" == --* ]]; do shift; done
shift
exec "$@"
MOCK
cat > "$TEST_DIR/bin/ping" <<'MOCK'
#!/usr/bin/env bash
value=20
[[ " $* " == *' -c '* ]] && value=5
for n in 1 2 3 4 5; do printf '64 bytes from 127.0.0.1: icmp_seq=%s ttl=64 time=%s ms\n' "$n" "$value"; done
MOCK
chmod +x "$TEST_DIR/bin/iperf3" "$TEST_DIR/bin/timeout" "$TEST_DIR/bin/ping"
export PATH="$TEST_DIR/bin:$PATH"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if bench_command --peer 'host;touch /tmp/unexpected' --yes >/dev/null 2>&1; then fail 'unsafe peer accepted'; fi
[[ ! -e "$TEST_DIR/calls" ]] || fail 'unsafe input invoked iperf3'
if bench_command --peer localhost --budget-mib 0 --yes >/dev/null 2>&1; then fail 'zero budget accepted'; fi
if bench_command --peer localhost --port 65536 --yes >/dev/null 2>&1; then fail 'invalid port accepted'; fi
if bench_command --peer localhost --streams 999 --yes >/dev/null 2>&1; then fail 'invalid streams accepted'; fi
if bench_command --peer localhost </dev/null >/dev/null 2>&1; then fail 'noninteractive test ran without consent'; fi
[[ ! -e "$TEST_DIR/calls" ]] || fail 'cancelled test invoked iperf3'

bench_command --peer ::1 --budget-mib 2 --streams 2 --direction both --output "$TEST_DIR/before.json" --yes > "$TEST_DIR/summary"
[[ "$(wc -l < "$TEST_DIR/calls" | tr -d ' ')" == 2 ]] || fail 'both directions were not tested'
grep -q -- '-n 786432' "$TEST_DIR/calls" || fail 'budget was not divided across directions with a per-stream final-block reserve'
grep -q -- '-R' "$TEST_DIR/calls" || fail 'receive test did not reverse direction'
python3 - "$TEST_DIR/before.json" <<'PY'
import json, os, stat, sys
report = json.load(open(sys.argv[1]))
assert report['schema_version'] == 1
assert report['budget_bytes'] == 2 * 1024 * 1024
assert report['peer'] == '::1'
assert len(report['runs']) == 2
assert all(x['status'] == 'ok' for x in report['runs'])
assert report['runs'][0]['retransmits'] == 3
assert report['runs'][0]['cpu_host_percent'] == 12
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
cp "$TEST_DIR/before.json" "$TEST_DIR/after.json"
bench_compare "$TEST_DIR/before.json" "$TEST_DIR/after.json" > "$TEST_DIR/compare"
grep -q '0.0%' "$TEST_DIR/compare" || fail 'comparison does not show unchanged measured throughput'
python3 - "$TEST_DIR" <<'PY'
import copy,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); valid=json.load(open(root/'before.json'))
variants={}
variants['empty-runs']=copy.deepcopy(valid); variants['empty-runs']['runs']=[]
variants['missing-metadata']=copy.deepcopy(valid); variants['missing-metadata'].pop('peer')
variants['illegal-schema']=copy.deepcopy(valid); variants['illegal-schema']['schema_version']=999
variants['boolean-schema']=copy.deepcopy(valid); variants['boolean-schema']['schema_version']=True
variants['top-level-list']=[valid]
variants['duplicate-direction']=copy.deepcopy(valid); variants['duplicate-direction']['runs'][1]['direction']='send'
variants['nan-throughput']=copy.deepcopy(valid); variants['nan-throughput']['runs'][0]['mbps']=float('nan')
variants['boolean-throughput']=copy.deepcopy(valid); variants['boolean-throughput']['runs'][0]['mbps']=True
variants['boolean-streams']=copy.deepcopy(valid); variants['boolean-streams']['streams']=True
for name,report in variants.items():
    (root/('invalid-'+name+'.json')).write_text(json.dumps(report))
PY
comparison_errors=0
for report in "$TEST_DIR"/invalid-*.json; do
  if bench_compare "$report" "$report" >/dev/null 2>&1; then
    printf 'FAIL: compare accepted %s\n' "${report##*/}" >&2
    comparison_errors=$((comparison_errors + 1))
  fi
done
(( comparison_errors == 0 )) || fail 'malformed reports must not compare as valid measurements'
python3 - "$TEST_DIR/after.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['peer']='other.example'; json.dump(d,open(p,'w'))
PY
if bench_compare "$TEST_DIR/before.json" "$TEST_DIR/after.json" >/dev/null 2>&1; then fail 'unmatched peers compared'; fi
if bench_command --peer localhost --output "$TEST_DIR/before.json" --yes >/dev/null 2>&1; then fail 'existing report overwritten'; fi
ln -s "$TEST_DIR/target" "$TEST_DIR/symlink.json"
if bench_command --peer localhost --output "$TEST_DIR/symlink.json" --yes >/dev/null 2>&1; then fail 'symlink report accepted'; fi

# Simulate a concurrent directory creation after output preflight but before publish.
race_output="$TEST_DIR/raced-output"
ln() {
  local destination="${@: -1}"
  [[ "$destination" != "$race_output" ]] || mkdir -p -- "$destination"
  command ln "$@"
}
if bench_command --peer localhost --output "$race_output" --yes >/dev/null 2>&1; then fail 'directory race was accepted'; fi
unset -f ln
[[ -z "$(ls -A "$race_output")" ]] || fail 'report was unexpectedly published inside a raced directory'

bench_command --peer localhost --budget-mib 2 --latency --output "$TEST_DIR/latency.json" --yes >/dev/null
python3 - "$TEST_DIR/latency.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['idle_latency']['p95_ms']==5
assert d['runs'][0]['loaded_latency']['p95_ms']==20
assert d['runs'][0]['loaded_latency']['p95_delta_ms']==15
PY

if FAIL_IPERF=1 bench_command --peer localhost --output "$TEST_DIR/failed.json" --yes >/dev/null 2>&1; then fail 'failed command reported success'; fi
python3 - "$TEST_DIR/failed.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['runs'][0]['status']=='failed'; assert 'peer busy' in d['runs'][0]['error']
PY
if INVALID_IPERF=1 bench_command --peer localhost --output "$TEST_DIR/invalid.json" --yes >/dev/null 2>&1; then fail 'invalid JSON totals reported success'; fi
if TIMEOUT_IPERF=1 bench_command --peer localhost --output "$TEST_DIR/timeout.json" --yes >/dev/null 2>&1; then fail 'timeout reported success'; fi
python3 - "$TEST_DIR/timeout.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['runs'][0]['status']=='failed'; assert d['runs'][0]['exit_code']==124
PY

WAIT_IPERF=1 bench_command --peer localhost --output "$TEST_DIR/cancel.json" --yes >/dev/null 2>&1 &
bench_job=$!
for attempt in {1..40}; do [[ ! -f "$TEST_DIR/iperf-pid" ]] || break; sleep 0.05; done
[[ -f "$TEST_DIR/iperf-pid" ]] || { kill -TERM "$bench_job" 2>/dev/null || true; fail 'cancellation fixture did not start'; }
iperf_pid="$(cat "$TEST_DIR/iperf-pid")"
kill -TERM "$bench_job"
if wait "$bench_job"; then fail 'cancelled benchmark reported success'; fi
if kill -0 "$iperf_pid" 2>/dev/null; then kill -TERM "$iperf_pid" 2>/dev/null || true; fail 'cancelled iperf3 child was left running'; fi
[[ ! -e "$TEST_DIR/cancel.json" ]] || fail 'cancelled benchmark published an incomplete successful report'
printf 'PASS: bounded benchmark validation, direction, reports, comparison, and failures\n'
