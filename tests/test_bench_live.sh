#!/usr/bin/env bash
# Run only against a real loopback iperf3 server; no external network is used.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_OVERRIDE:-$ROOT/vps-tcp-full-tune.sh}"
TEST_DIR="$(mktemp -d)"
server_pid=''
cleanup() {
  if [[ -n "$server_pid" ]]; then kill -TERM "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT
for dep in iperf3 python3 ping timeout ss; do command -v "$dep" >/dev/null || { printf 'FAIL: live test needs %s\n' "$dep" >&2; exit 1; }; done
PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1',0)); print(sock.getsockname()[1])
PY
)"
iperf3 -s -B 127.0.0.1 -p "$PORT" > "$TEST_DIR/server.log" 2>&1 &
server_pid=$!
for attempt in {1..50}; do
  if ss -H -ltn "sport = :$PORT" | grep -q .; then break; fi
  kill -0 "$server_pid" 2>/dev/null || { cat "$TEST_DIR/server.log"; exit 1; }
  sleep 0.05
done
ss -H -ltn "sport = :$PORT" | grep -q . || { printf 'FAIL: loopback server did not listen\n' >&2; exit 1; }

run_case() {
  local name="$1" direction="$2" streams="$3" budget="$4"
  shift 4
  if ! bash "$SCRIPT" bench --peer 127.0.0.1 --port "$PORT" --direction "$direction" \
    --streams "$streams" --budget-mib "$budget" --timeout 10 --output "$TEST_DIR/$name.json" --yes "$@" > "$TEST_DIR/$name.log" 2>&1; then
    cat "$TEST_DIR/$name.log"; return 1
  fi
  python3 - "$TEST_DIR/$name.json" "$direction" "$streams" "$budget" <<'PY'
import json,os,stat,sys
path,direction,streams,budget=sys.argv[1:]
report=json.load(open(path)); runs=report['runs']
expected=['send','receive'] if direction=='both' else [direction]
assert [r['direction'] for r in runs]==expected, runs
assert all(r['status']=='ok' for r in runs), runs
assert report['streams']==int(streams)
transferred=sum(r['bytes'] for r in runs)
assert 0 < transferred <= int(budget)*1048576, (transferred,budget,runs)
assert stat.S_IMODE(os.stat(path).st_mode)==0o600
assert all(r['mbps']>0 and r['seconds']>=0 for r in runs)
assert all(r['sample_quality']=='short_sample' for r in runs if r['seconds']<3)
if report['latency_enabled']:
    assert report['idle_latency']['status']=='ok', report['idle_latency']
    for r in runs:
        loaded=r['loaded_latency']
        if loaded['samples']<3:
            assert loaded['status']=='unavailable_or_insufficient' and loaded['p95_delta_ms'] is None, loaded
print('PASS: real loopback %s / %s streams, payload=%s <= %s bytes, private report' % (direction,streams,transferred,int(budget)*1048576))
PY
}

run_case send send 1 4
run_case receive receive 1 4
run_case parallel both 4 16
run_case latency both 1 8 --latency
run_case repeat send 1 4
bash "$SCRIPT" compare "$TEST_DIR/send.json" "$TEST_DIR/repeat.json" > "$TEST_DIR/compare.log"
grep -q 'send:' "$TEST_DIR/compare.log"
grep -q '不能' "$TEST_DIR/compare.log"
printf 'PASS: real loopback same-condition comparison and short latency samples\n'
