#!/usr/bin/env bash
# Real local HTTP transfers; no public endpoint is contacted by this test.
set -Eeuo pipefail
[[ $(uname -s) == Linux && ${BASH_VERSINFO[0]} -ge 4 ]] || { printf 'Tests require Linux and Bash 4+.\n' >&2; exit 2; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_OVERRIDE:-$ROOT/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
for dep in python3 timeout; do command -v "$dep" >/dev/null || { printf 'FAIL: HTTP measurement test needs %s\n' "$dep" >&2; exit 1; }; done
if [[ -n "${HTTP_MEASUREMENT_FRAGMENT:-}" ]]; then
  cp -- "$HTTP_MEASUREMENT_FRAGMENT" "$TMP/functions.sh"
else
  sed -n '/^# BEGIN HTTP MEASUREMENT$/,/^# END HTTP MEASUREMENT$/p' "$SCRIPT" > "$TMP/functions.sh"
fi
if [[ ! -s "$TMP/functions.sh" ]]; then printf 'FAIL: HTTP measurement backend is missing\n' >&2; exit 1; fi
# shellcheck source=/dev/null
source "$TMP/functions.sh"
declare -F http_measure_path >/dev/null || { printf 'FAIL: http_measure_path is missing\n' >&2; exit 1; }
export NETPILOT_HTTP_TEST_FRAGMENT="$TMP/functions.sh" NETPILOT_HTTP_TEST_TMP="$TMP"
python3 - <<'PY'
import collections
import copy
import http.server
import json
import math
import os
import pathlib
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit

root = pathlib.Path(os.environ['NETPILOT_HTTP_TEST_TMP'])
fragment = os.environ['NETPILOT_HTTP_TEST_FRAGMENT']
state = {'mode': 'ok', 'requests': [], 'node': 'LAB', 'accepted': 0, 'generation': 0,
         'active': 0, 'max_active': 0, 'spans': [], 'barrier': None, 'upload_read': 0}
lock = threading.Lock()

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, request, client_address):
        # Deliberate early aborts reject bad headers before reading the body.
        if not isinstance(sys.exc_info()[1], OSError):
            super().handle_error(request, client_address)

