#!/usr/bin/env bash
set -Eeuo pipefail
[[ $(uname -s) == Linux && ${BASH_VERSINFO[0]} -ge 4 ]] || { printf 'Tests require Linux and Bash 4+.\n' >&2; exit 2; }
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
SOURCE_HASH="$(sha256sum "$SCRIPT" | awk '{print $1}')"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
require_auto() { declare -F auto_tune >/dev/null || fail 'auto_tune closed-loop entry point is missing'; }

# Production functions run unchanged except for their fixed write locations.
# The generated definitions are not statically visible to ShellCheck.
# shellcheck source=/dev/null
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
awk '/^log\(\)/ {p=1} /^# CLI entry point/ {exit} p {print}' "$SCRIPT" |
  sed "s@/etc/sysctl.d@$TMP/sysctl.d@g; s@/run/netpilot.lock@$TMP/operation.lock@g" > "$TMP/functions.sh"
# shellcheck source=/dev/null
source "$TMP/functions.sh"
# shellcheck source=/dev/null
source <(sed -n '/^main() {/,/^}/p' "$SCRIPT")
# Preserve the real verifier, adding only an observable call and fault injection.
# shellcheck source=/dev/null
source <(declare -f verify_tuning | sed '1s/verify_tuning/fixture_verify_tuning/')

# Runtime production functions consume these globals.
# shellcheck disable=SC2034
{
  declare -a SYSCTL_KEYS=()
  declare -A SYSCTL_TARGETS=()
  RED=''; GREEN=''; YELLOW=''; NC=''; NIC_IFACE=''
  SOURCE_PATH="$SCRIPT"; SOURCE_SNAPSHOT=''; SCRIPT_PATH=''; RESOLVED_SOURCE=''
  UPDATE_URL='https://github.com/luckiestultra/netpilot/raw/refs/heads/main/netpilot.sh'
  MSS_COMMENT=netpilot
  AUTO_DEFAULT_ENDPOINT='https://speed.cloudflare.com'
}

