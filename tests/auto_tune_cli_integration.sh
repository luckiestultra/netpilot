#!/usr/bin/env bash
# Complete CLI and real file writes: only inside a disposable Docker container.
set -Eeuo pipefail
[[ -f /.dockerenv && "$EUID" == 0 ]] || { printf 'Run only as root in a disposable Docker container.\n' >&2; exit 2; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/netpilot.sh"
TMP="$(mktemp -d)"
server_pid=''
cleanup() {
  if [[ -n "$server_pid" ]]; then kill -TERM "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  command rm -rf -- "$TMP"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for dep in python3 timeout sha256sum diff; do command -v "$dep" >/dev/null || fail "missing dependency: $dep"; done
REPORT_ROOT=/tmp/netpilot-reports
for path in /var/lib/netpilot "$REPORT_ROOT" /etc/sysctl.d/99-netpilot.conf /etc/sysctl.d/10-netpilot-bbr.conf /etc/modules-load.d/netpilot.conf /usr/local/bin/netpilot.sh /usr/local/bin/netpilot; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "container is not clean: $path"
done
source_hash="$(sha256sum "$SCRIPT" | awk '{print $1}')"
# Reproduce the group-writable /var/log reported by a real VPS. Neither the
# default workflow nor its reader may require changes to this system directory.
chmod 0775 /var/log
log_identity="$(stat -c '%a:%u:%g' /var/log)"
mkdir -p /var/log/netpilot
printf 'preserve legacy reports\n' > /var/log/netpilot/legacy-report
legacy_hash="$(sha256sum /var/log/netpilot/legacy-report | awk '{print $1}')"
mkdir "$TMP/bin" "$TMP/kernel"
export NETPILOT_TEST_KERNEL="$TMP/kernel" NETPILOT_TEST_WRITES="$TMP/kernel-writes"
: > "$NETPILOT_TEST_WRITES"
printf 'reno cubic bbr\n' > "$TMP/kernel/net.ipv4.tcp_available_congestion_control"
printf 'cubic\n' > "$TMP/kernel/net.ipv4.tcp_congestion_control"
printf 'fq_codel\n' > "$TMP/kernel/net.core.default_qdisc"
printf '0\n' > "$TMP/kernel/net.ipv4.tcp_moderate_rcvbuf"
printf '212992\n' > "$TMP/kernel/net.core.rmem_max"
printf '212992\n' > "$TMP/kernel/net.core.wmem_max"
printf '4096 131072 6291456\n' > "$TMP/kernel/net.ipv4.tcp_rmem"
printf '4096 16384 4194304\n' > "$TMP/kernel/net.ipv4.tcp_wmem"
printf '0\n' > "$TMP/kernel/net.ipv4.tcp_ecn"
cp -a "$TMP/kernel" "$TMP/original-kernel"
cat > "$TMP/bin/sysctl" <<'SYSCTL'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  -n)
    [[ $# == 2 && "$2" =~ ^net\.[a-zA-Z0-9_.]+$ && -f "$NETPILOT_TEST_KERNEL/$2" ]] || exit 1
    cat -- "$NETPILOT_TEST_KERNEL/$2" ;;
  -w)
    [[ $# == 2 && "$2" == *=* ]] || exit 1
    key="${2%%=*}"; value="${2#*=}"
    [[ "$key" =~ ^net\.[a-zA-Z0-9_.]+$ && -f "$NETPILOT_TEST_KERNEL/$key" ]] || exit 1
    printf '%s\n' "$2" >> "$NETPILOT_TEST_WRITES"
    printf '%s\n' "$value" > "$NETPILOT_TEST_KERNEL/$key"
    printf '%s = %s\n' "$key" "$value" ;;
  *) exit 1 ;;
esac
SYSCTL
chmod 0755 "$TMP/bin/sysctl"
export PATH="$TMP/bin:$PATH"

cat > "$TMP/server.py" <<'SERVER'
import http.server, json, pathlib, sys
from urllib.parse import parse_qs, urlsplit
root = pathlib.Path(sys.argv[1])
class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, request, client_address):
        if not isinstance(sys.exc_info()[1], OSError):
            super().handle_error(request, client_address)
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def record(self, method, size, mode, sent=0, received=0):
        with (root / 'http-requests.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(method=method, requested=size, mode=mode,
                                         sent=sent, received=received)) + '\n')
    def headers_for(self, length, code=200, uploaded=None):
        self.send_response(code)
        self.send_header('Content-Length', str(length))
        self.send_header('colo', 'LAB')
        self.send_header('cf-meta-colo', 'LAB')
        self.send_header('CF-RAY', '0123456789abcdef-LAB')
        if uploaded is not None: self.send_header('cf-meta-upload-bytes', str(uploaded))
        self.end_headers()
    def do_GET(self):
        size = int(parse_qs(urlsplit(self.path).query)['bytes'][0])
        mode = (root / 'mode').read_text().strip()
        if mode == 'limited':
            self.record('GET', size, mode)
            self.headers_for(0, 429)
            return
        self.headers_for(size)
        remaining = size
        while remaining:
            chunk = b'x' * min(65536, remaining)
            self.wfile.write(chunk)
            remaining -= len(chunk)
        self.wfile.flush()
        self.record('GET', size, mode, sent=size)
    def do_POST(self):
        size = int(parse_qs(urlsplit(self.path).query)['bytes'][0])
        assert int(self.headers['Content-Length']) == size
        received = 0
        while received < size:
            chunk = self.rfile.read(min(65536, size - received))
            if not chunk: raise RuntimeError('incomplete test upload')
            assert not chunk.strip(b'\0'), 'only synthetic data may be uploaded'
            received += len(chunk)
        self.record('POST', size, 'ok', received=received)
        self.headers_for(0, uploaded=received)