def tracked(method):
    def request(self):
        with lock:
            generation, mode, barrier = state['generation'], state['mode'], state['barrier']
            state['active'] += 1
            state['max_active'] = max(state['max_active'], state['active'])
        size = int(parse_qs(urlsplit(self.path).query).get('bytes', ['0'])[0])
        begin = time.monotonic()
        try:
            if mode == 'parallel-delay' and size != 65536:
                # Exactly four requests must reach the server together. A
                # serial collector cannot pass this rendezvous.
                barrier.wait(timeout=2)
                time.sleep(.3)
            elif mode == 'auto-delay':
                # Real requests spend time on a controlled peer; the collector
                # must keep sampling past the former 32 MiB direction budget.
                time.sleep(.5)
            return method(self)
        finally:
            with lock:
                if state['generation'] == generation:
                    state['active'] -= 1
                    state['spans'].append((method.__name__, size, begin, time.monotonic()))
    return request

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def headers_for(self, length, uploaded=None):
        mode = state['mode']
        size = length if uploaded is None else uploaded
        forbidden = (mode == 'forbidden' or mode == 'forbidden-upload' and uploaded is not None or
                     mode == 'max-4mib' and size > 4 * 1048576)
        self.send_response(429 if mode == 'limited' else 403 if forbidden else 302 if mode == 'redirect' else 200)
        self.send_header('Content-Length', str(length))
        self.send_header('Content-Type', 'application/octet-stream')
        node = 'ALT' if mode == 'node-change' and size != 65536 else state['node']
        self.send_header('colo', node)
        self.send_header('CF-RAY', '0123456789abcdef-' + ('BAD' if mode == 'node-conflict' else node))
        if mode == 'encoded':
            self.send_header('Content-Encoding', 'gzip')
        if mode == 'redirect':
            self.send_header('Location', '/__down?bytes=1')
        if uploaded is not None:
            self.send_header('cf-meta-upload-bytes', str(uploaded + (1 if mode == 'bad-ack' else 0)))
        self.end_headers()
    @tracked
    def do_GET(self):
        u = urlsplit(self.path)
        size = int(parse_qs(u.query).get('bytes', ['0'])[0])
        with lock:
            state['requests'].append(('GET', size, self.client_address[0]))
        if state['mode'] == 'stall':
            time.sleep(5)
        mode = state['mode']
        length = size + 1 if mode == 'long-length' else size
        try:
            self.headers_for(length)
            if mode in ('limited', 'forbidden', 'redirect') or mode == 'max-4mib' and size > 4 * 1048576:
                self.close_connection = True
                return
            remaining = max(0, size - 1) if mode == 'short-body' else length
            while remaining:
                chunk = b'x' * min(16384 if mode == 'slow-pilot' else 65536, remaining)
                if mode == 'slow-pilot':
                    time.sleep(.8)
                self.wfile.write(chunk)
                remaining -= len(chunk)
            self.wfile.flush()
            if mode == 'short-body':
                self.close_connection = True
        except (OSError, BrokenPipeError):
            self.close_connection = True
    @tracked
    def do_POST(self):
        u = urlsplit(self.path)
        size = int(parse_qs(u.query).get('bytes', ['0'])[0])
        with lock:
            state['requests'].append(('POST', size, self.client_address[0]))
        remaining = int(self.headers.get('Content-Length', '0'))
        received = 0
        try:
            while remaining:
                chunk = self.rfile.read(min(16384 if state['mode'] in ('slow-upload', 'slow-pilot') else 65536, remaining))
                if not chunk:
                    break
                assert not chunk.strip(b'\0'), 'upload must contain synthetic zero bytes only'
                remaining -= len(chunk)
                received += len(chunk)
                if state['mode'] == 'slow-upload':
                    with lock:
                        state['upload_read'] += len(chunk)
                    time.sleep(.02)
                elif state['mode'] == 'slow-pilot':
                    time.sleep(.8)
            with lock:
                state['accepted'] += received
            self.headers_for(0, received)
        except (OSError, BrokenPipeError):
            self.close_connection = True

server = Server(('127.0.0.1', 0), Handler)
server6 = None
threading.Thread(target=server.serve_forever, daemon=True).start()
endpoint = 'http://127.0.0.1:%d' % server.server_address[1]
budget = 1048576

def run(name, phase='before', previous='', limit=10, endpoint_override=None, extra_env=None):
    output = root / (name + '.json')
    env = dict(os.environ, NETPILOT_LANG='en', HTTP_PROXY='http://127.0.0.1:1', HTTPS_PROXY='http://127.0.0.1:1', ALL_PROXY='http://127.0.0.1:1')
    if extra_env:
        env.update(extra_env)
    args = ['bash', '-c', 'source "$1"; http_measure_path "${@:2}"', '_', fragment, phase,
            endpoint_override or endpoint, str(budget), str(limit), str(output), str(previous)]
    result = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=limit + 4)
    report = json.loads(output.read_text()) if output.exists() else None
    return result, report, output

def reset(mode='ok'):
    state.update(mode=mode, requests=[], accepted=0, node='LAB', generation=state['generation'] + 1,
                 active=0, max_active=0, spans=[], upload_read=0,
                 barrier=threading.Barrier(4) if mode == 'parallel-delay' else None)

