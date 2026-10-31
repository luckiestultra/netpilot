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
state = {'mode': 'ok', 'requests': [], 'node': 'LAB', 'accepted': 0}
lock = threading.Lock()

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, request, client_address):
        # Deliberate early aborts reject bad headers before reading the body.
        if not isinstance(sys.exc_info()[1], OSError):
            super().handle_error(request, client_address)

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def headers_for(self, length, uploaded=None):
        mode = state['mode']
        self.send_response(429 if mode == 'limited' else 403 if mode == 'forbidden' else 302 if mode == 'redirect' else 200)
        self.send_header('Content-Length', str(length))
        self.send_header('Content-Type', 'application/octet-stream')
        node = 'ALT' if mode == 'node-change' and len(state['requests']) > 1 else state['node']
        self.send_header('colo', node)
        self.send_header('CF-RAY', '0123456789abcdef-' + ('BAD' if mode == 'node-conflict' else node))
        if mode == 'encoded':
            self.send_header('Content-Encoding', 'gzip')
        if mode == 'redirect':
            self.send_header('Location', '/__down?bytes=1')
        if uploaded is not None:
            self.send_header('cf-meta-upload-bytes', str(uploaded + (1 if mode == 'bad-ack' else 0)))
        self.end_headers()
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
            if mode in ('limited', 'forbidden', 'redirect'):
                self.close_connection = True
                return
            remaining = max(0, size - 1) if mode == 'short-body' else length
            while remaining:
                chunk = b'x' * min(65536, remaining)
                self.wfile.write(chunk)
                remaining -= len(chunk)
            self.wfile.flush()
            if mode == 'short-body':
                self.close_connection = True
        except (OSError, BrokenPipeError):
            self.close_connection = True
    def do_POST(self):
        u = urlsplit(self.path)
        size = int(parse_qs(u.query).get('bytes', ['0'])[0])
        with lock:
            state['requests'].append(('POST', size, self.client_address[0]))
        remaining = int(self.headers.get('Content-Length', '0'))
        received = 0
        try:
            while remaining:
                chunk = self.rfile.read(min(65536, remaining))
                if not chunk:
                    break
                assert not chunk.strip(b'\0'), 'upload must contain synthetic zero bytes only'
                remaining -= len(chunk)
                received += len(chunk)
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
    state.update(mode=mode, requests=[], accepted=0, node='LAB')

def valid_report(report, phase, expected_endpoint=endpoint, expected_address='127.0.0.1'):
    assert report['type'] == 'netpilot-http-measurement' and report['version'] == 1 and report['ok'] is True
    assert report['phase'] == phase and report['endpoint'] == expected_endpoint
    assert report['address'] == expected_address and report['node'] == 'LAB'
    assert report['latency_method'] == 'tcp-connect-estimate'
    assert 0 < report['latency_ms'] <= 60000
    assert 0 < report['reserved_bytes'] <= report['budget_bytes'] == budget
    for direction in ('download', 'upload'):
        item = report[direction]
        assert item['payload_bytes'] == sum(item['request_sizes']) > 0
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
    assert sum(size for method, size, _ in state['requests']) <= budget
    assert state['accepted'] == before['upload']['payload_bytes']
    schedule = {d: before[d]['request_sizes'] for d in ('download', 'upload')}
    before_request_log = [(method, size) for method, size, _ in state['requests']]
    reset()
    result, after, after_path = run('after', 'after', before_path)
    assert result.returncode == 0, result.stderr.decode()
    valid_report(after, 'after')
    assert {d: after[d]['request_sizes'] for d in schedule} == schedule
    assert [(method, size) for method, size, _ in state['requests']] == before_request_log
    assert before['node'] == after['node'] and before['address'] == after['address']
    print('PASS: real HTTP bidirectional probes, exact phase budget, pinned peer and matched before/after schedules')

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

    reset()
    small_budget = budget
    budget = 80 * 1048576
    result, capped, _ = run('capped-chunks')
    assert result.returncode == 0, result.stderr.decode()
    valid_report(capped, 'before')
    assert max(size for _, size, _ in state['requests']) <= 16 * 1048576
    assert sum(size for _, size, _ in state['requests']) <= budget
    budget = small_budget
    print('PASS: large phase budgets retain a 16 MiB per-request ceiling')

    data = after_path.read_bytes()
    reset()
    result, _, _ = run('after', 'after', before_path)
    assert result.returncode != 0 and after_path.read_bytes() == data and not state['requests']
    print('PASS: HTTP reports are private and existing output files are never overwritten')

    for mode in ('limited', 'forbidden', 'redirect', 'encoded', 'long-length', 'short-body', 'bad-ack', 'node-change', 'node-conflict'):
        reset(mode)
        result, report, _ = run('failure-' + mode)
        assert result.returncode != 0, mode
        assert report is not None and report['ok'] is False and report['error'], (mode, report)
        assert 0 <= report['reserved_bytes'] <= budget
        if mode in ('limited', 'forbidden', 'redirect', 'encoded', 'long-length', 'node-conflict'):
            assert len(state['requests']) == 1, (mode, state['requests'])
        assert sum(size for _, size, _ in state['requests']) <= budget
    print('PASS: HTTP status, redirects, encoding, length, acknowledgement and node mismatches fail without retries')

    reset()
    tampered = dict(before)
    tampered['budget_bytes'] = budget + 1
    invalid_path = root / 'tampered.json'
    invalid_path.write_text(json.dumps(tampered))
    result, report, _ = run('invalid-before', 'after', invalid_path)
    assert result.returncode != 0 and not state['requests']
    reset()
    state['node'] = 'ALT'
    result, report, _ = run('changed-after', 'after', before_path)
    assert result.returncode != 0 and report['ok'] is False
    print('PASS: invalid prior reports and changed after-test nodes cannot produce a comparison')

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
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
    print('PASS: SIGINT cancels the HTTP measurement without surviving child processes')

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
