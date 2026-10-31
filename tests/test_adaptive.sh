#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_OVERRIDE:-$ROOT/netpilot.sh}"
# Extracted application functions share the language formatter.
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
if [[ -n "${ADAPTIVE_FRAGMENT:-}" ]]; then
  cp "$ADAPTIVE_FRAGMENT" "$TMP/functions.sh"
else
  sed -n '/^# BEGIN ADAPTIVE$/,/^# END ADAPTIVE$/p' "$SCRIPT" > "$TMP/functions.sh"
fi
[[ -s "$TMP/functions.sh" ]] || fail 'adaptive functions are missing'
source "$TMP/functions.sh"
mkdir -p "$TMP/proc/self" "$TMP/cgroup/parent/leaf"
printf '0::/parent/leaf\n' > "$TMP/proc/self/cgroup"
printf '24 23 0:25 / %s rw - cgroup2 cgroup rw\n' "$TMP/cgroup" > "$TMP/proc/self/mountinfo"
mapfile -t DIRS < <(adaptive_cgroup_dirs memory "$TMP/proc")
[[ "${DIRS[*]}" == "$TMP/cgroup/parent/leaf $TMP/cgroup/parent $TMP/cgroup" ]] || fail 'cgroup v2 should include all ancestor limits'
printf '2:cpu,cpuacct:/parent/leaf\n3:memory:/parent/leaf\n' > "$TMP/proc/self/cgroup"
printf '24 23 0:25 /parent %s rw - cgroup cgroup rw,memory\n' "$TMP/cgroup" > "$TMP/proc/self/mountinfo"
mkdir -p "$TMP/cgroup/leaf"
mapfile -t DIRS < <(adaptive_cgroup_dirs memory "$TMP/proc")
[[ "${DIRS[*]}" == "$TMP/cgroup/leaf $TMP/cgroup" ]] || fail 'cgroup v1 should translate mount root correctly'
ip() {
  case "$*" in
    '-o route get 192.0.2.1') return 1 ;;
    '-o route show default') printf 'default dev ppp0 scope link\n' ;;
    *) return 1 ;;
  esac
}
[[ "$(adaptive_default_interface)" == ppp0 ]] || fail 'point-to-point default route must use the dev field'
ip() {
  case "$*" in
    '-6 -o route show default') printf 'default via fe80::1 dev ens9 proto ra\n' ;;
    *) return 1 ;;
  esac
}
[[ "$(adaptive_default_interface)" == ens9 ]] || fail 'IPv6-only route should be supported'
declare -a SYSCTL_KEYS=()
declare -A SYSCTL_TARGETS=()
declare -A CURRENT=(
  [net.ipv4.tcp_available_congestion_control]='reno cubic bbr'
  [net.ipv4.tcp_congestion_control]=cubic
  [net.core.default_qdisc]=fq_codel
  [net.ipv4.tcp_moderate_rcvbuf]=1
  [net.core.rmem_max]=212992
  [net.core.wmem_max]=212992
  [net.ipv4.tcp_rmem]='4096 131072 6291456'
  [net.ipv4.tcp_wmem]='4096 16384 4194304'
)
sysctl_value() { [[ -n "${CURRENT[$1]+exists}" ]] && printf '%s\n' "${CURRENT[$1]}"; }
adaptive_physical_memory_bytes() { printf '%s\n' "${PHYSICAL_BYTES:-2147483648}"; }
adaptive_cgroup_values() {
  case "$2" in
    memory.max|memory.limit_in_bytes) printf '%s\n' "${MEMORY_LIMIT:-max}" ;;
    cpu.max) printf '%s\n' "${CPU_QUOTA:-max 100000}" ;;
    *) return 0 ;;
  esac
}
adaptive_online_cpus() { printf '%s\n' "${ONLINE_CPUS:-8}"; }