# Every path an extracted function can write belongs to one private test case.
# shellcheck disable=SC2034
setup_case() {
  CASE_DIR="$TMP/$1"; KERNEL_DIR="$CASE_DIR/kernel"
  STATE_DIR="$CASE_DIR/state"; BACKUP_DIR="$STATE_DIR/backup"
  SYSCTL_FILE="$CASE_DIR/sysctl.d/99-netpilot.conf"
  BBR_FILE="$CASE_DIR/sysctl.d/10-netpilot-bbr.conf"
  BBR_MODULE_FILE="$CASE_DIR/modules.conf"; LIMITS_FILE="$CASE_DIR/limits.conf"
  GAI_FILE="$CASE_DIR/gai.conf"
  INSTALL_PATH="$CASE_DIR/install/netpilot.sh"; SHORTCUT_PATH="$CASE_DIR/install/netpilot"
  AUTO_REPORT_ROOT="$CASE_DIR/reports"
  AUTO_SCENARIO=success; AUTO_SELECTION=preserved; VERIFY_FAILURE=0
  AUTO_EXPECT_CC=cubic; AUTO_EXPECT_QDISC=fq_codel
  export CASE_DIR KERNEL_DIR
  export FAIL_SYSCTL_KEY='' FAIL_SYSCTL_VALUE=1
  SYSCTL_KEYS=(); SYSCTL_TARGETS=()
  mkdir -p "$KERNEL_DIR" "$(dirname "$SYSCTL_FILE")"
  printf 'reno cubic bbr\n' > "$KERNEL_DIR/net.ipv4.tcp_available_congestion_control"
  printf 'cubic\n' > "$KERNEL_DIR/net.ipv4.tcp_congestion_control"
  printf 'fq_codel\n' > "$KERNEL_DIR/net.core.default_qdisc"
  printf '0\n' > "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf"
  printf '212992\n' > "$KERNEL_DIR/net.core.rmem_max"
  printf '212992\n' > "$KERNEL_DIR/net.core.wmem_max"
  printf '4096 131072 6291456\n' > "$KERNEL_DIR/net.ipv4.tcp_rmem"
  printf '4096 16384 4194304\n' > "$KERNEL_DIR/net.ipv4.tcp_wmem"
  printf '0\n' > "$KERNEL_DIR/net.ipv4.tcp_ecn"
  cp -a "$KERNEL_DIR" "$CASE_DIR/original-kernel"
  printf '# Managed by netpilot.sh.\nnet.ipv4.tcp_ecn = 0\n' > "$SYSCTL_FILE"
  cp "$SYSCTL_FILE" "$CASE_DIR/original.conf"
  printf '# Original address selection\n' > "$GAI_FILE"
  : > "$CASE_DIR/prompts"; : > "$CASE_DIR/writes"; : > "$CASE_DIR/trace"
  : > "$CASE_DIR/verify-calls"
  mkdir "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/sysctl" <<'SYSCTL'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  -n) [[ $# == 2 && -f "$KERNEL_DIR/$2" ]] || exit 1; cat "$KERNEL_DIR/$2" ;;
  -w)
    [[ $# == 2 && "$2" == *=* ]] || exit 1
    key="${2%%=*}"; value="${2#*=}"
    [[ "$key" =~ ^net\.[a-zA-Z0-9_.]+$ && -f "$KERNEL_DIR/$key" ]] || exit 1
    printf '%s\n' "$2" >> "$CASE_DIR/writes"
    printf 'write\t%s\n' "$key" >> "$CASE_DIR/trace"
    [[ "$key" != "$FAIL_SYSCTL_KEY" || "$value" != "$FAIL_SYSCTL_VALUE" ]] || exit 1
    printf '%s\n' "$value" > "$KERNEL_DIR/$key"
    printf '%s = %s\n' "$key" "$value" ;;
  *) exit 1 ;;
esac
SYSCTL
  chmod 0755 "$CASE_DIR/bin/sysctl"
  export PATH="$CASE_DIR/bin:$PATH"
  np_set_language en
}

adaptive_physical_memory_bytes() { printf '2147483648\n'; }
adaptive_cgroup_values() { return 0; }

# Bash application and Python restoration share one observable kernel boundary.
sysctl() {
  "$CASE_DIR/bin/sysctl" "$@"
}

verify_tuning() {
  printf 'verify\n' >> "$CASE_DIR/trace"
  printf 'called\n' >> "$CASE_DIR/verify-calls"
  (( VERIFY_FAILURE == 0 )) || return 1
  fixture_verify_tuning "$@"
}

# Record actual terminal prompts while preserving Bash's real input handling.
read() {
  local n next
  for ((n=1;n<=$#;n++)); do
    if [[ "${!n}" == -p ]]; then next=$((n+1)); printf '%s\n' "${!next}" >> "$CASE_DIR/prompts"; fi
  done
  builtin read "$@"
}

# Test doubles stop at measurement and algorithm-selection boundaries. Reports
# contain measured data; all planning, backup, application and restoration run
# the production implementations sourced above.
http_measure_path() {
  local phase="$1" endpoint="$2" budget="$3" seconds="$4" output="$5" before="${6:-}"
  printf 'probe\t%s\t%s\t%s\t%s\t%s\t%s\n' "$phase" "$endpoint" "$budget" "$seconds" "$output" "$before" >> "$CASE_DIR/trace"
  if [[ "$phase" == before ]]; then
    [[ ! -s "$CASE_DIR/writes" ]] || fail 'configuration changed before the baseline was measured'
  else
    [[ -n "$before" && -f "$before" ]] || fail 'post-test did not receive its baseline report'
    [[ -s "$CASE_DIR/verify-calls" || ! -s "$CASE_DIR/writes" ]] || fail 'post-test started before configuration verification'
  fi
  python3 - "$phase" "$endpoint" "$budget" "$seconds" "$output" "$AUTO_SCENARIO" <<'PY' || return 1
import json, math, os, sys
phase, endpoint, budget, seconds, output, scenario = sys.argv[1:]
budget, seconds = int(budget), int(seconds)
failed = (phase == 'before' and scenario in ('before_failure','cancel_before')) or (phase == 'after' and scenario in ('after_failure','cancel_after'))
down, up, latency = (80e6, 40e6, 50.0) if phase == 'before' else (100e6, 50e6, 40.0)
if phase == 'after' and scenario in ('regression','transient_regression'):
    if scenario == 'regression' or not output.endswith('confirmation.json'):
        down, up, latency = 40e6, 20e6, 70.0
if scenario == 'short_sample': down, up = 400e6, 100e6
if scenario == 'short_download': down = 400e6
if scenario == 'short_upload': up = 400e6
address, node = '1.1.1.1', 'NRT'
size = min(budget // 4, 32 * 1048576)
if scenario == 'baseline_budget_high': size = budget // 2
report = dict(type='netpilot-http-measurement', version=1, ok=not failed,
              phase=phase, endpoint=endpoint, address=address, port=443,
              node=node, family='IPv4', node_verified=True,
              measurement_policy='parallel-http-v1', parallelism=4, connection_policy='pinned-parallel',
              budget_mode='auto' if budget > 512 * 1048576 else 'fixed',
              latency_ms=latency, latency_method='tcp-connect-estimate',
              download_bps=down, upload_bps=up, budget_bytes=budget,
              reserved_bytes=size * 2, timeout_seconds=seconds)
sizes = [min(4 * 1048576, size - offset) for offset in range(0, size, 4 * 1048576)]
for direction, rate in [('download', down), ('upload', up)]:
    report[direction] = dict(request_sizes=sizes, request_batches=[sizes[i:i+4] for i in range(0, len(sizes), 4)], payload_bytes=size,
                             duration_seconds=size*8/rate, bits_per_second=rate,
                             quality='sampled' if size*8/rate >= 3 else 'budget-limited')
if failed: report['error'] = 'fixture measurement failure'
if phase == 'before' and scenario == 'bad_rate': report['download_bps'] = float('nan')
if phase == 'before' and scenario == 'zero_latency': report['latency_ms'] = 0
if phase == 'before' and scenario == 'over_budget': report['reserved_bytes'] = budget + 1
if phase == 'after' and scenario == 'node_change': report['node'] = 'SIN'
if phase == 'after' and scenario == 'address_change': report['address'] = '1.0.0.1'
if phase == 'after' and scenario == 'sizes_change': report['download']['request_sizes'] = [size//2, size-size//2]
fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as stream:
    if phase == 'before' and scenario == 'bad_json': stream.write('not valid JSON\n')
    else: json.dump(report, stream)
PY
  if [[ "$AUTO_SCENARIO" == cancel_before && "$phase" == before || "$AUTO_SCENARIO" == cancel_after && "$phase" == after ]]; then
    kill -INT "$BASHPID"
    return 130
  fi
  [[ "$AUTO_SCENARIO" != before_failure || "$phase" != before ]] || return 1
  [[ "$AUTO_SCENARIO" != after_failure || "$phase" != after ]] || return 1
}

http_select_congestion() {
  local before="$1" endpoint="$2" total="$3" seconds="$4" directory="$5" original="$6"
  [[ "$(sysctl_value net.ipv4.tcp_congestion_control)" == "$original" ]] || fail 'selection began after a global algorithm change'
  [[ ! -s "$CASE_DIR/writes" ]] || fail 'configuration changed before algorithm comparison'
  printf 'selection\t%s\n' "$original" >> "$CASE_DIR/trace"
  [[ "$AUTO_SELECTION" != missing ]] || return 1
  python3 - "$before" "$endpoint" "$total" "$seconds" "$directory" "$original" "$AUTO_SELECTION" <<'PY' || return 1
import json,os,pathlib,sys
before,endpoint,total,seconds,directory,original,mode=sys.argv[1:]
b=json.loads(pathlib.Path(before).read_text()); root=pathlib.Path(directory)
assert endpoint==b['endpoint'] and int(seconds)==b['timeout_seconds']
allowance=2*b['upload']['payload_bytes']; candidate='bbr' if original=='cubic' else 'cubic'
r=dict(type='netpilot-algorithm-selection',version=1,original=original,selected=original,
       status='preserved',reason_code='no_consistent_gain',reserved_bytes=0,trials=[],
       timeout_seconds=int(seconds),total_timeout_seconds=6*int(seconds),duration_seconds=.1,
       budget_bytes=int(total),baseline_reserved_bytes=b['reserved_bytes'],
       final_reserved_bytes=2*b['reserved_bytes'],trial_allowance_bytes=allowance,
       planned_trial_bytes=6*allowance,endpoint=endpoint,address=b['address'],node=b['node'],
       parallelism=4,policy='three-paired-upload-v1',candidate=candidate)
if mode=='selected':
    assert 6*allowance<=int(total)-3*b['reserved_bytes']
    for i,cc in enumerate([original,candidate,candidate,original,original,candidate]):
        duration=4.8 if cc==original else 4.0
        upload=dict(request_sizes=b['upload']['request_sizes']*2,
                    request_batches=b['upload']['request_batches']*2,payload_bytes=allowance,
                    duration_seconds=duration,bits_per_second=allowance*8/duration,quality='sampled',
                    tcp_info=dict(supported=True,srtt_ms=1. if cc==original else 1.1,
                                  busy_time_seconds=3.2,connection_busy_seconds=[3.2,.1,.1,.1],
                                  total_retransmissions=0))
        r['trials'].append(dict(index=i+1,pair=i//2+1,algorithm=cc,reserved_bytes=allowance,
            report_file='algorithm-trial-%d.json'%(i+1),exit_code=0,upload=upload,
            process_cpu_seconds=.1,endpoint=endpoint,address=b['address'],node=b['node'],congestion_algorithm=cc))
    r.update(selected=candidate,status='selected',reason_code='consistent_gain',reserved_bytes=6*allowance,
             paired_throughput_ratios=[1.2]*3,paired_srtt_delta_ms=.1,
             original_srtt_median_ms=1.,allowed_srtt_delta_ms=1.)
target=root/'algorithm.json'
fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as stream:json.dump(r,stream)
PY
  if [[ "$AUTO_SCENARIO" == drift_sysctl ]]; then
    printf '1\n' > "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf"
  elif [[ "$AUTO_SCENARIO" == drift_file ]]; then
    printf '# Managed by netpilot.sh.\n# External administrator update\nnet.ipv4.tcp_ecn = 0\n' > "$SYSCTL_FILE"
  fi
  if [[ "$AUTO_SELECTION" == cancel ]]; then kill -INT "$BASHPID"; return 130; fi
  [[ "$(sysctl_value net.ipv4.tcp_congestion_control)" == "$original" ]] || fail 'candidate comparison changed the global algorithm'
}

network_interfaces() { fail 'automatic tuning adjusted unrelated NIC hardware'; }
modprobe() { fail 'automatic tuning loaded a kernel module'; }
iptables() { fail 'automatic tuning changed firewall rules'; }
curl() { fail 'transport-boundary tests unexpectedly invoked curl'; }

summary_file() {
  python3 - "$AUTO_REPORT_ROOT" <<'PY' || return 1
from pathlib import Path
import sys
files=list(Path(sys.argv[1]).rglob('summary.json'))
assert len(files)==1, ('expected one automatic summary',files)
print(files[0])
PY
}

assert_no_changes() {
  [[ ! -e "$STATE_DIR" && ! -s "$CASE_DIR/writes" ]] || fail 'failed preflight or measurement created tuning state'
  diff -r "$KERNEL_DIR" "$CASE_DIR/original-kernel" > "$CASE_DIR/kernel-diff" || fail 'failed preflight or measurement modified kernel values'
  cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'failed preflight or measurement modified configuration'
}

assert_basic_applied() {
  [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_congestion_control")" == "$AUTO_EXPECT_CC" ]] || fail 'application did not respect the selected or retained algorithm'
  [[ "$(cat "$KERNEL_DIR/net.core.default_qdisc")" == "$AUTO_EXPECT_QDISC" ]] || fail 'application changed the queue without selecting BBR'
  [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf")" == 1 ]] || fail 'basic plan did not enable receive-buffer autotuning'
  [[ -f "$STATE_DIR/original-values" && -f "$BACKUP_DIR/sysctl-file" ]] || fail 'automatic application omitted original state or configuration backup'
  cmp -s "$BACKUP_DIR/sysctl-file" "$CASE_DIR/original.conf" || fail 'automatic application did not preserve the original file'
  [[ -s "$STATE_DIR/original-values" ]] || fail 'changed kernel values have no first-ever baseline'
  if [[ "$AUTO_SELECTION" == selected ]]; then
    grep -qx "net.ipv4.tcp_congestion_control=$(cat "$CASE_DIR/original-kernel/net.ipv4.tcp_congestion_control")" "$STATE_DIR/original-values" || fail 'selected algorithm lost the first-ever original value'
  fi
  fixture_verify_tuning > "$CASE_DIR/final-verify" || fail 'automatic application is inconsistent with its saved values'
}

assert_applied() {
  assert_basic_applied
  [[ "$(cat "$KERNEL_DIR/net.core.rmem_max")" -gt 212992 ]] || fail 'measured bandwidth and latency did not affect buffer planning'
}

assert_restored() {
  diff -r "$KERNEL_DIR" "$CASE_DIR/original-kernel" > "$CASE_DIR/kernel-diff" || fail 'rollback did not restore the original kernel values'
  cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'rollback did not restore the original file'
  [[ ! -e "$STATE_DIR" ]] || fail 'successful recovery retained its state'
}

assert_run_restored() {
  diff -r "$KERNEL_DIR" "$CASE_DIR/original-kernel" > "$CASE_DIR/kernel-diff" || fail 'automatic recovery did not restore this run kernel values'
  cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'automatic recovery did not restore this run file bytes'
  [[ -f "$STATE_DIR/original-values" && -f "$BACKUP_DIR/sysctl-file" ]] || fail 'automatic recovery deleted first-ever backup state'
  cmp -s "$BACKUP_DIR/sysctl-file" "$CASE_DIR/original.conf" || fail 'automatic recovery altered first-ever file backup'
}

assert_completed_report() {
  local summary
  summary="$(summary_file)" || fail 'automatic summary was not generated'
  python3 - "$summary" "$CASE_DIR/trace" "$CASE_DIR/writes" <<'PY' || return 1
from pathlib import Path
import json, math, os, stat, sys
path=Path(sys.argv[1]); data=json.loads(path.read_text())
assert data['type']=='netpilot-tune-report' and data['version']==1, data
assert isinstance(data.get('stage'),str) and data['stage'], data
assert data['status']=='completed' and data['changed'] is True, data
assert data['applied'] is True and data['verified'] is True, data
before=json.loads(path.with_name('before.json').read_text())
after=json.loads(path.with_name('after.json').read_text())
assert before['ok'] is True and after['ok'] is True
assert data['budget_bytes']==16*1024**3 and data['budget_mode']=='auto', data
assert before['reserved_bytes']+after['reserved_bytes']<=data['budget_bytes']
assert before['budget_mode']==after['budget_mode']=='auto'
assert before['reserved_bytes']+after['reserved_bytes']==128*1048576
algorithm=json.loads(path.with_name('algorithm.json').read_text())
assert data['algorithm']==algorithm and data['restoration_scope']=='run',data
assert data['accounted_bytes']==before['reserved_bytes']+after['reserved_bytes']+algorithm['reserved_bytes'],data
assert data['accounting_conservative'] is False,data
comparison=data['comparison']
def field(primary, alternative):
    return comparison.get(primary,comparison.get(alternative))
assert math.isclose(field('download_change_pct','download_percent'),25.0),comparison
assert math.isclose(field('upload_change_pct','upload_percent'),25.0),comparison
assert math.isclose(comparison['latency_delta_ms'],-10.0),comparison
lines=Path(sys.argv[2]).read_text().splitlines()
probes=[line.split('\t') for line in lines if line.startswith('probe\t')]
assert [p[1] for p in probes]==['before','after'],probes
assert probes[0][2]==probes[1][2]=='https://speed.cloudflare.com',probes
assert int(probes[0][3])==int(probes[1][3])==8*1024**3,probes
assert probes[0][4]==probes[1][4]=='30',probes
assert Path(probes[1][6])==path.with_name('before.json'),probes
selection=next(i for i,line in enumerate(lines) if line.startswith('selection\t'))
assert lines.index(next(x for x in lines if x.startswith('probe\tbefore'))) < selection
assert selection < lines.index(next(x for x in lines if x.startswith('write\t'))),lines
assert lines.index(next(x for x in lines if x.startswith('write\t')))<lines.index('verify')<lines.index(next(x for x in lines if x.startswith('probe\tafter'))),lines
assert stat.S_IMODE(path.parent.stat().st_mode)==0o700
for report in path.parent.rglob('*.json'):
    assert stat.S_IMODE(report.stat().st_mode)==0o600,(report,oct(report.stat().st_mode))
PY
}

test_manual_fixture_and_rollback() (
  setup_case manual
  apply_tuning --profile proxy --bandwidth 400 --rtt 50 --yes > "$CASE_DIR/output" 2>&1 || fail 'manual fixture cannot apply a real plan'
  assert_applied
  run_mutation rollback_tuning > "$CASE_DIR/rollback" 2>&1 || fail 'manual fixture cannot roll back'
  assert_restored
)

test_automatic_command_and_bilingual_menu() (
  require_auto
  local mode
  for mode in command explicit-auto zh en; do
    setup_case "$mode"
    if [[ "$mode" == command || "$mode" == explicit-auto ]]; then
      if [[ "$mode" == explicit-auto ]]; then
        main --lang en tune --budget-mib auto < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'explicit automatic budget failed'
      else
        main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'automatic command required input or failed'
      fi
      [[ ! -s "$CASE_DIR/prompts" ]] || fail 'automatic command prompted for numbers or reports'
    else
      np_set_language "$mode"
      menu < <(printf '9\n0\n') > "$CASE_DIR/output" 2>&1 || fail 'menu automatic workflow failed'
      [[ "$(wc -l < "$CASE_DIR/prompts")" == 2 ]] || fail 'automatic menu requested more than choice and exit'
    fi
    python3 - "$PLAN_BANDWIDTH" "$PLAN_RTT" <<'PY' || return 1
import math,sys
assert math.isclose(float(sys.argv[1]),80.0)
assert math.isclose(float(sys.argv[2]),50.0)
PY
    assert_applied
    assert_completed_report
    grep -Eiq '实测|自动测|measur' "$CASE_DIR/output" || fail 'automatic plan omitted its measured-data provenance'
    ! grep -Eq '用户输入|user input' "$CASE_DIR/output" || fail 'automatic plan mislabels measured values as user input'
    run_mutation rollback_tuning > "$CASE_DIR/rollback" 2>&1 || fail 'automatic changes cannot be rolled back'
    assert_restored
  done
)

test_short_samples_keep_buffers_and_apply_basic_tuning() (
  require_auto
  local scenario lang key before plan
  for scenario in short_sample short_download short_upload; do
    for lang in zh en; do
      setup_case "$scenario-$lang"; AUTO_SCENARIO="$scenario"
      main --lang "$lang" tune < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'short samples prevented basic automatic tuning'
      [[ -z "$PLAN_BANDWIDTH" && -z "$PLAN_RTT" ]] || fail 'short measurements were used as path data for buffer planning'
      assert_basic_applied
      for key in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
        cmp -s "$KERNEL_DIR/$key" "$CASE_DIR/original-kernel/$key" || fail "short samples changed an existing buffer: $key"
      done
      before="$(summary_file)"; before="${before%/*}/before.json"
      plan="$(auto_report plan "$before" "$AUTO_DEFAULT_ENDPOINT" 8589934592 30)" || fail 'valid short samples were treated as invalid measurements'
      [[ -z "$plan" ]] || fail 'report planner returned path values from a short sample'
      grep -Eiq 'short|budget-limited|样本|预算受限' "$CASE_DIR/output" || fail 'short sample reason was omitted'
      grep -Eiq 'buffers|缓冲' "$CASE_DIR/output" || fail 'preserved buffers were not explained'
      python3 - "$(summary_file)" <<'PY' || return 1
import json, sys
d=json.load(open(sys.argv[1]))
assert d['status']=='completed' and d['changed'] and d['applied'] and d['verified'],d
assert d['comparison']['budget_limited'] is True,d
assert any(d['before'][direction]['quality']=='budget-limited' for direction in ('download','upload')),d
PY
      run_mutation rollback_tuning > "$CASE_DIR/rollback" 2>&1 || fail 'basic short-sample tuning cannot be rolled back'
      assert_restored
    done
  done
)

test_automatic_options_and_budget() (
  require_auto
  setup_case options
  [[ "$(auto_report endpoint 'HTTPS://LOCALHOST:443/')" == 'https://localhost:443' ]] || fail 'custom endpoint normalization changed its identity'
  main --lang en tune --profile proxy --budget-mib 3 --timeout 8 < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'valid automatic options failed'
  [[ "$PLAN_PROFILE" == proxy ]] || fail 'automatic profile selection was ignored'
  python3 - "$(summary_file)" "$CASE_DIR/trace" <<'PY' || return 1
from pathlib import Path
import json,sys
summary=json.loads(Path(sys.argv[1]).read_text())
probes=[s.split('\t')for s in Path(sys.argv[2]).read_text().splitlines()if s.startswith('probe\t')]
assert len(probes)==2 and sum(int(x[3])for x in probes)==3*1048576,probes
assert all(x[4]=='8' for x in probes),probes
assert summary['budget_bytes']==3*1048576 and summary['budget_mode']=='fixed'
PY
)

test_invalid_options_are_zero_traffic() (
  require_auto
  local variant status
  local -a args=()
  for variant in profile small-budget large-budget low-time high-time endpoint-port endpoint-user manual unknown; do
    setup_case "invalid-$variant"
    case "$variant" in
      profile) args=(--profile invalid) ;;
      small-budget) args=(--budget-mib 0) ;;
      large-budget) args=(--budget-mib 1025) ;;
      low-time) args=(--timeout 4) ;;
      high-time) args=(--timeout 121) ;;
      endpoint-port) args=(--endpoint https://example.net:0) ;;
      endpoint-user) args=(--endpoint https://user@localhost) ;;
      manual) args=(--bandwidth 100 --rtt 50) ;;
      unknown) args=(--unknown) ;;
    esac
    status=0
    main --lang en tune "${args[@]}" < /dev/null > "$CASE_DIR/output" 2>&1 || status=$?
    [[ "$status" != 0 ]] || fail "invalid automatic options accepted: $variant"
    [[ ! -s "$CASE_DIR/trace" && ! -s "$CASE_DIR/prompts" ]] || fail 'invalid options started a probe or requested input'
    assert_no_changes
  done
)

