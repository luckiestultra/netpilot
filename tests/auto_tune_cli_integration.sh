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
import http.server, json, pathlib, sys, time
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
        if mode == 'limited' or mode == 'reject-after-apply' and (root / 'kernel/net.ipv4.tcp_moderate_rcvbuf').read_text().strip() == '1':
            self.record('GET', size, mode)
            self.headers_for(0, 429 if mode == 'limited' else 403)
            return
        if mode == 'auto':
            time.sleep(3.1)
        elif mode in ('ok', 'reject-after-apply'):
            time.sleep(1.6)
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
        mode = (root / 'mode').read_text().strip()
        assert int(self.headers['Content-Length']) == size
        received = 0
        while received < size:
            chunk = self.rfile.read(min(65536, size - received))
            if not chunk: raise RuntimeError('incomplete test upload')
            assert not chunk.strip(b'\0'), 'only synthetic data may be uploaded'
            received += len(chunk)
        if mode == 'auto':
            time.sleep(3.1)
        elif mode in ('ok', 'reject-after-apply'):
            time.sleep(1.6)
        self.record('POST', size, mode, received=received)
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
if bash "$SCRIPT" --lang en tune --endpoint "$endpoint" --budget-mib 1 --timeout 5 < /dev/null > "$TMP/rejected.log" 2>&1; then
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
bash "$SCRIPT" --lang en tune --endpoint "$endpoint" --budget-mib 1 --timeout 5 < /dev/null > "$TMP/success.log" 2>&1 || {
  cat "$TMP/success.log" >&2; fail 'complete automatic tuning CLI failed';
}
[[ -f /var/lib/netpilot/original-values && -f /var/lib/netpilot/backup/sysctl-file ]] || fail 'CLI did not create its original-values and file backup'
cmp -s /var/lib/netpilot/backup/sysctl-file "$TMP/original.conf" || fail 'CLI backup differs from the actual original configuration'
grep -qx 'net.ipv4.tcp_moderate_rcvbuf=0' /var/lib/netpilot/original-values || fail 'original changed receive setting was not recorded'
[[ "$(cat "$TMP/kernel/net.ipv4.tcp_congestion_control")" == cubic && "$(cat "$TMP/kernel/net.core.default_qdisc")" == fq_codel && "$(cat "$TMP/kernel/net.ipv4.tcp_moderate_rcvbuf")" == 1 ]] || fail 'real CLI did not preserve the algorithm/default queue while applying receive autotuning'
[[ ! -e /etc/modules-load.d/netpilot.conf ]] || fail 'preserved CUBIC unexpectedly created BBR module persistence'
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
assert summary['budget_mode']=='fixed'
assert stat.S_IMODE(reports.stat().st_mode)==0o700
assert stat.S_IMODE(path.parent.stat().st_mode)==0o700
for name in ['before.json','after.json','algorithm.json','summary.json','run-snapshot.json']:
    assert stat.S_IMODE((path.parent/name).stat().st_mode)==0o600
before,after=summary['before'],summary['after']
for key in ['endpoint','address','port','node','latency_method','budget_bytes','timeout_seconds','connection_policy','node_verified']:
    assert before[key]==after[key], key
assert before['address']=='127.0.0.1' and before['node']=='LAB'
assert before['node_verified'] is True
for direction in ['download','upload']:
    assert before[direction]['request_sizes']==after[direction]['request_sizes']
assert summary['algorithm']['status']=='preserved' and summary['algorithm']['selected']=='cubic'
assert summary['algorithm']['reason_code']=='insufficient_budget' and summary['algorithm']['reserved_bytes']==0
assert summary['accounted_bytes']==before['reserved_bytes']+after['reserved_bytes']<=summary['budget_bytes']==1048576
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

# A failed retest must restore this run, retaining a previous tuning and its
# first-ever rollback records. The HTTP source observes the actual apply write
# and rejects the first post-apply download; it cannot fail the baseline.
bash "$SCRIPT" --lang en apply --yes --profile proxy --bandwidth 100 --rtt 50 > "$TMP/prior-apply.log" 2>&1 || fail 'could not prepare a previous valid tuning'
sysctl -w net.ipv4.tcp_moderate_rcvbuf=0 > /dev/null
cp -a "$TMP/kernel" "$TMP/run-start-kernel"
cp -p /etc/sysctl.d/99-netpilot.conf "$TMP/run-start.conf"
find /var/lib/netpilot -type f -print0 | sort -z | xargs -0 sha256sum > "$TMP/run-start-state.sha256"
printf 'reject-after-apply\n' > "$TMP/mode"
if bash "$SCRIPT" --lang en tune --endpoint "$endpoint" --budget-mib 1 --timeout 5 < /dev/null > "$TMP/failed-retest.log" 2>&1; then
  fail 'CLI claimed success after a real post-apply HTTP rejection'