adaptive_plan || fail 'a default plan should succeed without measurement'
[[ -z "${SYSCTL_TARGETS[net.core.rmem_max]+exists}" ]] || fail 'missing path input must preserve buffers'
[[ -z "$PLAN_BUFFER_BYTES" ]] || fail 'unmeasured plan must not retain stale measured ceilings'
[[ "${SYSCTL_TARGETS[net.ipv4.tcp_congestion_control]}" == bbr ]] || fail 'advertised BBR should be proposed'
[[ -z "${SYSCTL_TARGETS[net.ipv4.tcp_mem]+exists}" ]] || fail 'default TCP memory budget must be preserved'
[[ -z "${SYSCTL_TARGETS[net.ipv4.tcp_retries2]+exists}" ]] || fail 'retries must be preserved'

adaptive_plan --profile proxy --bandwidth 1000 --rtt 100 || fail 'measured proxy plan'
[[ "${SYSCTL_TARGETS[net.core.rmem_max]}" -gt 12500000 ]] || fail 'BDP must influence ceiling'
[[ "${SYSCTL_TARGETS[net.core.rmem_max]}" -le 67108864 ]] || fail 'proxy recommendation must obey effective-memory budget'
[[ "${SYSCTL_TARGETS[net.ipv4.tcp_rmem]}" == '4096 131072 '* ]] || fail 'existing receive minimum and initial buffer must be preserved'
[[ -z "${SYSCTL_TARGETS[net.core.rmem_default]+exists}" ]] || fail 'socket defaults must not be inflated'

MEMORY_LIMIT=134217728
adaptive_plan --bandwidth 10000 --rtt 200 || fail 'low-memory plan'
[[ "${SYSCTL_TARGETS[net.core.rmem_max]}" -le 8388608 ]] || fail 'cgroup limit must constrain recommendation'
[[ "$(adaptive_memory_bytes)" == 134217728 ]] || fail 'effective memory should use cgroup limit'
MEMORY_LIMIT=max
[[ "$(adaptive_memory_bytes)" == 2147483648 ]] || fail 'unlimited cgroup should retain physical memory'
CPU_QUOTA='100000 100000'
[[ "$(adaptive_cpu_count)" == 1 ]] || fail 'quota must constrain usable CPUs'
CPU_QUOTA='250000 100000'
[[ "$(adaptive_cpu_count)" == 3 ]] || fail 'fractional quota should round up for CPU count'
CPU_QUOTA='max 100000'; ONLINE_CPUS=2
[[ "$(adaptive_cpu_count)" == 2 ]] || fail 'CPU affinity limit must be retained'

for args in '--bandwidth 1' '--rtt 1' '--profile magic' '--bandwidth 0 --rtt 1' '--bandwidth 1 --rtt -2' '--bandwidth 1e6 --rtt 1' '--bandwidth 1;touch --rtt 1' '--bandwidth 1000001 --rtt 1' '--bandwidth 1 --rtt 60001' '--unknown 1'; do
  if adaptive_plan $args >/dev/null 2>&1; then fail "invalid arguments were accepted: $args"; fi
done
adaptive_plan --profile bulk --bandwidth 0.5 --rtt 1.5 || fail 'positive fractional path inputs should be valid'

CURRENT[net.core.rmem_max]=134217728
adaptive_plan --profile proxy --bandwidth 100 --rtt 10 || fail 'existing larger ceiling plan'
[[ -z "${SYSCTL_TARGETS[net.core.rmem_max]+exists}" ]] || fail 'conservative plan should not lower an existing larger ceiling'
CURRENT[net.ipv4.tcp_available_congestion_control]='reno cubic'
adaptive_plan || fail 'missing BBR should be a capability note'
[[ -z "${SYSCTL_TARGETS[net.ipv4.tcp_congestion_control]+exists}" ]] || fail 'unadvertised BBR must not be proposed or loaded'

printf 'PASS: adaptive planning, memory/CPU limits, input validation and conservative defaults\n'