server = Server(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_address[1]))
server.serve_forever()
SERVER
printf 'limited\n' > "$TMP/mode"
python3 "$TMP/server.py" "$TMP" > "$TMP/server.log" 2>&1 &
server_pid=$!
for _attempt in {1..100}; do
  [[ ! -s "$TMP/port" ]] || break
  kill -0 "$server_pid" 2>/dev/null || { cat "$TMP/server.log" >&2; fail 'HTTP server stopped'; }
  sleep .02
done
[[ -s "$TMP/port" ]] || fail 'HTTP server did not start'
endpoint="http://127.0.0.1:$(cat "$TMP/port")"

# A real rejection must stop the full command before any managed configuration
# or kernel write, while preserving its private failure report for inspection.
if bash "$SCRIPT" --lang en tune --endpoint "$endpoint" --budget-mib 1 < /dev/null > "$TMP/rejected.log" 2>&1; then
  fail 'the real CLI accepted a 429 baseline'
fi
[[ ! -e /var/lib/netpilot && ! -e /etc/sysctl.d/99-netpilot.conf && ! -s "$NETPILOT_TEST_WRITES" ]] || fail 'baseline rejection reached configuration changes'
diff -r "$TMP/kernel" "$TMP/original-kernel" > "$TMP/rejected-kernel.diff" || fail 'baseline rejection changed kernel values'
[[ -d "$REPORT_ROOT" ]] || { cat "$TMP/rejected.log" >&2; fail 'default report creation failed with a group-writable /var/log'; }
python3 - "$TMP" "$REPORT_ROOT" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]); reports=list(pathlib.Path(sys.argv[2]).glob('run.*/summary.json'))
assert len(reports)==1
summary=json.loads(reports[0].read_text())
assert summary['status']=='failed' and summary['stage']=='before'
assert summary['applied'] is False and summary['configuration_state']=='unchanged'
requests=[json.loads(line) for line in (root/'http-requests.jsonl').read_text().splitlines()]
assert 1 <= len(requests) <= 4 and all(item['mode']=='limited' for item in requests)
assert all(item['sent']==item['received']==0 for item in requests)
PY
printf 'PASS: full CLI rejects a real HTTP 429 baseline before creating configuration or backup state\n'

# The source, all CLI dispatch, HTTP transport, planner, actual system files,
# verification and final report comparison now run unchanged.
printf 'ok\n' > "$TMP/mode"
printf '# Managed by netpilot.sh.\nnet.ipv4.tcp_ecn = 0\n' > /etc/sysctl.d/99-netpilot.conf
cp -a /etc/sysctl.d/99-netpilot.conf "$TMP/original.conf"
bash "$SCRIPT" --lang en tune --endpoint "$endpoint" --budget-mib 1 < /dev/null > "$TMP/success.log" 2>&1 || {
  cat "$TMP/success.log" >&2; fail 'complete automatic tuning CLI failed';
}
[[ -f /var/lib/netpilot/original-values && -f /var/lib/netpilot/backup/sysctl-file ]] || fail 'CLI did not create its original-values and file backup'
cmp -s /var/lib/netpilot/backup/sysctl-file "$TMP/original.conf" || fail 'CLI backup differs from the actual original configuration'
grep -qx 'net.ipv4.tcp_congestion_control=cubic' /var/lib/netpilot/original-values || fail 'original algorithm was not recorded'
[[ "$(cat "$TMP/kernel/net.ipv4.tcp_congestion_control")" == bbr && "$(cat "$TMP/kernel/net.core.default_qdisc")" == fq && "$(cat "$TMP/kernel/net.ipv4.tcp_moderate_rcvbuf")" == 1 ]] || fail 'real CLI did not apply the basic plan'
for key in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
  cmp -s "$TMP/kernel/$key" "$TMP/original-kernel/$key" || fail "short local measurements changed buffer values: $key"
