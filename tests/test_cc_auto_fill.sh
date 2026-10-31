#!/usr/bin/env bash
# Reproduce the VPS short-active-time run without consuming public traffic.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_OVERRIDE:-$ROOT/netpilot.sh}"
python3 - "$SCRIPT" <<'PY'
import copy,json,math,os,pathlib,subprocess,sys,tempfile
script=pathlib.Path(sys.argv[1]).resolve()
source=script.read_text()
fragment=source[source.index('# BEGIN HTTP MEASUREMENT'):source.index('# END HTTP MEASUREMENT')]
stub=r'''
http_measure_path() {
python3 - "$@" <<'STUB'
import json,math,os,pathlib,sys
phase,endpoint,budget,seconds,output,before,cc,direction,target=sys.argv[1:10]
limit=int(sys.argv[10]) if len(sys.argv)>10 else int(target)
target=int(target); b=json.loads(pathlib.Path(before).read_text()); case=os.environ['CASE']
log=pathlib.Path(os.environ['CALLS']); n=len(log.read_text().splitlines()) if log.exists() else 0
with log.open('a') as f:f.write(json.dumps([cc,target,limit])+'\n')
if case=='refused' and n==1:
 pathlib.Path(output).write_text(json.dumps(dict(ok=False,http_error={'status':403},reserved_bytes=0)));sys.exit(1)
def plan(amount):
 out=[];left=amount
 while left:
  for batch in b['upload']['request_batches']:
   sizes=[]
   for size in batch:
    if not left:break
    size=min(size,left);sizes.append(size);left-=size
   if sizes:out.append(sizes)
   if not left:break
 return out
if case in ('live','cap','win'):
 slope=2.596/1762561521
 def busy(amount):return amount*slope
 def duration(amount):return amount*11.14821787099936/1762561521
else:
 def busy(amount):return 2.6 if n==1 else 3.6
 def duration(amount):return 4.8/(1.2 if cc=='bbr' else 1.)
amount=int(target)
if len(sys.argv)>10:
 amount=0
 for batch in plan(limit):
  amount+=sum(batch)
  if amount>=target and busy(amount)>=3.5:break
batches=plan(amount); sizes=[s for batch in batches for s in batch]
elapsed=duration(amount)/(1.2 if case=='win' and cc=='cubic' else 1.)
u=dict(request_sizes=sizes,request_batches=batches,payload_bytes=amount,
 duration_seconds=elapsed,bits_per_second=amount*8/elapsed,
 quality='sampled' if elapsed>=3 else 'budget-limited',
 tcp_info=dict(supported=True,srtt_ms=1.,busy_time_seconds=busy(amount),
 connection_busy_seconds=[busy(amount)]*4,total_retransmissions=0))
r=dict(b,phase='after',ok=True,requested_congestion_algorithm=cc,congestion_algorithm=cc,
 reserved_bytes=amount,upload=u,upload_bps=u['bits_per_second'])
pathlib.Path(output).write_text(json.dumps(r))
STUB
}
'''
base=dict(type='netpilot-http-measurement',version=1,ok=True,phase='before',
 endpoint='http://127.0.0.1:12345',address='127.0.0.1',port=12345,node='LAB',node_verified=True,
 budget_bytes=8*1024**3,budget_mode='auto',timeout_seconds=30,latency_ms=1.247096680648004,
 latency_method='tcp-connect-estimate',connection_policy='pinned-parallel',
 measurement_policy='parallel-http-v1',parallelism=4)
for direction,cycles in [('download',34),('upload',30)]:
 batches=[[65536],[262144]*4,[1048576]*4]+[[4194304]*4]*cycles
 sizes=[n for batch in batches for n in batch]; amount=sum(sizes)
 u=dict(request_sizes=sizes,request_batches=batches,payload_bytes=amount,
 duration_seconds=3.033472837996669,bits_per_second=amount*8/3.033472837996669,quality='sampled')
 if direction=='upload':u['tcp_info']=dict(supported=True,busy_time_seconds=1.01)
 base[direction]=u;base[direction+'_bps']=u['bits_per_second']
