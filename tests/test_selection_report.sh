#!/usr/bin/env bash
# Validate the actual report reader against contradictory candidate evidence.
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
python3 - "$SCRIPT" "$TMP" <<'PY'
import json,pathlib,subprocess,sys
source=pathlib.Path(sys.argv[1]).read_text(); root=pathlib.Path(sys.argv[2])
program=source.split('auto_report() {\n',1)[1].split("<<'PY'\n",1)[1].split('\nPY\n',1)[0]
MIB=1048576
def fixture(original='cubic',gain=1.2,rtt=10.5):
    candidate='bbr' if original=='cubic' else 'cubic'
    r=dict(type='netpilot-algorithm-selection',version=1,original=original,selected=candidate,
           status='selected',reason_code='consistent_gain',candidate=candidate,
           reserved_bytes=6*MIB,trials=[],budget_bytes=64*MIB,baseline_reserved_bytes=MIB,
           final_reserved_bytes=2*MIB,trial_allowance_bytes=MIB,planned_trial_bytes=6*MIB,
           endpoint='https://speed.cloudflare.com',address='1.1.1.1',node='NRT',parallelism=4,
           policy='three-paired-upload-v1',timeout_seconds=10,total_timeout_seconds=60,
           duration_seconds=26,paired_throughput_ratios=[gain]*3,
           original_srtt_median_ms=10.,paired_srtt_delta_ms=rtt-10.,allowed_srtt_delta_ms=2.)
    for i,cc in enumerate([original,candidate,candidate,original,original,candidate]):
        duration=4*gain if cc==original else 4.
        upload=dict(request_sizes=[131072]*8,request_batches=[[131072]*4]*2,
                    payload_bytes=MIB,duration_seconds=duration,bits_per_second=MIB*8/duration,
                    quality='sampled',tcp_info=dict(supported=True,srtt_ms=10. if cc==original else rtt,
                    busy_time_seconds=3.2,connection_busy_seconds=[3.2,.1,.1,.1],total_retransmissions=0))
        r['trials'].append(dict(index=i+1,pair=i//2+1,algorithm=cc,congestion_algorithm=cc,
            reserved_bytes=MIB,report_file='algorithm-trial-%d.json'%(i+1),exit_code=0,
            endpoint=r['endpoint'],address=r['address'],node=r['node'],upload=upload,process_cpu_seconds=.1))
    return r
def run(label,data,accepted,body=program):
    path=root/(label+'.json');path.write_text(json.dumps(data))
    p=subprocess.run([sys.executable,'-','selected',str(path),str(data['budget_bytes']),'en'],
                     input=body,text=True,capture_output=True,timeout=3)
    assert (p.returncode==0)==accepted,(label,p.returncode,p.stdout,p.stderr)
    if accepted: assert p.stdout.strip()==(data['selected'] if data['status']=='selected' else ''),label
    return p
for original in ('cubic','bbr'):
    run('valid-'+original,fixture(original),True)
run('exact-gain-and-rtt-threshold',fixture(gain=1.1,rtt=12.),True)
run('lower-rtt',fixture(rtt=8.),True)
kept=fixture();kept.update(selected='cubic',status='preserved',reason_code='no_consistent_gain',reserved_bytes=0,trials=[])
run('preserved-no-trials',kept,True)
print('PASS: valid BBR/CUBIC decisions, exact thresholds, lower SRTT and inconclusive reports remain readable')

cases=[]
def change(label,apply):
    r=fixture();apply(r);cases.append((label,r))
change('all-original-trials',lambda r:[t.update(algorithm='cubic',congestion_algorithm='cubic') for t in r['trials']])
change('duplicate-pair',lambda r:r['trials'][2].update(pair=1))
change('duplicate-index',lambda r:r['trials'][2].update(index=1))
change('reused-raw-trial',lambda r:r['trials'][2].update(report_file='algorithm-trial-1.json'))
change('failed-trial',lambda r:r['trials'][1].update(exit_code=1))
change('wrong-readback',lambda r:r['trials'][1].update(congestion_algorithm='cubic'))
for field,value in [('endpoint','https://example.net'),('address','8.8.8.8'),('node','SJC')]:
    change('changed-'+field,lambda r,k=field,v=value:r['trials'][1].update({k:v}))
change('wrong-width',lambda r:r.update(parallelism=1))
def different_work(r):
    u=r['trials'][1]['upload'];u.update(request_sizes=[262144]+[131072]*6,
                                     request_batches=[[262144]+[131072]*3,[131072]*3])
change('different-common-work',different_work)
change('invalid-batch',lambda r:r['trials'][1]['upload'].update(request_batches=[[131072]*8]))
change('payload-mismatch',lambda r:r['trials'][1]['upload'].update(payload_bytes=MIB-1))
change('rate-mismatch',lambda r:r['trials'][1]['upload'].update(bits_per_second=1.))
change('missing-upload',lambda r:r['trials'][1].update(upload=None))
change('missing-tcp',lambda r:r['trials'][1]['upload'].update(tcp_info=None))
change('no-tcp-support',lambda r:r['trials'][1]['upload']['tcp_info'].update(supported=False))
change('missing-srtt',lambda r:r['trials'][1]['upload']['tcp_info'].pop('srtt_ms'))
change('short-active-time',lambda r:r['trials'][1]['upload']['tcp_info'].update(busy_time_seconds=2.9,connection_busy_seconds=[2.9,.1,.1,.1]))
change('overlapping-active-time',lambda r:r['trials'][1]['upload']['tcp_info'].update(busy_time_seconds=4.,connection_busy_seconds=[1.]*4))
change('impossible-active-time',lambda r:r['trials'][1]['upload']['tcp_info'].update(busy_time_seconds=40.,connection_busy_seconds=[40.,.1,.1,.1]))
change('invalid-retransmissions',lambda r:r['trials'][1]['upload']['tcp_info'].update(total_retransmissions=-1))
def slow_candidate(r):
    for t in r['trials']:
        if t['algorithm']==r['selected']:t['upload'].update(duration_seconds=6.,bits_per_second=MIB*8/6.)
change('claimed-gain-despite-real-loss',slow_candidate)
change('claimed-wrong-ratios',lambda r:r.update(paired_throughput_ratios=[2.]*3))
def bad_latency(r):
    for t in r['trials']:
        if t['algorithm']==r['selected']:t['upload']['tcp_info']['srtt_ms']=15.
change('hidden-latency-regression',bad_latency)
change('inflated-latency-allowance',lambda r:r.update(allowed_srtt_delta_ms=1000.))
change('wrong-baseline-rtt',lambda r:r.update(original_srtt_median_ms=1000.))
change('wrong-delta',lambda r:r.update(paired_srtt_delta_ms=-100.))
change('insufficient-post-budget',lambda r:r.update(budget_bytes=8*MIB))
change('false-reservation',lambda r:r['trials'][1].update(reserved_bytes=0))
change('float-reservation',lambda r:r.update(final_reserved_bytes=float(2*MIB)))
change('missing-reservation',lambda r:r.pop('trial_allowance_bytes'))
for label,r in cases:run(label,r,False)
print('PASS: %d malformed or contradictory selection reports fail before returning a candidate'%len(cases))

PY