done
grep -Eiq 'short|budget-limited' "$TMP/success.log" || fail 'CLI omitted the short-sample reason'
grep -Eiq 'buffers' "$TMP/success.log" || fail 'CLI did not explain why buffer values were preserved'
bash "$SCRIPT" --lang en verify > "$TMP/verify.log" 2>&1 || fail 'separate real verify command rejected the persisted plan'
python3 - "$TMP" "$REPORT_ROOT" <<'PY'
import json, pathlib, stat, sys
root=pathlib.Path(sys.argv[1]); reports=pathlib.Path(sys.argv[2])
all_reports=[(path,json.loads(path.read_text())) for path in reports.glob('run.*/summary.json')]
success=[(path,data) for path,data in all_reports if data['status']=='completed']
assert len(success)==1 and len(all_reports)==2
path,summary=success[0]
assert summary['stage']=='completed' and summary['exit_code']==0
assert summary['changed'] and summary['applied'] and summary['verified']
assert summary['configuration_state']=='verified' and summary['comparison'] is not None
assert summary['comparison']['causal_claim'] is False
assert summary['comparison']['budget_limited'] is True
assert stat.S_IMODE(reports.stat().st_mode)==0o700
assert stat.S_IMODE(path.parent.stat().st_mode)==0o700
for name in ['before.json','after.json','summary.json']:
    assert stat.S_IMODE((path.parent/name).stat().st_mode)==0o600
before,after=summary['before'],summary['after']
for key in ['endpoint','address','port','node','latency_method','budget_bytes','timeout_seconds','connection_policy','node_verified']:
    assert before[key]==after[key], key
assert before['address']=='127.0.0.1' and before['node']=='LAB'
assert before['node_verified'] is True
for direction in ['download','upload']:
    assert before[direction]['request_sizes']==after[direction]['request_sizes']
assert before['reserved_bytes']+after['reserved_bytes']<=summary['budget_bytes']==1048576
requests=[json.loads(line) for line in (root/'http-requests.jsonl').read_text().splitlines()]
successful=[item for item in requests if item['mode']=='ok']
assert sum(item['requested'] for item in successful)<=1048576
assert sum(item['sent']+item['received'] for item in successful)==before['reserved_bytes']+after['reserved_bytes']
(root/'completed-report').write_text(str(path))
PY
printf 'PASS: real complete CLI measures, backs up, applies, verifies, retests and compares within one whole-run budget\n'
report_path="$(cat "$TMP/completed-report")"
report_hash="$(sha256sum "$report_path" | awk '{print $1}')"
bash "$SCRIPT" --lang en rollback > "$TMP/rollback.log" 2>&1 || { cat "$TMP/rollback.log" >&2; fail 'real rollback command failed'; }
diff -r "$TMP/kernel" "$TMP/original-kernel" > "$TMP/rollback-kernel.diff" || fail 'rollback did not restore exact original kernel values'
cmp -s /etc/sysctl.d/99-netpilot.conf "$TMP/original.conf" || fail 'rollback did not restore the actual original file'
[[ ! -e /var/lib/netpilot ]] || fail 'successful rollback left its owned state'
[[ -f "$report_path" && "$(sha256sum "$report_path" | awk '{print $1}')" == "$report_hash" ]] || fail 'rollback removed or changed the completed measurement report'
[[ ! -e /usr/local/bin/netpilot.sh && ! -e /usr/local/bin/netpilot && ! -L /usr/local/bin/netpilot ]] || fail 'automatic tune unexpectedly installed the script'
[[ "$(sha256sum "$SCRIPT" | awk '{print $1}')" == "$source_hash" ]] || fail 'CLI changed source bytes'
printf 'PASS: full CLI rollback restores actual parameters/configuration and preserves private automatic reports\n'

bash "$SCRIPT" --lang en report --json > "$TMP/default-report.json"
python3 - "$TMP/default-report.json" "$report_path" <<'PY'
import json, pathlib, sys
assert json.loads(pathlib.Path(sys.argv[1]).read_text()) == json.loads(pathlib.Path(sys.argv[2]).read_text())
PY
printf '10\n0\n' | bash "$SCRIPT" --lang en > "$TMP/menu-report.log"
grep -q 'Flow: Completed' "$TMP/menu-report.log" || fail 'menu 10 cannot read the default report'
grep -qx 'Full data: netpilot --lang en report --json' "$TMP/menu-report.log" || fail 'default report command still requires a custom path'
[[ "$(stat -c '%a:%u:%g' /var/log)" == "$log_identity" ]] || fail 'automatic tuning changed /var/log permissions or ownership'
[[ "$(sha256sum /var/log/netpilot/legacy-report | awk '{print $1}')" == "$legacy_hash" ]] || fail 'automatic tuning changed a legacy report'
printf 'PASS: default report and menu 10 work with group-writable /var/log; system permissions and legacy reports are preserved\n'