test_baseline_failures_never_apply() (
  require_auto
  local scenario
  for scenario in before_failure bad_json bad_rate zero_latency over_budget; do
    setup_case "$scenario"; AUTO_SCENARIO="$scenario"
    if main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1; then fail "bad baseline was accepted: $scenario"; fi
    [[ "$(grep -c '^probe' "$CASE_DIR/trace")" == 1 ]] || fail 'failed baseline was retried or followed by a post-test'
    assert_no_changes
    python3 - "$(summary_file)" <<'PY' || return 1
import json,sys
d=json.load(open(sys.argv[1]))
assert d['status']=='failed' and d['applied'] is False,d
PY
  done
)

test_application_and_verification_failures_restore() (
  require_auto
  local mode
  for mode in apply verify; do
    setup_case "failure-$mode"
    if [[ "$mode" == apply ]]; then FAIL_SYSCTL_KEY=net.ipv4.tcp_moderate_rcvbuf
    else VERIFY_FAILURE=1; fi
    if main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1; then fail "$mode failure reported completion"; fi
    [[ "$(grep -c '^probe' "$CASE_DIR/trace")" == 1 ]] || fail 'failed configuration was measured as if it had succeeded'
    [[ -s "$CASE_DIR/writes" ]] || fail 'failure test did not reach a real partial application'
    assert_run_restored
    python3 - "$(summary_file)" "$mode" <<'PY' || return 1
import json,sys
d=json.load(open(sys.argv[1]));assert d['status']=='failed',d
if sys.argv[2]=='apply':
    assert d.get('rollback_status')=='completed',d
    assert d.get('configuration_state')=='restored',d
PY
  done
)