fi
diff -r "$TMP/kernel" "$TMP/run-start-kernel" > "$TMP/run-restore.diff" || fail 'failed retest restored first-ever values instead of this run'
cmp -s /etc/sysctl.d/99-netpilot.conf "$TMP/run-start.conf" || fail 'failed retest discarded previous managed configuration'
sha256sum --check --status "$TMP/run-start-state.sha256" || fail 'failed retest changed prior applied state or first-ever backups'
bash "$SCRIPT" --lang en report --json > "$TMP/restored-summary.json"
python3 - "$TMP/restored-summary.json" <<'PYRESTORE'
import json,sys
with open(sys.argv[1]) as stream:data=json.load(stream)
assert data['status']=='failed' and data['stage']=='after' and data['exit_code']==1,data
assert data['configuration_state']=='restored' and data['rollback_status']=='completed',data
assert data['restoration_scope']=='run' and data['verify_status']=='restored',data
assert data['applied'] is False and data['verified'] is False and data['changed'] is True,data
assert data['before']['ok'] is True and data['after']['http_error']['status']==403,data
assert data['accounted_bytes']>data['before']['reserved_bytes'],data
PYRESTORE
bash "$SCRIPT" --lang en rollback > "$TMP/prior-rollback.log" 2>&1 || fail 'first-ever rollback did not survive run restoration'
diff -r "$TMP/kernel" "$TMP/original-kernel" > "$TMP/prior-rollback.diff" || fail 'first-ever rollback failed after per-run recovery'
cmp -s /etc/sysctl.d/99-netpilot.conf "$TMP/original.conf" || fail 'first-ever configuration was lost after per-run recovery'
printf 'PASS: complete CLI restores this run after a real HTTP403 retest and preserves earlier applied state and first-ever backups\n'

printf 'auto\n' > "$TMP/mode"
bash "$SCRIPT" --lang en tune --endpoint "$endpoint" < /dev/null > "$TMP/auto.log" 2>&1 || {
  cat "$TMP/auto.log" >&2; fail 'default automatic-budget CLI required input or failed';
}
[[ "$(cat "$TMP/kernel/net.core.rmem_max")" -gt 212992 ]] || fail 'long automatic samples did not reach buffer planning'
python3 - "$TMP" "$REPORT_ROOT" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]); reports=pathlib.Path(sys.argv[2])
all_reports=[(path,json.loads(path.read_text())) for path in reports.glob('run.*/summary.json')]
automatic=[(path,data) for path,data in all_reports if data.get('budget_mode')=='auto']
assert len(automatic)==1 and len(all_reports)==4
path,summary=automatic[0]
assert summary['status']=='completed' and summary['stage']=='completed' and summary['exit_code']==0
assert summary['budget_bytes']==16*1024**3 and summary['comparison']['budget_limited'] is False
assert summary['configuration_state']=='verified' and summary['applied'] and summary['verified']
before,after=summary['before'],summary['after']
for measurement in (before,after):
    assert measurement['budget_mode']=='auto' and measurement['budget_bytes']==8*1024**3
    assert measurement['reserved_bytes']==2*65536
    for direction in ('download','upload'):
        assert measurement[direction]['request_batches']==[[65536]]
        assert measurement[direction]['quality']=='sampled' and measurement[direction]['duration_seconds']>=3
assert summary['algorithm']['status']=='preserved' and summary['algorithm']['selected']=='cubic'
assert summary['algorithm']['reason_code']=='short_sample' and len(summary['algorithm']['trials'])==1
assert summary['algorithm']['reserved_bytes']==131072
assert summary['accounted_bytes']==before['reserved_bytes']+after['reserved_bytes']+summary['algorithm']['reserved_bytes']==393216 < summary['budget_bytes']
requests=[json.loads(line) for line in (root/'http-requests.jsonl').read_text().splitlines()]
automatic_requests=[item for item in requests if item['mode']=='auto']
assert len(automatic_requests)==6 and all(item['requested']==65536 for item in automatic_requests)
assert sum(item['sent']+item['received'] for item in automatic_requests)==393216
(root/'auto-completed-report').write_text(str(path))
PY
report_path="$(cat "$TMP/auto-completed-report")"
report_hash="$(sha256sum "$report_path" | awk '{print $1}')"
bash "$SCRIPT" --lang en rollback > "$TMP/auto-rollback.log" 2>&1 || fail 'automatic-budget run could not roll back'
diff -r "$TMP/kernel" "$TMP/original-kernel" > "$TMP/auto-rollback.diff" || fail 'automatic-budget rollback changed original kernel values'
cmp -s /etc/sysctl.d/99-netpilot.conf "$TMP/original.conf" || fail 'automatic-budget rollback did not restore the original file'
[[ ! -e /var/lib/netpilot && -f "$report_path" && "$(sha256sum "$report_path" | awk '{print $1}')" == "$report_hash" ]] || fail 'automatic-budget recovery lost its report or retained rollback state'
printf 'PASS: default automatic-budget CLI uses only the payload needed for real samples and preserves exact recovery\n'

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