def valid_report(report, phase, expected_endpoint=endpoint, expected_address='127.0.0.1'):
    assert report['type'] == 'netpilot-http-measurement' and report['version'] == 1 and report['ok'] is True
    assert report['phase'] == phase and report['endpoint'] == expected_endpoint
    assert report['address'] == expected_address and report['node'] == 'LAB'
    assert report['latency_method'] == 'tcp-connect-estimate'
    assert report['measurement_policy'] == 'parallel-http-v1'
    assert report['connection_policy'] == 'pinned-parallel' and report['parallelism'] == 4
    assert report['budget_mode'] == ('auto' if budget == 8 * 1024**3 else 'fixed')
    assert 0 < report['latency_ms'] <= 60000
    assert 0 < report['reserved_bytes'] <= report['budget_bytes'] == budget
    for direction in ('download', 'upload'):
        item = report[direction]
        assert item['payload_bytes'] == sum(item['request_sizes']) > 0
        batches = item['request_batches']
        assert batches and all(1 <= len(batch) <= 4 for batch in batches)
        assert [size for batch in batches for size in batch] == item['request_sizes']
        assert math.isfinite(item['bits_per_second']) and item['bits_per_second'] > 0
        assert item['quality'] in ('sampled', 'budget-limited')
        assert item['duration_seconds'] > 0
        assert math.isclose(item['bits_per_second'], item['payload_bytes'] * 8 / item['duration_seconds'], rel_tol=1e-8)
    assert report['reserved_bytes'] == report['download']['payload_bytes'] + report['upload']['payload_bytes']