test_post_failures_restore_current_run() (
  require_auto
  local scenario
  for scenario in after_failure node_change address_change sizes_change; do
    setup_case "$scenario"; AUTO_SCENARIO="$scenario"
    if main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1; then fail "invalid post-test produced a successful comparison: $scenario"; fi
    [[ "$(grep -c '^probe' "$CASE_DIR/trace")" == 2 ]] || fail 'post-test failure caused a fresh budget or retry'
    assert_run_restored
    python3 - "$(summary_file)" <<'PY' || return 1
import json,sys
d=json.load(open(sys.argv[1]))
assert d['status']=='failed' and d['stage']=='after',d
assert d['applied'] is False and d['verified'] is False,d
assert d['rollback_status']=='completed' and d['configuration_state']=='restored',d
assert not d.get('comparison'),d
PY
  done
)

test_no_change_still_compares() (
  require_auto
  setup_case noop
  printf 'bbr\n' > "$KERNEL_DIR/net.ipv4.tcp_congestion_control"
  printf 'fq\n' > "$KERNEL_DIR/net.core.default_qdisc"
  printf '1\n' > "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf"
  printf '134217728\n' > "$KERNEL_DIR/net.core.rmem_max"
  printf '134217728\n' > "$KERNEL_DIR/net.core.wmem_max"
  printf '4096 131072 134217728\n' > "$KERNEL_DIR/net.ipv4.tcp_rmem"
  printf '4096 16384 134217728\n' > "$KERNEL_DIR/net.ipv4.tcp_wmem"
  AUTO_SCENARIO=regression
  main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'no-change automatic workflow failed'
  [[ ! -s "$CASE_DIR/writes" && ! -e "$STATE_DIR" ]] || fail 'no-change automatic workflow forced writes'
  [[ "$(grep -c '^probe' "$CASE_DIR/trace")" == 2 ]] || fail 'no-change workflow omitted automatic comparison'
  python3 - "$(summary_file)" <<'PY' || return 1
import json,sys
d=json.load(open(sys.argv[1]))
assert d['status']=='completed' and d['changed'] is False and d.get('comparison'),d
assert d['rollback_status']=='not-needed' and d['comparison']['causal_claim'] is False,d
PY
)