base['reserved_bytes']=sum(base[d]['payload_bytes'] for d in ('download','upload'))
with tempfile.TemporaryDirectory() as temporary:
 root=pathlib.Path(temporary); f=root/'functions.sh';f.write_text(fragment)
 def run(case,total=16*1024**3,baseline=base,original='bbr'):
  d=root/case;d.mkdir(mode=0o700);p=d/'before.json';p.write_text(json.dumps(baseline))
  cmd='source "$1"; '+stub+'\nhttp_select_congestion "$2" "$3" "$4" 30 "$5" "$6"'
  proc=subprocess.run(['bash','-c',cmd,'_',str(f),str(p),base['endpoint'],str(total),str(d),original],
   capture_output=True,text=True,env={**os.environ,'CASE':case,'CALLS':str(d/'calls')},timeout=10)
  r=json.loads((d/'algorithm.json').read_text());calls=[json.loads(x) for x in (d/'calls').read_text().splitlines()]
  all_trials=r.get('discarded_trials',[])+r['trials']
  assert r['reserved_bytes']==sum(t['reserved_bytes'] for t in all_trials)<=total-3*baseline['reserved_bytes'],r
  return proc,r,calls,d
 for case in ('live','win'):
  p,r,calls,d=run(case)
  assert p.returncode==0 and r['reason_code']==('consistent_gain' if case=='win' else 'no_consistent_gain'),(p.stderr,r)
  assert len(calls)==len(r['trials'])==6 and not r.get('discarded_trials'),r
  amount=r['trial_allowance_bytes']
  assert amount>1762561521 and amount<=(16*1024**3-3*base['reserved_bytes'])//6,r
  assert all(t['upload']['payload_bytes']==amount and t['upload']['tcp_info']['busy_time_seconds']>=3 for t in r['trials']),r
  assert all(t['upload']['request_batches']==r['trials'][0]['upload']['request_batches'] for t in r['trials']),r
  assert r['reserved_bytes']==6*amount and r['total_timeout_seconds']==180,r
  if case=='win':
   read=subprocess.run(['bash','-c','source "$1"; auto_report selected "$2" "$3"','_',str(script),str(d/'algorithm.json'),str(16*1024**3)],capture_output=True,text=True)
   assert read.returncode==0 and read.stdout.strip()=='cubic',(read.stdout,read.stderr)
 print('PASS: recorded 2.596s VPS sample is extended in its original measurement, then all six algorithms replay identical work inside 16GiB')
 small=copy.deepcopy(base)
 for direction in ('download','upload'):
  u=small[direction];u.update(request_sizes=[131072]*4,request_batches=[[131072]*4],payload_bytes=524288,
   duration_seconds=3.2,bits_per_second=524288*8/3.2)
  if direction=='upload':u['tcp_info']=dict(supported=True,busy_time_seconds=1.)
  small[direction+'_bps']=u['bits_per_second']
 small['reserved_bytes']=1048576
 p,r,calls,d=run('later',512*1048576,small,'cubic')
 assert p.returncode==0 and r['reason_code']=='consistent_gain',(p.stderr,r)
 assert len(r.get('discarded_trials',[]))==2 and len(r['trials'])==6 and len(calls)==8,r
 assert all(t['upload']['request_batches']==r['trials'][0]['upload']['request_batches'] for t in r['trials']),r
 read=subprocess.run(['bash','-c','source "$1"; auto_report selected "$2" "$3"','_',str(script),str(d/'algorithm.json'),str(512*1048576)],capture_output=True,text=True)
 assert read.returncode==0 and read.stdout.strip()=='bbr',(read.stdout,read.stderr)
 print('PASS: a later short sample replans the paired comparison without mixing work sizes or refunding discarded traffic')
 initial=math.ceil(base['upload']['payload_bytes']*3.5/1.01)
 p,r,calls,_=run('cap',3*base['reserved_bytes']+6*initial)
 assert p.returncode==0 and r['reason_code']=='insufficient_budget' and len(calls)==1,r
 p,r,calls,_=run('refused',512*1048576,small,'cubic')
 assert p.returncode!=0 and r['reason_code']=='endpoint_rejected' and len(calls)==2,r
 print('PASS: insufficient remaining budget and HTTP rejection stop without spending the retest reserve')
PY