try:
    reset()
    result, before, before_path = run('before')
    assert result.returncode == 0, result.stderr.decode()
    valid_report(before, 'before')
    assert stat.S_IMODE(before_path.stat().st_mode) == 0o600
    assert before['download']['quality'] == 'budget-limited'
    assert before['upload']['quality'] == 'budget-limited' and before['reserved_bytes'] == budget
    assert sum(size for method, size, _ in state['requests']) <= budget
    assert state['accepted'] == before['upload']['payload_bytes']
    schedule = {d: before[d]['request_sizes'] for d in ('download', 'upload')}
    before_request_log = [(method, size) for method, size, _ in state['requests']]
    reset()
    result, after, after_path = run('after', 'after', before_path)
    assert result.returncode == 0, result.stderr.decode()
    valid_report(after, 'after')
    assert {d: after[d]['request_sizes'] for d in schedule} == schedule
    assert collections.Counter((method, size) for method, size, _ in state['requests']) == collections.Counter(before_request_log)
    assert {d: after[d]['request_batches'] for d in schedule} == {d: before[d]['request_batches'] for d in schedule}
    assert before['node'] == after['node'] and before['address'] == after['address']
    print('PASS: real HTTP bidirectional probes, exact phase budget, pinned peer and matched before/after schedules')

    reset('slow-pilot')
    original_budget = budget
    budget = 64 * 1048576
    result, slow, _ = run('slow-pilot-before', limit=12)
    assert result.returncode == 0, result.stderr.decode()
    valid_report(slow, 'before')
    assert [(method, size) for method, size, _ in state['requests']] == [('GET', 65536), ('POST', 65536)], state['requests']
    assert state['max_active'] == 1 and slow['reserved_bytes'] == 131072
    for direction in ('download', 'upload'):
        item = slow[direction]
        assert item['request_batches'] == [[65536]] and item['request_sizes'] == [65536]
        assert 3 <= item['duration_seconds'] < 6 and item['quality'] == 'sampled', item
    budget = original_budget
    print('PASS: real slow transfers stop after a 64 KiB pilot per direction without launching larger requests')

    reset('parallel-delay')
    original_budget = budget
    budget = 2228224
    started = time.monotonic()
    result, parallel, parallel_path = run('parallel-before')
    elapsed = time.monotonic() - started
    assert result.returncode == 0, result.stderr.decode()
    valid_report(parallel, 'before')
    assert 2 <= state['max_active'] <= 4, state['max_active']
    for direction, method in (('download', 'do_GET'), ('upload', 'do_POST')):
        item = parallel[direction]
        assert item['request_batches'] == [[65536], [262144] * 4], item
        all_spans = [(size, end - begin) for name, size, begin, end in state['spans'] if name == method]
        spans = [duration for size, duration in all_spans if size != 65536]
        assert len(all_spans) == 5 and len(spans) == 4 and min(spans) >= .29, all_spans
        # The denominator is aggregate wall time, never summed worker time.
        assert .29 <= item['duration_seconds'] < sum(spans) * .7, (item, spans, elapsed)
        assert item['duration_seconds'] <= elapsed
    parallel_requests = collections.Counter((method, size) for method, size, _ in state['requests'])
    parallel_batches = {d: parallel[d]['request_batches'] for d in ('download', 'upload')}
    reset('parallel-delay')
    result, parallel_after, _ = run('parallel-after', 'after', parallel_path)
    assert result.returncode == 0, result.stderr.decode()
    valid_report(parallel_after, 'after')
    assert collections.Counter((method, size) for method, size, _ in state['requests']) == parallel_requests
    assert {d: parallel_after[d]['request_batches'] for d in ('download', 'upload')} == parallel_batches
    assert 2 <= state['max_active'] <= 4
    budget = original_budget
    print('PASS: real simultaneous requests are capped at four, use aggregate wall time and replay identical batches')

    ipv6_info = pathlib.Path('/proc/net/if_inet6')
    ipv6_loopback = ipv6_info.exists() and any(line.split()[0] == '0' * 31 + '1' and line.split()[-1] == 'lo' for line in ipv6_info.read_text().splitlines())
    if ipv6_loopback:
        class Server6(Server):
            address_family = socket.AF_INET6
        server6 = Server6(('::1', 0), Handler)
        threading.Thread(target=server6.serve_forever, daemon=True).start()
        endpoint6 = 'http://[::1]:%d' % server6.server_address[1]
        reset()
        result, ipv6, _ = run('ipv6', endpoint_override=endpoint6)
        assert result.returncode == 0, result.stderr.decode()
        valid_report(ipv6, 'before', endpoint6, '::1')
        assert ipv6['family'] == 'IPv6'
        print('PASS: real IPv6 HTTP uploads and downloads use a pinned loopback address')
    else:
        print('SKIP: IPv6 loopback is not configured in this container')

    reset('max-4mib')
    small_budget = budget
    budget = 64 * 1048576  # An explicit 128 MiB run allocates 64 MiB to each phase.
    result, capped, capped_path = run('default-phase-before')
    assert result.returncode == 0, (result.stderr.decode(), state['requests'])
    valid_report(capped, 'before')
    assert 1 <= state['max_active'] <= 4, state['max_active']
    assert capped['provider'] == 'custom'
    assert max(size for _, size, _ in state['requests']) == 4 * 1048576
    assert sum(size for _, size, _ in state['requests']) <= budget
    capped_requests = [(method, size) for method, size, _ in state['requests']]
    for direction in ('download', 'upload'):
        assert 4 * 1048576 in capped[direction]['request_sizes']
        assert all(size <= 4 * 1048576 for size in capped[direction]['request_sizes'])
    reset('max-4mib')
    result, capped_after, _ = run('default-phase-after', 'after', capped_path)
    assert result.returncode == 0, result.stderr.decode()
    valid_report(capped_after, 'after')
    assert 1 <= state['max_active'] <= 4, state['max_active']
    assert capped_after['budget_bytes'] == capped['budget_bytes'] == budget
    assert capped_after['reserved_bytes'] == capped['reserved_bytes']
    assert collections.Counter((method, size) for method, size, _ in state['requests']) == collections.Counter(capped_requests)
    for direction in ('download', 'upload'):
        assert capped_after[direction]['request_sizes'] == capped[direction]['request_sizes']
        assert capped_after[direction]['request_batches'] == capped[direction]['request_batches']
    budget = small_budget
    print('PASS: fixed 64 MiB phases succeed against a real 4 MiB request limit with identical bidirectional schedules')

    reset('auto-delay')
    budget = 8 * 1024**3
    result, automatic, automatic_path = run('automatic-before', limit=15)
    assert result.returncode == 0, result.stderr.decode()
    valid_report(automatic, 'before')
    automatic_requests = collections.Counter((method, size) for method, size, _ in state['requests'])
    for direction in ('download', 'upload'):
        item = automatic[direction]
        assert item['payload_bytes'] > 32 * 1048576, item
        assert 3 <= item['duration_seconds'] < 7 and item['quality'] == 'sampled', item
        assert item['request_sizes'].count(65536) == 1, 'automatic sampling restarted its pilot'
        assert item['request_batches'][0] == [65536]
    assert automatic['reserved_bytes'] < budget // 8
    assert 2 <= state['max_active'] <= 4
    reset('auto-delay')
    result, automatic_after, _ = run('automatic-after', 'after', automatic_path, limit=15)
    assert result.returncode == 0, result.stderr.decode()
    valid_report(automatic_after, 'after')
    for direction in ('download', 'upload'):
        assert automatic_after[direction]['request_batches'] == automatic[direction]['request_batches']
    assert collections.Counter((method, size) for method, size, _ in state['requests']) == automatic_requests
    assert automatic_after['reserved_bytes'] == automatic['reserved_bytes']
    assert 128 * 1048576 < automatic['reserved_bytes'] + automatic_after['reserved_bytes'] < 16 * 1024**3
    budget = small_budget
    print('PASS: automatic sampling continues online past former limits, stops by duration and replays without restarting or consuming its full cap')

    # Validate a maximum-budget baseline without transferring a GiB: the local
    # server denies the first accepted request, after baseline validation.
    budget = 512 * 1048576
    maximum = copy.deepcopy(before)
    maximum['budget_bytes'] = maximum['reserved_bytes'] = budget
    for direction in ('download', 'upload'):
        item = maximum[direction]
        item.update(request_sizes=[2 * 1048576] * 128, request_batches=[[2 * 1048576] * 4 for _ in range(32)], payload_bytes=budget // 2,
                    duration_seconds=2.0, bits_per_second=budget * 2, quality='budget-limited')
        maximum[direction + '_bps'] = item['bits_per_second']
    maximum_path = root / 'maximum-baseline.json'
    maximum_path.write_text(json.dumps(maximum))
    reset('forbidden')
    result, denied, _ = run('maximum-baseline-after', 'after', maximum_path)
    assert result.returncode != 0 and denied['ok'] is False
    assert 1 <= len(state['requests']) <= 4, state['requests']
    assert all(method == 'GET' and size == 2 * 1048576 for method, size, _ in state['requests'])
    assert denied['reserved_bytes'] == 8 * 1048576
    assert denied['download']['request_sizes'] == [2 * 1048576] * 4
    assert denied['http_error']['status'] == 403 and denied['http_error']['direction'] == 'download'
    expanded_fixed = copy.deepcopy(maximum)
    for direction in ('download', 'upload'):
        expanded_fixed[direction]['request_sizes'] = [2 * 1048576] * 127 + [1048576, 1048576]
        expanded_fixed[direction]['request_batches'] = [expanded_fixed[direction]['request_sizes'][i:i+4] for i in range(0, 129, 4)]
    expanded_fixed_path = root / 'expanded-fixed-baseline.json'
    expanded_fixed_path.write_text(json.dumps(expanded_fixed))
    reset('forbidden')
    result, expanded_denied, _ = run('expanded-fixed-baseline-after', 'after', expanded_fixed_path)
    assert result.returncode != 0 and expanded_denied['http_error']['status'] == 403 and state['requests']
    print('PASS: fixed-budget baseline reader retains 128 records and accepts expanded 129-record plans without transferring their payload')

    budget = 8 * 1024**3
    maximum_auto = copy.deepcopy(before)
    maximum_auto.update(budget_mode='auto', budget_bytes=budget, reserved_bytes=budget)
    for direction in ('download', 'upload'):
        item = maximum_auto[direction]
        item.update(request_sizes=[2 * 1048576] * 2048,
                    request_batches=[[2 * 1048576] * 4 for _ in range(512)], payload_bytes=budget // 2,
                    duration_seconds=2.0, bits_per_second=budget * 2, quality='budget-limited')
        maximum_auto[direction + '_bps'] = item['bits_per_second']
    maximum_auto_path = root / 'maximum-auto-baseline.json'
    maximum_auto_path.write_text(json.dumps(maximum_auto))
    reset('forbidden')
    result, auto_denied, _ = run('maximum-auto-baseline-after', 'after', maximum_auto_path)
    assert result.returncode != 0 and auto_denied['ok'] is False and state['requests']
    assert auto_denied['http_error']['status'] == 403 and auto_denied['reserved_bytes'] == 8 * 1048576
    assert all(method == 'GET' and size == 2 * 1048576 for method, size, _ in state['requests'])
    too_many = copy.deepcopy(maximum_auto)
    for direction in ('download', 'upload'):
        too_many[direction]['request_sizes'] = [2 * 1048576] * 2047 + [1048576, 1048576]
        too_many[direction]['request_batches'] = [too_many[direction]['request_sizes'][i:i+4] for i in range(0, 2049, 4)]
    too_many_path = root / 'too-many-baseline.json'
    too_many_path.write_text(json.dumps(too_many))
    reset('forbidden')
    result, invalid, _ = run('too-many-baseline-after', 'after', too_many_path)
    assert result.returncode != 0 and invalid['ok'] is False and not state['requests']
    budget = small_budget
    print('PASS: automatic maximum-budget baseline accepts 2048 requests per direction and rejects 2049 before any HTTP traffic')

    data = after_path.read_bytes()
    reset()
    result, _, _ = run('after', 'after', before_path)
    assert result.returncode != 0 and after_path.read_bytes() == data and not state['requests']
    print('PASS: HTTP reports are private and existing output files are never overwritten')

    for mode in ('limited', 'forbidden', 'forbidden-upload', 'redirect', 'encoded', 'long-length', 'short-body', 'bad-ack', 'node-change', 'node-conflict'):
        reset(mode)
        result, report, _ = run('failure-' + mode)
        assert result.returncode != 0, mode
        assert report is not None and report['ok'] is False and report['error'], (mode, report)
        assert 0 <= report['reserved_bytes'] <= budget
        if mode in ('limited', 'forbidden', 'redirect', 'encoded', 'long-length', 'node-conflict'):
            assert 1 <= len(state['requests']) <= 4, (mode, state['requests'])
            assert len(report['download']['request_batches']) == 1, (mode, report)
        assert sum(size for _, size, _ in state['requests']) <= budget
        if mode in ('forbidden', 'forbidden-upload'):
            direction = 'download' if mode == 'forbidden' else 'upload'
            method = 'GET' if direction == 'download' else 'POST'
            attempted = [size for requested_method, size, _ in state['requests'] if requested_method == method]
            assert 1 <= len(attempted) <= 4, (mode, state['requests'])
            assert len(report[direction]['request_batches']) == 1, (mode, report)
            assert report['http_error']['status'] == 403
            assert report['http_error']['direction'] == direction
            assert report['http_error']['request_bytes'] in report[direction]['request_batches'][0]
            assert report['http_error']['reserved_bytes'] == report['reserved_bytes']
            assert report['reserved_bytes'] >= sum(size for _, size, _ in state['requests'])
            assert report['reserved_bytes'] == sum(sum(report[d]['request_sizes']) for d in ('download', 'upload'))
    print('PASS: HTTP status, redirects, encoding, length, acknowledgement and node mismatches fail without retries')

    reset()
    tampered = dict(before)
    tampered['budget_bytes'] = budget + 1
    invalid_path = root / 'tampered.json'
    invalid_path.write_text(json.dumps(tampered))
    result, report, _ = run('invalid-before', 'after', invalid_path)
    assert result.returncode != 0 and not state['requests']
    for kind in ('legacy', 'parallelism', 'batch-flatten', 'batch-numeric-type', 'wide-batch'):
        reset()
        incompatible = copy.deepcopy(before)
        if kind == 'legacy':
            incompatible.pop('measurement_policy')
            incompatible.pop('parallelism')
            incompatible['connection_policy'] = 'pinned-preconnected'
            for direction in ('download', 'upload'):
                incompatible[direction].pop('request_batches')
        elif kind == 'parallelism':
            incompatible['parallelism'] = 5
        elif kind == 'batch-flatten':
            incompatible['download']['request_batches'][0][0] += 1
        elif kind == 'batch-numeric-type':
            incompatible['download']['request_batches'][0][0] = float(incompatible['download']['request_batches'][0][0])
        else:
            incompatible['download']['request_batches'] = [[1] * 5]
        incompatible_path = root / ('incompatible-' + kind + '.json')
        incompatible_path.write_text(json.dumps(incompatible))
        result, rejected, _ = run('rejected-' + kind, 'after', incompatible_path)
        assert result.returncode != 0 and rejected['ok'] is False and not state['requests'], kind
    reset()
    state['node'] = 'ALT'
    result, report, _ = run('changed-after', 'after', before_path)
    assert result.returncode != 0 and report['ok'] is False
    print('PASS: malformed or legacy runtime policies, invalid batches and changed after-test nodes fail without a comparison')

    reset('stall')
    started = time.monotonic()
    result, report, _ = run('timeout', limit=1)
    assert result.returncode != 0 and time.monotonic() - started < 3.5
    assert report is None or report['ok'] is False
    print('PASS: a real stalled HTTP request is bounded by the global timeout')

    reset('stall')
    output = root / 'cancel.json'
    command = ['bash', '-c', 'source "$1"; http_measure_path before "$2" 1048576 10 "$3"', '_', fragment, endpoint, str(output)]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        for _ in range(100):
            if state['requests'] or process.poll() is not None:
                break
            time.sleep(.02)
        assert process.poll() is None, process.communicate()
        os.killpg(process.pid, signal.SIGINT)
        process.communicate(timeout=3)
        assert process.returncode != 0
        time.sleep(.05)
        children = subprocess.check_output(['ps', '-eo', 'pid=,pgid=,stat='], text=True)
        alive = [line for line in children.splitlines() if len(line.split()) == 3 and int(line.split()[1]) == process.pid and not line.split()[2].startswith('Z')]
        assert not alive, alive
        requests_after_exit = list(state['requests'])
        time.sleep(.15)
        assert state['requests'] == requests_after_exit, 'measurement continued sending after cancellation'
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
    print('PASS: SIGINT cancels the HTTP measurement without surviving child processes')

    reset('slow-upload')
    output = root / 'cancel-upload.json'
    command = ['bash', '-c', 'source "$1"; http_measure_path before "$2" 67108864 10 "$3"', '_', fragment, endpoint, str(output)]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        for _ in range(150):
            if (any(method == 'POST' and size == 4 * 1048576 for method, size, _ in state['requests']) or
                    process.poll() is not None):
                break
            time.sleep(.02)
        assert process.poll() is None and any(method == 'POST' and size == 4 * 1048576 for method, size, _ in state['requests']), process.communicate() if process.poll() is not None else state
        os.killpg(process.pid, signal.SIGINT)
        process.communicate(timeout=3)
        assert process.returncode != 0
        children = subprocess.check_output(['ps', '-eo', 'pid=,pgid=,stat='], text=True)
        alive = [line for line in children.splitlines() if len(line.split()) == 3 and int(line.split()[1]) == process.pid and not line.split()[2].startswith('Z')]
        assert not alive, alive
        requests_after_exit = list(state['requests'])
        time.sleep(.15)
        assert state['requests'] == requests_after_exit, 'new HTTP requests started after upload cancellation'
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
    print('PASS: cancellation during real upload closes worker processes and starts no further HTTP requests')

    reset()
    result, report, _ = run('insecure-remote', endpoint_override='http://example.com')
    assert result.returncode != 0 and not state['requests']
    site = root / 'dns'; site.mkdir()
    (site / 'sitecustomize.py').write_text('import socket\nsocket.getaddrinfo=lambda *a,**kw:[(socket.AF_INET,socket.SOCK_STREAM,6,"",("198.18.0.1",443))]\n')
    result, report, _ = run('mapped-default', endpoint_override='https://speed.cloudflare.com', extra_env={'PYTHONPATH': str(site)})
    assert result.returncode != 0 and report and report['ok'] is False
    assert 'proxy-mapped' in report['error'], report
    assert not state['requests']
    print('PASS: remote plaintext and mapped/private Cloudflare DNS addresses are rejected')
finally:
    if server6 is not None:
        server6.shutdown()
        server6.server_close()
    server.shutdown()
    server.server_close()
PY