test_confirmed_regression_restores_current_run() (
  require_auto
  setup_case regression; AUTO_SCENARIO=regression
  if main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1; then fail 'confirmed throughput loss was reported as success'; fi
  [[ "$(grep -c '^probe' "$CASE_DIR/trace")" == 3 ]] || fail 'regression did not receive exactly one confirmation'
  assert_run_restored
  python3 - "$(summary_file)" <<'PY' || return 1
import json,math,pathlib,sys
p=pathlib.Path(sys.argv[1]);d=json.loads(p.read_text());c=d['comparison']
assert d['status']=='failed' and d['stage']=='confirm' and d['changed'] is True,d
assert d['rollback_status']=='completed' and d['configuration_state']=='restored',d
assert math.isclose(c.get('download_change_pct',c.get('download_percent')),-50.0),c
assert math.isclose(c.get('upload_change_pct',c.get('upload_percent')),-50.0),c
assert math.isclose(c['latency_delta_ms'],20.0),c
assert d['confirmation']['ok'] and d['confirmation_comparison']==c,d
assert d['accounted_bytes']==sum(json.loads((p.parent/name).read_text())['reserved_bytes'] for name in ('before.json','after.json','confirmation.json')),d
PY
)

test_transient_regression_is_confirmed_only_once() (
  setup_case transient-regression; AUTO_SCENARIO=transient_regression
  main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'a recovered confirmation was treated as a confirmed regression'
  [[ "$(grep -c '^probe' "$CASE_DIR/trace")" == 3 ]] || fail 'transient regression received the wrong number of confirmations'
  assert_applied
  python3 - "$(summary_file)" <<'PY' || return 1
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);d=json.loads(p.read_text())
assert d['status']=='completed' and d['rollback_status']=='not-needed',d
assert (p.parent/'confirmation.json').is_file()
assert d['confirmation']['ok'] and d['confirmation_comparison']['download_change_pct']>0,d
assert d['comparison']['causal_claim'] is False,d
PY
)

seed_previous_tuning() {
  local path key
  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
  : > "$STATE_DIR/original-values"
  for path in "$CASE_DIR/original-kernel/"*; do
    key="${path##*/}"
    case "$key" in net.ipv4.tcp_available_congestion_control|net.ipv4.tcp_ecn) continue ;; esac
    printf '%s=%s\n' "$key" "$(cat "$path")" >> "$STATE_DIR/original-values"
  done
  chmod 0600 "$STATE_DIR/original-values"
  cp "$SYSCTL_FILE" "$BACKUP_DIR/sysctl-file"
  printf 'bbr\n' > "$KERNEL_DIR/net.ipv4.tcp_congestion_control"
  printf 'fq\n' > "$KERNEL_DIR/net.core.default_qdisc"
  printf '# Managed by netpilot.sh.\nnet.ipv4.tcp_ecn = 0\nnet.ipv4.tcp_congestion_control = bbr\nnet.core.default_qdisc = fq\n' > "$SYSCTL_FILE"
  cp -a "$KERNEL_DIR" "$CASE_DIR/previous-kernel"
  cp -a "$STATE_DIR" "$CASE_DIR/previous-state"
  cp "$SYSCTL_FILE" "$CASE_DIR/previous.conf"
}

