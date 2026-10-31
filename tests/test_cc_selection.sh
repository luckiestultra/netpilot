#!/usr/bin/env bash
# Deterministic selector decisions; fake transfers never contact the network.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_OVERRIDE:-$ROOT/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
sed -n '/^# BEGIN HTTP MEASUREMENT$/,/^# END HTTP MEASUREMENT$/p' "$SCRIPT" > "$TMP/functions.sh"
source "$TMP/functions.sh"
declare -F http_select_congestion >/dev/null || { printf 'FAIL: congestion selector is missing\n' >&2; exit 1; }
export NETPILOT_CC_FRAGMENT="$TMP/functions.sh" NETPILOT_CC_TEST_TMP="$TMP"
python3 - <<'PY'
import copy,json,os,pathlib,stat,subprocess
root=pathlib.Path(os.environ['NETPILOT_CC_TEST_TMP'])
fragment=os.environ['NETPILOT_CC_FRAGMENT']
# Exercise the actual Linux tcp_info decoder at its binary capability boundary.
import ast,socket,struct,types
backend_source=pathlib.Path(fragment).read_text().split("<<'PY' &\n",1)[1].split('\nPY\n',1)[0]
module=ast.parse(backend_source)
decoder=next(node for node in module.body if isinstance(node,ast.FunctionDef) and node.name=='tcp_snapshot')
namespace={'socket':socket,'struct':struct}
exec(compile(ast.Module(body=[decoder],type_ignores=[]),'<tcp-info-decoder>','exec'),namespace)
class InfoSocket:
    def __init__(self,data):self.data=data
    def getsockopt(self,*_):return self.data
buffer=bytearray(176)
struct.pack_into('=I',buffer,68,1500)
struct.pack_into('=I',buffer,100,7)
struct.pack_into('=Q',buffer,168,3200000)
# macOS does not expose TCP_INFO; the decoder is a Linux UAPI contract.
if not hasattr(socket,'TCP_INFO'):socket.TCP_INFO=11
assert namespace['tcp_snapshot'](types.SimpleNamespace(sock=InfoSocket(bytes(buffer))))==(1.5,7,3.2)
assert namespace['tcp_snapshot'](types.SimpleNamespace(sock=InfoSocket(bytes(buffer[:175])))) is None
print('PASS: Linux tcp_info busy_time requires 176 returned bytes and decodes the u64 at offset168 in microseconds')
base={'type':'netpilot-http-measurement','version':1,'ok':True,'phase':'before',
      'endpoint':'http://127.0.0.1:12345','address':'127.0.0.1','port':12345,'node':'LAB','node_verified':True,
      'budget_bytes':1048576,'budget_mode':'fixed','reserved_bytes':1048576,'timeout_seconds':10,
      'latency_ms':1.,'latency_method':'tcp-connect-estimate','connection_policy':'pinned-parallel',
      'measurement_policy':'parallel-http-v1','parallelism':4}
for direction in ('download','upload'):
    base[direction]={'request_sizes':[131072]*4,'request_batches':[[131072]*4],
                     'payload_bytes':524288,'duration_seconds':4.,'bits_per_second':1048576.,'quality':'sampled'}
    base[direction+'_bps']=1048576.