# An insufficient candidate budget must not implicitly load an unmeasured BBR module.
# Only the module/kernel boundary is simulated; HTTP, files, dispatcher,
# planning, verification, reports and rollback use the production code.
printf 'ok\n' > "$TMP/mode"
printf 'reno cubic\n' > "$TMP/kernel/net.ipv4.tcp_available_congestion_control"
cp -a "$TMP/kernel" "$TMP/cold-original-kernel"
export NETPILOT_TEST_MODULE_LOG="$TMP/module-calls"
: > "$NETPILOT_TEST_MODULE_LOG"
cat > "$TMP/bin/modprobe" <<'MODPROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$*" == tcp_bbr ]] || exit 2
printf 'tcp_bbr\n' >> "$NETPILOT_TEST_MODULE_LOG"
printf 'reno cubic bbr\n' > "$NETPILOT_TEST_KERNEL/net.ipv4.tcp_available_congestion_control"
MODPROBE
chmod 0755 "$TMP/bin/modprobe"
bash "$SCRIPT" --lang en tune --endpoint "$endpoint" --budget-mib 1 --timeout 5 < /dev/null > "$TMP/cold-bbr.log" 2>&1 || {
  cat "$TMP/cold-bbr.log" >&2; fail 'real CLI failed with an installed but unloaded BBR module';
}
[[ ! -s "$NETPILOT_TEST_MODULE_LOG" ]] || fail 'real CLI implicitly loaded an algorithm without candidate budget'
[[ "$(cat "$TMP/kernel/net.ipv4.tcp_congestion_control")" == cubic ]] || fail 'real CLI failed to preserve the current algorithm'
[[ "$(cat "$TMP/kernel/net.core.default_qdisc")" == fq_codel ]] || fail 'real CLI failed to preserve the default queue'
[[ ! -e /etc/modules-load.d/netpilot.conf ]] || fail 'real CLI persisted an unselected BBR module'
bash "$SCRIPT" --lang en verify > "$TMP/cold-bbr-verify.log" 2>&1 || fail 'real cold-BBR CLI configuration did not verify'
bash "$SCRIPT" --lang en report --json > "$TMP/cold-bbr-summary.json"
python3 - "$TMP/cold-bbr-summary.json" <<'PYREPORT'
import json, sys
with open(sys.argv[1]) as f: data=json.load(f)
assert data['status']=='completed' and data['changed'] and data['applied'] and data['verified'], data
assert data['comparison'] is not None, data
assert data['algorithm']['reason_code']=='insufficient_budget' and data['algorithm']['reserved_bytes']==0,data
PYREPORT
bash "$SCRIPT" --lang en rollback > "$TMP/cold-bbr-rollback.log" 2>&1 || fail 'real cold-BBR CLI rollback failed'
# No module is loaded or unloaded when the complete comparison cannot fit.
[[ "$(cat "$TMP/cold-original-kernel/net.ipv4.tcp_available_congestion_control")" == 'reno cubic' ]] || fail 'cold fixture was not actually unloaded'
[[ "$(cat "$TMP/kernel/net.ipv4.tcp_available_congestion_control")" == 'reno cubic' ]] || fail 'automatic tuning or rollback unexpectedly changed module availability'
for original in "$TMP/cold-original-kernel"/*; do
  key="${original##*/}"
  [[ "$key" == net.ipv4.tcp_available_congestion_control ]] && continue
  cmp -s "$TMP/kernel/$key" "$original" || fail "real cold-BBR CLI rollback changed original parameter: $key"
done
[[ ! -e /etc/modules-load.d/netpilot.conf ]] || fail 'real cold-BBR CLI rollback retained module persistence'
printf 'PASS: real cold-BBR CLI preserves the current algorithm/module state when comparison budget is insufficient\n'