test_existing_tuning_restores_this_run_not_first_backup() (
  local scenario
  for scenario in after_failure cancel_after; do
    setup_case "previous-$scenario"; seed_previous_tuning; AUTO_SCENARIO="$scenario"
    if main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1; then fail "failed repeat run reported completion: $scenario"; fi
    [[ -s "$CASE_DIR/writes" ]] || fail 'repeat-run recovery case never applied a new parameter'
    diff -r "$KERNEL_DIR" "$CASE_DIR/previous-kernel" > "$CASE_DIR/previous-kernel.diff" || fail 'repeat-run recovery restored the first algorithm instead of current BBR'
    cmp -s "$SYSCTL_FILE" "$CASE_DIR/previous.conf" || fail 'repeat-run recovery lost current managed file bytes'
    cmp -s "$STATE_DIR/original-values" "$CASE_DIR/previous-state/original-values" || fail 'repeat-run recovery changed the first-ever original values'
    cmp -s "$BACKUP_DIR/sysctl-file" "$CASE_DIR/previous-state/backup/sysctl-file" || fail 'repeat-run recovery changed the first-ever file backup'
    [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_congestion_control")" == bbr ]] || fail 'repeat-run recovery reverted current BBR to first-ever CUBIC'
    python3 - "$(summary_file)" <<'PY' || return 1
import json,sys
d=json.load(open(sys.argv[1]))
assert d['status'] in ('failed','cancelled') and d['rollback_status']=='completed',d
assert d['configuration_state']=='restored' and d['changed'] is True and d['applied'] is False,d
PY
  done
)

test_preapply_external_drift_stops_without_overwrite() (
  local mode
  for mode in sysctl file; do
    setup_case "external-drift-$mode"; AUTO_SCENARIO="drift_$mode"
    if main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1; then fail 'external drift was silently overwritten'; fi
    [[ ! -s "$CASE_DIR/writes" && ! -e "$STATE_DIR" ]] || fail 'preapply drift still reached application or recovery'
    [[ "$(grep -c '^probe' "$CASE_DIR/trace")" == 1 ]] || fail 'drift triggered a post-test'
    if [[ "$mode" == sysctl ]]; then
      [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf")" == 1 ]] || fail 'preapply drift restored over an external sysctl change'
      cmp -s "$SYSCTL_FILE" "$CASE_DIR/original.conf" || fail 'sysctl drift unexpectedly altered the managed file'
    else
      grep -qx '# External administrator update' "$SYSCTL_FILE" || fail 'preapply drift overwrote an external file update'
      diff -r "$KERNEL_DIR" "$CASE_DIR/original-kernel" > "$CASE_DIR/drift-kernel.diff" || fail 'file drift unexpectedly altered a kernel parameter'
    fi
    python3 - "$(summary_file)" <<'PY' || return 1
import json,sys
d=json.load(open(sys.argv[1]))
assert d['status']=='failed' and d['changed'] is False and d['rollback_status']=='not-needed',d
PY
  done
)

test_selected_candidate_applies_only_after_comparison() (
  local original
  for original in cubic bbr; do
    setup_case "selected-candidate-$original"; AUTO_SELECTION=selected
    printf '%s\n' "$original" > "$KERNEL_DIR/net.ipv4.tcp_congestion_control"
    cp "$KERNEL_DIR/net.ipv4.tcp_congestion_control" "$CASE_DIR/original-kernel/net.ipv4.tcp_congestion_control"
    if [[ "$original" == cubic ]]; then AUTO_EXPECT_CC=bbr; AUTO_EXPECT_QDISC=fq
    else AUTO_EXPECT_CC=cubic; AUTO_EXPECT_QDISC=fq_codel; fi
    main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'valid candidate evidence could not reach application'
    assert_applied
    assert_completed_report
    python3 - "$(summary_file)" "$CASE_DIR/trace" "$original" "$AUTO_EXPECT_CC" <<'PY' || return 1
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);a=json.loads((p.parent/'algorithm.json').read_text())
assert a['status']=='selected' and a['original']==sys.argv[3] and a['selected']==sys.argv[4],a
assert len(a['trials'])==6 and a['reserved_bytes']==sum(t['reserved_bytes'] for t in a['trials']),a
lines=pathlib.Path(sys.argv[2]).read_text().splitlines()
assert lines.index('selection\t'+sys.argv[3]) < lines.index('write\tnet.ipv4.tcp_congestion_control'),lines
PY
  done
)

test_retained_bbr_preserves_existing_queue() (
  setup_case retained-bbr-queue
  AUTO_EXPECT_CC=bbr
  printf 'bbr\n' > "$KERNEL_DIR/net.ipv4.tcp_congestion_control"
  main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1 || fail 'inconclusive comparison of current BBR failed'
  assert_applied
  ! grep -q '^net.ipv4.tcp_congestion_control=\|^net.core.default_qdisc=' "$CASE_DIR/writes" || fail 'retaining BBR rewrote the algorithm or forced default FQ'
)

test_missing_algorithm_report_cannot_reach_application() (
  setup_case missing-selection; AUTO_SELECTION=missing
  if main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1; then fail 'missing selector report became a preserved-success decision'; fi
  [[ "$(grep -c '^probe' "$CASE_DIR/trace")" == 1 ]] || fail 'missing selector report reached a post-test'
  assert_no_changes
  python3 - "$(summary_file)" <<'PY' || return 1
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);d=json.loads(p.read_text())
assert d['status']=='failed' and d['stage']=='selection' and not d['changed'],d
b=json.loads((p.parent/'before.json').read_text())
assert d['accounting_conservative'] is True and d['algorithm'] is None,d
assert d['accounted_bytes']==b['reserved_bytes']+12*b['upload']['payload_bytes'],d
PY
)