stub=r'''
http_measure_path() {
  python3 - "$@" <<'STUB'
import json,os,pathlib,sys
phase,endpoint,budget,timeout,output,baseline,cc,mode=sys.argv[1:]
b=json.loads(pathlib.Path(baseline).read_text()); case=os.environ['CC_CASE']
log=pathlib.Path(os.environ['CC_LOG']); count=len(log.read_text().splitlines()) if log.exists() else 0
with log.open('a') as f:f.write(cc+' '+mode+'\n')
assert phase=='after' and mode=='upload' and cc in ('cubic','bbr')
assert endpoint==b['endpoint'] and int(budget)==b['budget_bytes'] and int(timeout)==10
if case=='missing-report':sys.exit(1)
if case=='unsupported-cc':
 pathlib.Path(output).write_text(json.dumps(dict(ok=False,error_code='congestion_unavailable')));sys.exit(1)
if case=='fatal':sys.exit(139)
if case=='cancel':sys.exit(130)
sizes=b['upload']['request_sizes']*2; batches=b['upload']['request_batches']*2
ratio=1.2 if cc!=os.environ['CC_ORIGINAL'] else 1.
if case=='threshold':ratio=1.1 if cc!=os.environ['CC_ORIGINAL'] else 1.
if case=='equal':ratio=1.
if case=='mixed' and count==2:ratio=1.
duration=4.8/ratio
if case=='short':duration=.1
busy=20. if case=='impossible-busy' else 1. if case=='overlap' else 3.2 if case!='idle' else .001
srtt=1. if cc==os.environ['CC_ORIGINAL'] else (3. if case=='rtt' else 1.1)
r=dict(b,phase='after',congestion_algorithm=cc,requested_congestion_algorithm=cc,
       reserved_bytes=sum(sizes),duration_seconds=duration,process_cpu_seconds=.05)
r['upload']=dict(request_sizes=sizes,request_batches=batches,payload_bytes=sum(sizes),
                 duration_seconds=duration,bits_per_second=sum(sizes)*8/duration,
                 quality='sampled' if duration>=3 else 'budget-limited',
                 tcp_info={'supported':case!='missing-tcp','srtt_ms':srtt,
                           'busy_time_seconds':busy,'connection_busy_seconds':[busy]*4 if case=='overlap' else [busy,min(.1,busy),min(.1,busy),min(.1,busy)],
                           'total_retransmissions':0})
r['upload_bps']=r['upload']['bits_per_second']
if case=='wrong-cc':r['congestion_algorithm']='reno'
if case=='wrong-schedule':r['upload']['request_batches']=[[1]]
if case=='wrong-peer':r['node']='ALT'
if case=='forbidden':r.update(ok=False,error='denied',http_error={'status':403});r['reserved_bytes']=524288
pathlib.Path(output).write_text(json.dumps(r));sys.exit(1 if case=='forbidden' else 0)
STUB
}
'''
def run(case,original='cubic',budget=64*1048576,baseline=None):
    d=root/(case+'-'+original+'-'+str(budget));d.mkdir(mode=0o700)
    before=d/'before.json';before.write_text(json.dumps(base if baseline is None else baseline))
    env=dict(os.environ,CC_CASE=case,CC_ORIGINAL=original,CC_LOG=str(d/'calls'))
    command='source "$1"; '+stub+'\nhttp_select_congestion "$2" "$3" "$4" 10 "$5" "$6"'
    p=subprocess.run(['bash','-c',command,'_',fragment,str(before),base['endpoint'],str(budget),str(d),original],env=env,capture_output=True,timeout=8)
    path=d/'algorithm.json';r=json.loads(path.read_text()) if path.exists() else None
    calls=(d/'calls').read_text().splitlines() if (d/'calls').exists() else []
    if r:
        assert r['type']=='netpilot-algorithm-selection' and r['version']==1
        assert r['original']==original and r['status'] in ('preserved','selected')
        assert type(r['reserved_bytes']) is int and 0<=r['reserved_bytes']<=max(0,budget-3*base['reserved_bytes'])
        assert stat.S_IMODE(path.stat().st_mode)==0o600
    return p,r,calls,d
for original in ('cubic','bbr'):
    p,r,calls,_=run('win',original)
    assert p.returncode==0,(p.stderr,r)
    assert r['status']=='selected' and r['selected']==('bbr' if original=='cubic' else 'cubic'),r
    candidate=r['selected']
    assert calls==[original+' upload',candidate+' upload',candidate+' upload',original+' upload',original+' upload',candidate+' upload'],calls
    assert r['reserved_bytes']==6*1048576 and len(r['trials'])==6,r
p,r,_,_=run('threshold')
assert p.returncode==0 and r['status']=='selected',r
print('PASS: three alternating paired upload schedules select either candidate only on consistent wins')
for case,reason in [('equal','no_consistent_gain'),('mixed','no_consistent_gain'),('rtt','latency_regression'),
                    ('short','short_sample'),('idle','short_sample'),('overlap','short_sample'),('missing-tcp','missing_tcp_info'),('impossible-busy','missing_tcp_info'),
                    ('wrong-cc','conditions_mismatch'),('wrong-schedule','conditions_mismatch'),('wrong-peer','conditions_mismatch'),
                    ('forbidden','endpoint_rejected'),('missing-report','trial_failed'),('unsupported-cc','congestion_unavailable')]:
    p,r,calls,_=run(case)
    assert p.returncode==0 and r['selected']=='cubic' and r['status']=='preserved',(case,p.stderr,r)
    assert r['reason_code']==reason,(case,r)
    assert calls and r['reserved_bytes']>=len(calls)*1048576,(case,r,calls)
print('PASS: mixed, slow-ACK-only, short, missing TCP evidence, refused, missing and mismatched trials preserve the original algorithm')
p,r,calls,_=run('budget',budget=8*1048576)
assert p.returncode==0 and r['reason_code']=='insufficient_budget' and r['reserved_bytes']==0 and not calls,r
p,r,calls,_=run('unsupported',original='reno')
assert p.returncode==0 and r['reason_code']=='unsupported_original' and not calls,r
print('PASS: full six-trial plan and two final measurements are reserved before any candidate traffic')
for case in ('fatal','cancel'):
    p,r,calls,_=run(case)
    assert p.returncode!=0 and r['reserved_bytes']==1048576,(case,p.returncode,r)
corrupt=copy.deepcopy(base);corrupt['upload']['request_sizes']=[True]
p,r,calls,_=run('corrupt',baseline=corrupt)
assert p.returncode!=0 and not calls,(p.returncode,r,calls)
print('PASS: corrupt baseline, internal child failure and cancellation cannot become a preserved success')
d=root/'existing';d.mkdir(mode=0o700);before=d/'before.json';before.write_text(json.dumps(base))
target=d/'target';target.write_text('KEEP');(d/'algorithm.json').symlink_to(target)
p=subprocess.run(['bash','-c','source "$1"; http_select_congestion "$2" "$3" 67108864 10 "$4" cubic','_',fragment,str(before),base['endpoint'],str(d)],capture_output=True)
assert p.returncode!=0 and target.read_text()=='KEEP' and (d/'algorithm.json').is_symlink()
print('PASS: selector report publication is private and cannot replace an existing file or symlink')
PY
