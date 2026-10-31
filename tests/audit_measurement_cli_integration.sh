#!/usr/bin/env bash
# Independent audit regressions. Execute only in the approved isolated container.
set -Eeuo pipefail
[[ $(uname -s) == Linux && -f /.dockerenv && $EUID == 0 ]] || { printf 'Run as root in the isolated Linux container.\n' >&2; exit 2; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_OVERRIDE:-$ROOT/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
# shellcheck source=/dev/null
source "$SCRIPT"
export AUDIT_TMP="$TMP" AUDIT_SCRIPT="$SCRIPT"

test_compare_rejects_nonfinite_change() (
  python3 - "$TMP" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
report=dict(schema_version=1, kind='netpilot-benchmark', peer='127.0.0.1',
            port=5201, streams=1, budget_bytes=1048576, timeout_seconds=30,
            direction='send', latency_enabled=False, bytes_per_run_target=917504,
            runs=[dict(direction='send', status='ok', mbps=5e-324, seconds=4,
                       bytes=917504, sample_quality='bounded_sample',
                       remote_endpoints=[dict(address='127.0.0.1',port=5201)])])
(root/'before.json').write_text(json.dumps(report))
report['runs'][0]['mbps']=1e308
(root/'after.json').write_text(json.dumps(report))
PY
  local rc=0
  bench_compare "$TMP/before.json" "$TMP/after.json" > "$TMP/ratio.log" 2>&1 || rc=$?
  if [[ "$rc" == 0 ]]; then
    printf 'RED: compare returned success for a nonfinite change percentage\n' >&2
    tail -n 2 "$TMP/ratio.log" >&2
    return 1
  fi
)

test_compare_rejects_changed_request_target() (
  python3 - "$TMP" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
for phase, target, rate in [('before',917504,1.0),('after',131072,2.0)]:
    seconds=target*8/(rate*1e6)
    report=dict(schema_version=1, kind='netpilot-benchmark', peer='127.0.0.1',
                port=5201, streams=1, budget_bytes=1048576, timeout_seconds=30,
                direction='send', latency_enabled=False, bytes_per_run_target=target,
                runs=[dict(direction='send',status='ok',mbps=rate,seconds=seconds,
                           bytes=target,sample_quality='short_sample' if seconds<3 else 'bounded_sample',
                           remote_endpoints=[dict(address='127.0.0.1',port=5201)])])
    (root/(phase+'.json')).write_text(json.dumps(report))
PY
  local rc=0
  bench_compare "$TMP/before.json" "$TMP/after.json" > "$TMP/target.log" 2>&1 || rc=$?
  if [[ "$rc" == 0 ]]; then
    printf 'RED: compare accepted differing bytes_per_run_target as the same conditions\n' >&2
    cat "$TMP/target.log" >&2
    return 1
  fi
)

test_real_bench_rejects_changed_resolved_peer() (
  python3 - <<'PY'
import json,os,pathlib,shlex,shutil,socket,subprocess,sys,time
root=pathlib.Path(os.environ['AUDIT_TMP'])/'dns';root.mkdir()
real_iperf=shutil.which('iperf3');assert real_iperf
with socket.socket() as sock:
    sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
server_log=(root/'server.log').open('w')
server=subprocess.Popen([real_iperf,'-s','-B','0.0.0.0','-p',str(port)],stdout=server_log,stderr=subprocess.STDOUT)
hosts=pathlib.Path('/etc/hosts');original_hosts=hosts.read_text()
alias='netpilot-audit-peer-'+str(os.getpid())
binary=root/'bin';binary.mkdir()
wrapper=binary/'iperf3'
# This case checks peer identity, not peak rate. Pace real TCP traffic so a
# 917 KiB sample gives the receiver an observable sampling window.
wrapper.write_text('#!/bin/bash\nset -o pipefail\n'+shlex.quote(real_iperf)+' "$@" -b 8M 2> >(tee "$AUDIT_ERR" >&2) | tee "$AUDIT_RAW"\n')
wrapper.chmod(0o755)
env=dict(os.environ,PATH=str(binary)+':'+os.environ['PATH'])
try:
    ready_deadline=time.monotonic()+3
    while True:
        assert server.poll() is None,'local iperf server exited: '+(root/'server.log').read_text(errors='replace')
        # An empty TCP connect is an invalid iperf control session. Inspect the
        # server's own listening socket without changing its protocol state.
        listening=subprocess.run(['ss','-H','-ltnp','sport = :'+str(port)],
                                 capture_output=True,text=True,check=True)
        if 'pid='+str(server.pid)+',' in listening.stdout: break
        assert time.monotonic()<ready_deadline,('local iperf server did not listen',listening.stdout,listening.stderr)
        time.sleep(.01)
    remotes=[]
    for phase,address in [('before','127.0.0.1'),('after','127.0.0.2')]:
        hosts.write_text(original_hosts+'\n'+address+' '+alias+'\n')
        env['AUDIT_RAW']=str(root/(phase+'-raw.json'))
        env['AUDIT_ERR']=str(root/(phase+'-iperf.err'))
        result=subprocess.run(['bash',os.environ['AUDIT_SCRIPT'],'bench','--peer',alias,'--port',str(port),
                               '--direction','send','--budget-mib','1','--timeout','5',
                               '--output',str(root/(phase+'.json')),'--yes'],env=env,capture_output=True,timeout=9)
        if result.returncode != 0:
            print('Fixture benchmark failed at '+phase+', exit='+str(result.returncode),file=sys.stderr)
            print(result.stdout.decode(errors='replace')+result.stderr.decode(errors='replace'),file=sys.stderr)
            server_log.flush()
            for name in (phase+'.json',phase+'-raw.json',phase+'-iperf.err','server.log'):
                path=root/name
                print('--- '+name+' ---\n'+(path.read_text(errors='replace') if path.exists() else '(not created)'),file=sys.stderr)
        assert result.returncode==0,'real benchmark did not reach peer comparison'
        raw=json.loads(pathlib.Path(env['AUDIT_RAW']).read_text())
        assert raw['start']['test_start']['target_bitrate']==8_000_000,raw['start']
        assert raw['end']['sum_received']['bytes']>0 and raw['end']['sum_received']['seconds']>.1,raw['end']
        remotes.append(raw['start']['connected'][0]['remote_host'])
    assert remotes==['127.0.0.1','127.0.0.2'],remotes
    result=subprocess.run(['bash',os.environ['AUDIT_SCRIPT'],'compare',str(root/'before.json'),str(root/'after.json')],
                          capture_output=True,timeout=3)
    assert result.returncode!=0,('RED: genuine reports from different actual peers compare successfully',
                                 remotes,result.stdout.decode())
    reason=result.stderr.decode(errors='replace')
    assert '实际对端不同' in reason or 'different actual peers' in reason,('comparison failed for another reason',reason)
finally:
    hosts.write_text(original_hosts)
    server.terminate()
    try:server.wait(timeout=2)
    except subprocess.TimeoutExpired:server.kill();server.wait()
    server_log.close()
PY
)

test_report_root_rejects_replaceable_ancestor() (
  # Let a different UID traverse the fixture's parents, as it can under /tmp.
  chmod 0755 "$TMP"
  mkdir -p "$TMP/open-parent/reports"
  chmod 0777 "$TMP/open-parent"
  chmod 0700 "$TMP/open-parent/reports"
  local rc=0 run_dir
  run_dir="$(auto_report prepare "$TMP/open-parent/reports" "$TMP/state" 2> "$TMP/parent.log")" || rc=$?
  if [[ "$rc" == 0 ]]; then
    printf 'RED: report preparation accepted a root directory replaceable through its nonsticky 0777 parent: %s\n' "$run_dir" >&2
    return 1
  fi
)

test_report_root_canonical_private_creation() (
  umask 0000
  mkdir -m 0700 "$TMP/secure"
  ln -s "$TMP/secure" "$TMP/parent-alias"
  local run_dir
  run_dir="$(auto_report prepare "$TMP/parent-alias/new/nested/reports" "$TMP/state")"
  python3 - "$TMP" "$run_dir" <<'PY'
import pathlib,stat,sys
root=pathlib.Path(sys.argv[1]);run=pathlib.Path(sys.argv[2])
assert root/'secure' in run.parents and 'parent-alias' not in str(run),run
for path in (root/'secure/new',root/'secure/new/nested',run.parent,run):
    assert stat.S_IMODE(path.stat().st_mode)==0o700,(path,oct(path.stat().st_mode))
PY
  mkdir -m 1777 "$TMP/trusted-sticky"
  auto_report prepare "$TMP/trusted-sticky/reports" "$TMP/state" > /dev/null
  mkdir -m 0700 "$TMP/secure/deep"
  ln -s "$TMP/secure/deep" "$TMP/linked-parent"
  run_dir="$(auto_report prepare "$TMP/linked-parent/../reports" "$TMP/state")"
  [[ "$run_dir" == "$TMP/secure/reports/"* ]] || return 1
  ln -s "$TMP/secure" "$TMP/final-alias"
  if auto_report prepare "$TMP/final-alias" "$TMP/state" > /dev/null 2>&1; then
    printf 'FAIL: final report symlink accepted\n' >&2; return 1
  fi
)

test_auto_cancellation_restores_original_trap() (
  trap 'printf restored > "$TMP/trap-fired"' TERM
  local original status iteration
  original="$(trap -p TERM)"
  http_measure_path() { kill -TERM "$BASHPID"; return 143; }
  for iteration in 1 2; do
    status=0
    auto_tune --report-dir "$TMP/trap-reports" > "$TMP/trap-$iteration.log" 2>&1 || status=$?
    [[ "$status" == 143 && "$(trap -p TERM)" == "$original" ]] || return 1
  done
  kill -TERM "$BASHPID"
  [[ -s "$TMP/trap-fired" ]]
)

test_parent_pid_termination_stops_requests() (
  python3 - <<'PY'
import http.server,json,os,pathlib,signal,subprocess,threading,time
from urllib.parse import parse_qs,urlsplit
root=pathlib.Path(os.environ['AUDIT_TMP'])/'cancel-reports'
state={'requests':[],'seen':threading.Event()}
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def do_GET(self):
        size=int(parse_qs(urlsplit(self.path).query)['bytes'][0])
        state['requests'].append(('GET',size,time.monotonic()))
        state['seen'].set()
        time.sleep(.8)
        try:
            self.send_response(200)
            self.send_header('Content-Length',str(size))
            self.send_header('colo','LAB')
            self.end_headers()
            self.wfile.write(b'x'*size)
            self.wfile.flush()
        except OSError: pass
    def do_POST(self):
        size=int(self.headers['Content-Length'])
        self.rfile.read(size)
        state['requests'].append(('POST',size,time.monotonic()))
        time.sleep(.8)
        try:
            self.send_response(200)
            self.send_header('Content-Length','0')
            self.send_header('cf-meta-upload-bytes',str(size))
            self.send_header('colo','LAB')
            self.end_headers()
        except OSError: pass
class Server(http.server.ThreadingHTTPServer): daemon_threads=True
server=Server(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
endpoint='http://127.0.0.1:'+str(server.server_address[1])
process=subprocess.Popen(['bash',os.environ['AUDIT_SCRIPT'],'tune','--endpoint',endpoint,
                         '--budget-mib','1','--timeout','10','--report-dir',str(root)],
                         stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
try:
    assert state['seen'].wait(3),'local HTTP fixture did not receive a request'
    sent=time.monotonic()
    process.send_signal(signal.SIGTERM)
    stdout,stderr=process.communicate(timeout=14)
    elapsed=time.monotonic()-sent
    assert process.returncode != 0,(stdout,stderr)
    processes=subprocess.check_output(['ps','-eo','pid=,pgid=,stat='],text=True)
    alive=[line for line in processes.splitlines() if len(line.split())==3 and
           int(line.split()[1])==process.pid and not line.split()[2].startswith('Z')]
    assert not alive,('cancellation left live descendants',alive)
    reports=list(root.rglob('summary.json'))
    if reports:
        summary=json.loads(reports[0].read_text())
        assert summary['configuration_state']=='unchanged',summary
    later=[(method,size)for method,size,when in state['requests']if when>sent]
    assert not later,('RED: shell-only SIGTERM allowed later requests',later,
                      'seconds to exit',round(elapsed,2))
finally:
    if process.poll() is None:
        os.killpg(process.pid,signal.SIGKILL)
        process.communicate()
    server.shutdown()
    server.server_close()
PY
)

failures=0
selected=0
for test in test_compare_rejects_nonfinite_change test_compare_rejects_changed_request_target test_real_bench_rejects_changed_resolved_peer test_report_root_rejects_replaceable_ancestor test_report_root_canonical_private_creation test_parent_pid_termination_stops_requests test_auto_cancellation_restores_original_trap; do
  [[ -z "${AUDIT_ONLY:-}" || "$test" == "$AUDIT_ONLY" ]] || continue
  selected=$((selected+1))
  if "$test"; then printf 'PASS: %s\n' "$test"
  else printf 'FAIL: %s\n' "$test" >&2; failures=$((failures+1)); fi
done
((selected)) || { printf 'Unknown audit case: %s\n' "$AUDIT_ONLY" >&2; exit 2; }
[[ "$failures" == 0 ]]