test_repeated_runs_preserve_reports_and_first_backup() (
  require_auto
  setup_case repeated
  main --lang en tune < /dev/null > "$CASE_DIR/first-output" 2>&1 || fail 'first automatic run failed'
  local first_report first_hash original_hash backup_hash
  first_report="$(summary_file)"
  first_hash="$(sha256sum "$first_report" | awk '{print $1}')"
  original_hash="$(sha256sum "$STATE_DIR/original-values" | awk '{print $1}')"
  backup_hash="$(sha256sum "$BACKUP_DIR/sysctl-file" | awk '{print $1}')"
  : > "$CASE_DIR/writes"; : > "$CASE_DIR/trace"; : > "$CASE_DIR/verify-calls"
  main --lang en tune < /dev/null > "$CASE_DIR/second-output" 2>&1 || fail 'repeat automatic run failed'
  [[ "$(sha256sum "$first_report" | awk '{print $1}')" == "$first_hash" ]] || fail 'repeat run overwrote its previous report'
  [[ "$(sha256sum "$STATE_DIR/original-values" | awk '{print $1}')" == "$original_hash" ]] || fail 'repeat run replaced the original parameter baseline'
  [[ "$(sha256sum "$BACKUP_DIR/sysctl-file" | awk '{print $1}')" == "$backup_hash" ]] || fail 'repeat run replaced its first configuration backup'
  python3 - "$AUTO_REPORT_ROOT" <<'PY' || return 1
from pathlib import Path
import json,sys
reports=list(Path(sys.argv[1]).rglob('summary.json'))
assert len(reports)==2 and reports[0].parent!=reports[1].parent,reports
assert all(json.loads(p.read_text())['status']=='completed' for p in reports)
PY
)

test_report_paths_preserve_existing_data() (
  require_auto
  local kind
  for kind in file symlink; do
    setup_case "reports-$kind"
    mkdir "$CASE_DIR/unrelated"
    printf 'preserve this file\n' > "$CASE_DIR/unrelated/keep"
    if [[ "$kind" == file ]]; then printf 'occupied\n' > "$AUTO_REPORT_ROOT"
    else ln -s "$CASE_DIR/unrelated" "$AUTO_REPORT_ROOT"; fi
    if main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1; then fail 'occupied report path was accepted'; fi
    [[ ! -s "$CASE_DIR/trace" ]] || fail 'occupied report path still triggered traffic'
    [[ "$(cat "$CASE_DIR/unrelated/keep")" == 'preserve this file' ]] || fail 'report collision altered unrelated data'
    if [[ "$kind" == file ]]; then [[ "$(cat "$AUTO_REPORT_ROOT")" == occupied ]] || fail 'occupied report file was overwritten'
    else [[ -L "$AUTO_REPORT_ROOT" ]] || fail 'report symlink was replaced'; fi
    assert_no_changes
  done
)

test_report_paths_cannot_enter_tuning_state() (
  require_auto
  local kind destination failures=0
  for kind in state child normalized; do
    (
      setup_case "reports-in-state-$kind"
      case "$kind" in
        state) destination="$STATE_DIR" ;;
        child) destination="$STATE_DIR/reports" ;;
        normalized) destination="$CASE_DIR/uncreated/../state/reports/.." ;;
      esac
      if main --lang en tune --report-dir "$destination" < /dev/null > "$CASE_DIR/output" 2>&1; then
        fail "report directory inside tuning state was accepted: $kind"
      fi
      [[ ! -s "$CASE_DIR/trace" ]] || fail "report directory inside tuning state triggered measurement: $kind"
      [[ ! -e "$STATE_DIR" && ! -e "$CASE_DIR/uncreated" ]] || fail "rejected report directory created an incomplete tuning state: $kind"
      assert_no_changes
    ) || failures=$((failures+1))
  done
  [[ "$failures" == 0 ]] || fail 'report-directory preflight did not protect tuning state'
)

test_cancel_does_not_report_success() (
  require_auto
  local phase status
  for phase in before selection after; do
    setup_case "cancel-$phase"; AUTO_SCENARIO="cancel_$phase"
    [[ "$phase" != selection ]] || AUTO_SELECTION=cancel
    status=0
    main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1 || status=$?
    [[ "$status" != 0 ]] || fail 'cancelled workflow returned success'
    python3 - "$(summary_file)" <<'PY' || return 1
import json,sys
d=json.load(open(sys.argv[1]));assert d['status']=='cancelled',d
PY
    if [[ "$phase" == after ]]; then assert_run_restored
    else assert_no_changes; fi
  done
)

test_noop_cancellation_preserves_previous_tuning() (
  require_auto
  setup_case cancel-existing-noop
  main --lang en tune < /dev/null > "$CASE_DIR/first-output" 2>&1 || fail 'could not establish existing successful tuning before cancellation'
  assert_applied
  cp -a "$KERNEL_DIR" "$CASE_DIR/pre-cancel-kernel"
  cp -a "$STATE_DIR" "$CASE_DIR/pre-cancel-state"
  cp "$SYSCTL_FILE" "$CASE_DIR/pre-cancel.conf"
  : > "$CASE_DIR/writes"; : > "$CASE_DIR/trace"; : > "$CASE_DIR/verify-calls"

  # Interrupt after the new plan has been built but before this invocation has
  # written anything. Existing successful NetPilot changes belong to history.
  # shellcheck source=/dev/null
  source <(declare -f adaptive_print_plan | sed '1s/adaptive_print_plan/fixture_print_plan_before_cancel/')
  adaptive_print_plan() {
    kill -INT "$BASHPID"
    fixture_print_plan_before_cancel "$@"
  }
  local status=0
  main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1 || status=$?
  [[ "$status" != 0 ]] || fail 'cancelled no-op run returned success'
  [[ ! -s "$CASE_DIR/writes" ]] || fail 'cancelled no-op run rewrote or rolled back historical configuration'
  diff -r "$KERNEL_DIR" "$CASE_DIR/pre-cancel-kernel" > "$CASE_DIR/cancel-kernel-diff" || fail 'cancelled no-op run changed the previously tuned kernel'
  [[ -d "$STATE_DIR" ]] || fail 'cancelled no-op run deleted historical rollback state'
  diff -r "$STATE_DIR" "$CASE_DIR/pre-cancel-state" > "$CASE_DIR/cancel-state-diff" || fail 'cancelled no-op run changed historical rollback records'
  cmp -s "$SYSCTL_FILE" "$CASE_DIR/pre-cancel.conf" || fail 'cancelled no-op run changed the previously tuned configuration'
  python3 - "$AUTO_REPORT_ROOT" <<'PY' || return 1
from pathlib import Path
import json,sys
reports=[json.loads(p.read_text()) for p in Path(sys.argv[1]).rglob('summary.json')]
cancelled=[d for d in reports if d['status']=='cancelled']
assert len(reports)==2 and len(cancelled)==1,reports
assert cancelled[0]['changed'] is False,cancelled[0]
PY
)

test_cancelled_apply_with_failed_rollback_reports_uncertainty() (
  require_auto
  setup_case cancel-after-apply-rollback-failure
  # Keep the entire real application transaction. Cancel only after it has
  # successfully written and read back its settings, before auto_tune records
  # its normal success bookkeeping. Then make recovery genuinely unavailable.
  # shellcheck source=/dev/null
  source <(declare -f apply_tuning | sed '1s/apply_tuning/fixture_apply_before_cancel/')
  apply_tuning() {
    fixture_apply_before_cancel "$@" || return $?
    kill -INT "$BASHPID"
  }
  tuning_run_restore() { return 1; }
  local status=0
  main --lang en tune < /dev/null > "$CASE_DIR/output" 2>&1 || status=$?
  [[ "$status" != 0 ]] || fail 'cancelled application with failed recovery returned success'
  [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf")" == 1 ]] || fail 'cancellation fixture did not leave a real applied setting after failed recovery'
  [[ -s "$CASE_DIR/writes" && -f "$STATE_DIR/original-values" && -f "$BACKUP_DIR/sysctl-file" ]] || fail 'failed recovery lost its real writes or rollback records'
  python3 - "$(summary_file)" <<'PY' || return 1
import json,sys
d=json.load(open(sys.argv[1]))
assert d['status']=='cancelled',d
assert d.get('rollback_status')=='failed',d
assert d.get('configuration_state')=='unknown' or d.get('applied') is True,d
assert d.get('configuration_state') not in ('unchanged','restored','not-applied'),d
PY
)


test_unloaded_bbr_in_bilingual_menu() (
  local language
  for language in zh en; do
    setup_case "unloaded-menu-$language"
    AUTO_SELECTION=selected; AUTO_EXPECT_CC=bbr; AUTO_EXPECT_QDISC=fq
    printf 'reno cubic\n' > "$KERNEL_DIR/net.ipv4.tcp_available_congestion_control"
    printf '1\n' > "$KERNEL_DIR/net.ipv4.tcp_moderate_rcvbuf"
    printf '4194304\n' > "$KERNEL_DIR/net.core.rmem_max"
    printf '4194304\n' > "$KERNEL_DIR/net.core.wmem_max"
    modprobe() {
      [[ "$*" == tcp_bbr ]] || fail 'unexpected module'
      [[ "$(grep -c '^probe' "$CASE_DIR/trace")" == 1 && ! -s "$CASE_DIR/writes" ]] || fail 'module loading must follow the baseline and precede application'
      printf 'module\n' >> "$CASE_DIR/trace"
      printf 'reno cubic bbr\n' > "$KERNEL_DIR/net.ipv4.tcp_available_congestion_control"
    }
    np_set_language "$language"
    menu < <(printf '9\n10\n0\n') > "$CASE_DIR/output" 2>&1 || fail 'unloaded BBR broke the automatic menu workflow'
    [[ "$(wc -l < "$CASE_DIR/prompts")" == 3 ]] || fail 'automatic tuning required an extra answer'
    [[ "$(grep -c '^module$' "$CASE_DIR/trace")" == 1 ]] || fail 'automatic tuning skipped the BBR module'
    assert_basic_applied
    assert_completed_report
    grep -qx tcp_bbr "$BBR_MODULE_FILE" || fail 'automatic tuning did not persist BBR loading'
    ! grep -Eq '以上仅为计划|This is a plan only' "$CASE_DIR/output" || fail 'automatic menu prints a preview-only footer'
    run_mutation rollback_tuning > "$CASE_DIR/rollback" 2>&1 || fail 'automatic BBR configuration could not be rolled back'
    [[ "$(cat "$KERNEL_DIR/net.ipv4.tcp_congestion_control")" == cubic ]] || fail 'automatic rollback did not restore cubic'
    [[ "$(cat "$KERNEL_DIR/net.core.default_qdisc")" == fq_codel ]] || fail 'automatic rollback did not restore default FQ-CoDel'
    [[ ! -e "$BBR_MODULE_FILE" ]] || fail 'automatic rollback retained its module-loading file'
  done
)

test_retest_reserve_required_before_apply() (
  setup_case retest-reserve
  AUTO_SCENARIO=baseline_budget_high
  if main --lang en tune --budget-mib 128 < /dev/null > "$CASE_DIR/output" 2>&1; then
    fail 'configuration application started without reserving both retests'
  fi
  assert_no_changes
  grep -q 'Remaining budget cannot cover' "$CASE_DIR/output" || fail 'budget shortfall was not explained'
  [[ "$(grep -c '^probe' "$CASE_DIR/trace")" == 1 ]] || fail 'budget failure initiated more measurement'
)

test_failed_baseline_does_not_load_bbr() (
  setup_case unloaded-baseline-failure
  printf 'reno cubic\n' > "$KERNEL_DIR/net.ipv4.tcp_available_congestion_control"
  cp "$KERNEL_DIR/net.ipv4.tcp_available_congestion_control" "$CASE_DIR/original-kernel/net.ipv4.tcp_available_congestion_control"
  AUTO_SCENARIO=before_failure
  modprobe() { fail 'failed baseline must not load any module'; }
  if main tune < /dev/null > "$CASE_DIR/output" 2>&1; then fail 'failed baseline claimed completion'; fi
  assert_no_changes
)

failures=0
if test_retest_reserve_required_before_apply; then printf 'PASS: test_retest_reserve_required_before_apply\n'; else failures=$((failures+1)); fi
for test in test_manual_fixture_and_rollback test_automatic_command_and_bilingual_menu test_short_samples_keep_buffers_and_apply_basic_tuning test_automatic_options_and_budget test_invalid_options_are_zero_traffic test_baseline_failures_never_apply test_application_and_verification_failures_restore test_post_failures_restore_current_run test_no_change_still_compares test_confirmed_regression_restores_current_run test_transient_regression_is_confirmed_only_once test_existing_tuning_restores_this_run_not_first_backup test_preapply_external_drift_stops_without_overwrite test_selected_candidate_applies_only_after_comparison test_retained_bbr_preserves_existing_queue test_missing_algorithm_report_cannot_reach_application test_repeated_runs_preserve_reports_and_first_backup test_report_paths_preserve_existing_data test_report_paths_cannot_enter_tuning_state test_cancel_does_not_report_success test_noop_cancellation_preserves_previous_tuning test_cancelled_apply_with_failed_rollback_reports_uncertainty test_unloaded_bbr_in_bilingual_menu test_failed_baseline_does_not_load_bbr; do
  if "$test"; then printf 'PASS: %s\n' "$test"
  else
    failures=$((failures+1))
    python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
outputs=list(Path(sys.argv[1]).glob('*/output'))
if outputs:
    path=max(outputs,key=lambda p:p.stat().st_mtime_ns)
    print('Last call output ('+path.parent.name+'):',file=sys.stderr)
    print(path.read_text()[-3000:],file=sys.stderr)
PY
  fi
done
[[ "$(sha256sum "$SCRIPT" | awk '{print $1}')" == "$SOURCE_HASH" ]] || fail 'tests modified production source bytes'
[[ "$failures" == 0 ]]
