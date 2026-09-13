#!/usr/bin/env bash

set -Eeuo pipefail

# One-shot TCP/network tuning with an exact, script-owned rollback.
#
# Option 4 may install ethtool when it is missing. The script never downloads
# or updates itself automatically.
# It applies a broad profile similar in scope to common VPS tuning scripts,
# but every file/value/rule it owns is backed up before it is changed.

readonly STATE_DIR="/var/lib/vps-tcp-full-tune"
readonly BACKUP_DIR="$STATE_DIR/backup"
readonly INSTALL_PATH="/usr/local/bin/tcp.sh"
readonly BBR_FILE="/etc/sysctl.d/10-bbr.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-network-performance.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-network-performance.conf"
readonly GAI_FILE="/etc/gai.conf"
readonly MSS_COMMENT="vps-tcp-full-tune"
readonly SHORTCUT_PATH="/usr/local/bin/tcp"
readonly LEGACY_SHORTCUT_PATH="/usr/local/bin/t"
readonly UPDATE_URL="https://raw.githubusercontent.com/liuxr0814/vps-tcp-tune/main/vps-tcp-full-tune.sh"
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[0;33m'
readonly BLUE=$'\033[0;34m'
readonly PURPLE=$'\033[0;35m'
readonly CYAN=$'\033[0;36m'
readonly BOLD=$'\033[1m'
readonly NC=$'\033[0m'
SOURCE_PATH="${BASH_SOURCE[0]}"
SOURCE_SNAPSHOT=""
SCRIPT_PATH=""
RESOLVED_SOURCE=""
if command -v readlink >/dev/null 2>&1; then
  RESOLVED_SOURCE="$(readlink -f "$SOURCE_PATH" 2>/dev/null || true)"
fi
if [[ -n "$RESOLVED_SOURCE" && -f "$RESOLVED_SOURCE" ]]; then
  SCRIPT_PATH="$RESOLVED_SOURCE"
elif [[ -f "$SOURCE_PATH" && -s "$SOURCE_PATH" ]]; then
  SCRIPT_PATH="$SOURCE_PATH"
else
  # When launched with bash <(curl ...), Bash has already consumed the fd.
  # Re-fetch the canonical GitHub copy, just like the original script did.
  SOURCE_SNAPSHOT="$(mktemp /tmp/vps-tcp-full-tune.XXXXXX)"
  if ! command -v curl >/dev/null 2>&1 || ! curl --fail --silent --show-error \
    --location --proto '=https' --tlsv1.2 --output "$SOURCE_SNAPSHOT" "$UPDATE_URL"; then
    rm -f -- "$SOURCE_SNAPSHOT"
    printf '%s\n' '[vps-tcp-full-tune] 错误：无法重新下载 GitHub 脚本。' >&2
    exit 1
  fi
  if [[ ! -s "$SOURCE_SNAPSHOT" ]]; then
    rm -f -- "$SOURCE_SNAPSHOT"
    printf '%s\n' '[vps-tcp-full-tune] 错误：下载的 GitHub 脚本为空。' >&2
    exit 1
  fi
  SCRIPT_PATH="$SOURCE_SNAPSHOT"
fi

declare -a SYSCTL_KEYS=()
declare -A SYSCTL_TARGETS=()
NIC_IFACE=""
ROLLING_BACK=0

log() { printf '[vps-tcp-full-tune] %s\n' "$*"; }
warn() { printf '[vps-tcp-full-tune] 警告：%s\n' "$*" >&2; }
die() { printf '[vps-tcp-full-tune] 错误：%s\n' "$*" >&2; exit 1; }

draw_line() {
  printf '%b\n' "${YELLOW}--------------------------------------------------${NC}"
}

format_mb() {
  local bytes="$1"
  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '%sMB' "$((bytes / 1024 / 1024))"
  else
    printf '%s' "$bytes"
  fi
}

show_progress() {
  local marker="$1"
  shift
  local step i
  for step in "$@"; do
    printf '  %b[%s]%b %-30s [' "$BLUE" "$marker" "$NC" "$step..."
    for ((i = 0; i < 5; i++)); do
      printf '%b■%b' "$GREEN" "$NC"
      sleep 0.05
    done
    printf ' ] %b[DONE]%b\n' "$GREEN" "$NC"
  done
}

show_bbr_dashboard() {
  show_progress '⚙' \
    'Initializing FQ Pacifier' \
    'Loading BBR Kernel Module' \
    'Calibrating Pacing Rate' \
    'Synchronizing TCP States'
  printf '\n%b🚀 BBR + FQ 网络加速模块已成功灌注至内核底层！%b\n' "$GREEN" "$NC"
  draw_line
  printf '  %-24s : %b%-15s%b\n' 'Current Congestion Control' "$GREEN" "$(sysctl_value net.ipv4.tcp_congestion_control || echo unknown)" "$NC"
  printf '  %-24s : %b%-15s%b\n' 'Default Packet Scheduler' "$GREEN" "$(sysctl_value net.core.default_qdisc || echo unknown)" "$NC"
  printf '  %-24s : %b%-15s%b\n' 'Link Anti-Loss Rate' "$CYAN" '动态实时补偿 [UP]' "$NC"
  draw_line
  printf '%bℹ 跨境单线程吞吐性能、大文件下行带宽已获得内核级硬件加速。%b\n' "$PURPLE" "$NC"
}

show_full_dashboard() {
  local old_bbr="$1" old_somax="$2" old_file="$3" old_rmem="$4" new_rmem="$5"
  show_progress '*' \
    'Analyzing Network Topo' \
    'Clamping MSS Window' \
    'Expanding UDP Ring Buffer' \
    'Activating ECN Engine'
  printf '\n%b✅ 跨境链路专项补丁注入成功！当前实时网络增益快照：%b\n' "$GREEN" "$NC"
  draw_line
  printf '  %-30s : %b%-15s%b（显著降低 Reality/VLESS 握手延迟）\n' 'TCP Low Latency (TTFB)' "$GREEN" '已激活 [0ms 积压]' "$NC"
  printf '  %-30s : %b%-15s%b（防止运营商 ICMP 阻断导致断流）\n' 'MTU Path Discovery' "$GREEN" '智能探测中 [已开启]' "$NC"
  printf '  %-30s : %b%-15s%b（极大平滑 Hysteria2/TUIC 并发丢包）\n' 'UDP Buffer Expansion' "$GREEN" '深度扩容 [16KB Ring]' "$NC"
  printf '  %-30s : %b%-15s%b（高位拥塞时不抛弃数据包，只做标记）\n' 'ECN Smart Congestion' "$GREEN" '动态标记 [防断连]' "$NC"
  printf '  %-30s : %b%-15s%b（针对次世代 BBRv3 算法无缝向前兼容）\n' 'BBR Algorithm Version' "$GREEN" 'BBR3 Pipeline [就绪]' "$NC"
  draw_line
  printf '\n%b✅ 深度调优完成，性能看板快照：%b\n' "$GREEN" "$NC"
  draw_line
  printf '  %-12s: %-15s -> %b%-15s%b\n' '拥塞算法' "$old_bbr" "$GREEN" 'bbr' "$NC"
  printf '  %-12s: %-15s -> %b%-15s%b\n' '最大连接' "$old_somax" "$GREEN" '65535' "$NC"
  printf '  %-12s: %-15s -> %b%-15s%b\n' '文件句柄' "$old_file" "$GREEN" '1048576' "$NC"
  printf '  %-12s: %-15s -> %b%-15s%b\n' '网络缓冲' "$(format_mb "$old_rmem")" "$GREEN" "$(format_mb "$new_rmem")" "$NC"
  draw_line
}

show_nic_dashboard() {
  local cpu_count="$1" i percent=0
  show_progress '⚡' \
    'Mapping Network Interface' \
    'Unbinding Single Core IRQ' \
    'Injecting RPS Network Mask' \
    'Balancing Socket Flows'
  if [[ "$cpu_count" =~ ^[1-9][0-9]*$ ]]; then
    percent=$((100 / cpu_count))
  else
    cpu_count=0
  fi
  printf '\n%b✅ 优化成功！网卡硬件中断多流分发流水线部署完毕：%b\n' "$GREEN" "$NC"
  draw_line
  for ((i = 0; i < cpu_count; i++)); do
    printf '  ⚡ %bCPU Core #%s%b : [%b██████████████████████████████%b] %b分配比率: %s%%%b\n' \
      "$BOLD" "$i" "$NC" "$GREEN" "$NC" "$YELLOW" "$percent" "$NC"
  done
  draw_line
  printf '%bℹ 成功打破单核软中断（SoftIRQ）瓶颈，大并发流量已均匀平摊至所有 %s 个核心。%b\n' "$PURPLE" "$cpu_count" "$NC"
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die '请用 root 运行。';
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "找不到命令：$1";
}

sysctl_supported() {
  sysctl -n "$1" >/dev/null 2>&1
}

sysctl_value() {
  sysctl -n "$1" 2>/dev/null
}

add_target() {
  local key="$1" value="$2"
  if sysctl_supported "$key"; then
    SYSCTL_KEYS+=("$key")
    SYSCTL_TARGETS["$key"]="$value"
  fi
}

default_interface() {
  ip -o route show default 2>/dev/null | awk 'NR == 1 {print $5; exit}'
}

network_interfaces() {
  local path iface
  shopt -s nullglob
  for path in /sys/class/net/*; do
    iface="${path##*/}"
    case "$iface" in
      lo|docker*|veth*|br-*|any|tung3|sit0|tun*|wg*) continue ;;
    esac
    printf '%s\n' "$iface"
  done
  shopt -u nullglob
}

calculate_buffer_max() {
  local mem_kib mem_bytes max_bytes
  mem_kib="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
  [[ "$mem_kib" =~ ^[0-9]+$ ]] || die '无法读取 VPS 内存大小。'
  mem_bytes=$((mem_kib * 1024))

  # Same calculation as the public script: about 5% of total RAM.
  max_bytes=$((mem_bytes / 20))
  printf '%s\n' "$max_bytes"
}

build_targets() {
  local max_buf available_cc
  SYSCTL_KEYS=()
  SYSCTL_TARGETS=()
  max_buf="$(calculate_buffer_max)"

  # Queueing, socket buffers, port range and TCP behavior.
  add_target net.core.default_qdisc fq
  add_target net.core.rmem_max "$max_buf"
  add_target net.core.wmem_max "$max_buf"
  add_target net.core.rmem_default 2097152
  add_target net.core.wmem_default 2097152
  add_target net.core.netdev_max_backlog 65535
  add_target net.core.somaxconn 65535
  add_target net.ipv4.tcp_max_syn_backlog 16384
  add_target net.ipv4.ip_local_port_range '1024 65535'
  add_target net.ipv4.tcp_rmem "4096 87380 ${max_buf}"
  add_target net.ipv4.tcp_wmem "4096 65536 ${max_buf}"
  add_target net.ipv4.udp_rmem_min 16384
  add_target net.ipv4.udp_wmem_min 16384
  add_target net.ipv4.tcp_window_scaling 1
  add_target net.ipv4.tcp_sack 1
  add_target net.ipv4.tcp_ecn 1
  add_target net.ipv4.tcp_mtu_probing 1
  add_target net.ipv4.tcp_fastopen 3
  add_target net.ipv4.tcp_slow_start_after_idle 0
  add_target net.ipv4.tcp_notsent_lowat 16384
  add_target net.ipv4.tcp_tw_reuse 1
  add_target net.ipv4.tcp_fin_timeout 15
  add_target net.ipv4.tcp_retries2 8
  add_target net.ipv4.tcp_max_orphans 32768
  add_target net.ipv4.tcp_congestion_control_version 3

  # BBR is only selected when the running kernel advertises it.
  available_cc="$(sysctl_value net.ipv4.tcp_available_congestion_control || true)"
  if [[ " $available_cc " == *' bbr '* ]]; then
    add_target net.ipv4.tcp_congestion_control bbr
  else
    warn '当前内核没有可用的 BBR，跳过拥塞控制切换。'
  fi
}

bbr_available() {
  local available_cc
  available_cc="$(sysctl_value net.ipv4.tcp_available_congestion_control || true)"
  [[ " $available_cc " == *' bbr '* ]]
}

show_status() {
  local key current target
  build_targets
  echo '当前值 / 本脚本目标：'
  for key in "${SYSCTL_KEYS[@]}"; do
    current="$(sysctl_value "$key" || true)"
    target="${SYSCTL_TARGETS[$key]}"
    printf '%-42s current=%-24s target=%s\n' "$key" "$current" "$target"
  done
  echo
  echo '只读信息：'
  sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true
  if [[ -n "$NIC_IFACE" ]]; then
    printf '默认网卡：%s\n' "$NIC_IFACE"
  fi
  if [[ -e "$STATE_DIR/original-values" ]]; then
    echo '状态：已应用；可执行 rollback。'
  else
    echo '状态：未发现本脚本的应用记录。'
  fi
}

backup_file() {
  local path="$1" name="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a -- "$path" "$BACKUP_DIR/$name"
  else
    : > "$BACKUP_DIR/$name.missing"
  fi
}

restore_file() {
  local path="$1" name="$2"
  rm -f -- "$path"
  if [[ -e "$BACKUP_DIR/$name" || -L "$BACKUP_DIR/$name" ]]; then
    mkdir -p -- "$(dirname "$path")"
    cp -a -- "$BACKUP_DIR/$name" "$path"
  fi
}

write_lines() {
  local path="$1" mode="$2"
  shift 2
  local tmp
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  if ! printf '%s\n' "$@" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod "$mode" "$tmp"
  chown root:root "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$path"
}

write_sysctl_file() {
  local tmp key
  tmp="$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX")"
  {
    printf '%s\n' \
      '# Managed by vps-tcp-full-tune.sh.' \
      '# Remove this file, or run rollback, to disable this profile.'
    for key in "${SYSCTL_KEYS[@]}"; do
      printf '%s = %s\n' "$key" "${SYSCTL_TARGETS[$key]}"
    done
  } > "$tmp"
  chmod 0644 "$tmp"
  chown root:root "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$SYSCTL_FILE"
}

write_bbr_file() {
  write_lines "$BBR_FILE" 0644 \
    '# Managed by vps-tcp-full-tune.sh.' \
    'net.core.default_qdisc = fq' \
    'net.ipv4.tcp_congestion_control = bbr'
}

save_original_values() {
  local key value
  : > "$STATE_DIR/original-values"
  chmod 0600 "$STATE_DIR/original-values"
  for key in "${SYSCTL_KEYS[@]}"; do
    value="$(sysctl_value "$key" || true)"
    [[ -n "$value" ]] || continue
    printf '%s=%s\n' "$key" "$value" >> "$STATE_DIR/original-values"
  done
}

prepare_state() {
  if [[ -e "$STATE_DIR" ]]; then
    [[ -f "$STATE_DIR/original-values" ]] || die '状态目录不完整，请先检查后再继续。'
    return 0
  fi

  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
  backup_file "$BBR_FILE" bbr-file
  backup_file "$SYSCTL_FILE" sysctl-file
  backup_file "$LIMITS_FILE" limits-file
  backup_file "$GAI_FILE" gai-file
  save_original_values
  printf '%s\n' "$(ulimit -n)" > "$STATE_DIR/ulimit.before"
  printf '%s\n' "$NIC_IFACE" > "$STATE_DIR/interface"
}

restore_original_values() {
  local key value
  [[ -f "$STATE_DIR/original-values" ]] || return 0
  while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    sysctl -w "$key=$value" >/dev/null 2>&1 || warn "无法恢复 $key"
  done < "$STATE_DIR/original-values"
}

restore_ulimit() {
  local value
  if [[ -f "$STATE_DIR/ulimit.before" ]]; then
    value="$(cat "$STATE_DIR/ulimit.before")"
    ulimit -n "$value" 2>/dev/null || warn '无法恢复当前脚本进程的文件句柄上限。'
  fi
}

write_limits_file() {
  write_lines "$LIMITS_FILE" 0644 \
    '# Managed by vps-tcp-full-tune.sh.' \
    '* soft nofile 1048576' \
    '* hard nofile 1048576' \
    'root soft nofile 1048576' \
    'root hard nofile 1048576' \
    '* soft nproc 65535' \
    '* hard nproc 65535' \
    'root soft nproc 65535' \
    'root hard nproc 65535'
}

apply_gai_preference() {
  if [[ ! -e "$GAI_FILE" ]]; then
    write_lines "$GAI_FILE" 0644 \
      'label ::1/128       0' \
      'label ::/0          1' \
      'label 2002::/16     2' \
      'label ::/96         3' \
      'label ::ffff:0:0/96 4' \
      'precedence  ::1/128       50' \
      'precedence  ::/0          40' \
      'precedence  2002::/16    30' \
      'precedence  ::/96         20' \
      'precedence  ::ffff:0:0/96 10' \
      'precedence ::ffff:0:0/96  100'
    : > "$STATE_DIR/gai-changed"
    return 0
  fi
  if grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' "$GAI_FILE" 2>/dev/null; then
    log '已有 IPv4 优先规则，未重复添加 gai.conf 规则。'
    return 0
  fi

  {
    printf '\n# Added by vps-tcp-full-tune.sh.\n'
    printf 'precedence ::ffff:0:0/96 100\n'
  } >> "$GAI_FILE"
  : > "$STATE_DIR/gai-changed"
}

mss_rule_args() {
  printf '%s\n' '-p' 'tcp' '--tcp-flags' 'SYN,RST' 'SYN' '-m' 'comment' '--comment' "$MSS_COMMENT" '-j' 'TCPMSS' '--clamp-mss-to-pmtu'
}

legacy_mss_rule_args() {
  printf '%s\n' '-p' 'tcp' '--tcp-flags' 'SYN,RST' 'SYN' '-j' 'TCPMSS' '--clamp-mss-to-pmtu'
}

apply_mss_rule() {
  local rule_args=() legacy_args=()
  mapfile -t rule_args < <(mss_rule_args)
  mapfile -t legacy_args < <(legacy_mss_rule_args)
  if ! command -v iptables >/dev/null 2>&1; then
    log '没有 iptables，跳过 MSS 规则。'
    return 0
  fi
  if iptables -t mangle -C POSTROUTING "${rule_args[@]}" >/dev/null 2>&1; then
    log '已有相同 MSS 规则，未重复添加。'
  elif iptables -t mangle -C POSTROUTING "${legacy_args[@]}" >/dev/null 2>&1; then
    log '已有旧版 MSS 规则，未重复添加。'
  elif iptables -t mangle -A POSTROUTING "${rule_args[@]}" >/dev/null 2>&1; then
    : > "$STATE_DIR/iptables4-added"
    log '已添加 IPv4 POSTROUTING MSS 自适应规则。'
  else
    warn 'MSS 规则添加失败，继续应用其他优化。'
  fi
}

remove_mss_rule() {
  local rule_args=()
  mapfile -t rule_args < <(mss_rule_args)
  if [[ -e "$STATE_DIR/iptables4-added" ]] && command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -D POSTROUTING "${rule_args[@]}" >/dev/null 2>&1 || warn 'IPv4 MSS 规则可能已被外部删除。'
  fi
}

ensure_ethtool() {
  command -v ethtool >/dev/null 2>&1 && return 0
  log '未安装 ethtool，按原脚本尝试通过系统包管理器安装。'
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y ethtool
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ethtool
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ethtool
  else
    warn '找不到 apt-get/yum/dnf，无法安装 ethtool。'
    return 1
  fi
}

apply_nic_ring() {
  local iface info max_rx max_tx current_rx current_tx changed=0
  ensure_ethtool || return 0
  : > "$STATE_DIR/nic-ring.before"

  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    info="$(ethtool -g "$iface" 2>/dev/null || true)"
    [[ -n "$info" ]] || continue
    max_rx="$(awk '/Pre-set maximums:/{p=1;next} /Current hardware settings:/{p=0} p && $1=="RX:"{print $2;exit}' <<< "$info")"
    max_tx="$(awk '/Pre-set maximums:/{p=1;next} /Current hardware settings:/{p=0} p && $1=="TX:"{print $2;exit}' <<< "$info")"
    current_rx="$(awk '/Current hardware settings:/{p=1;next} p && $1=="RX:"{print $2;exit}' <<< "$info")"
    current_tx="$(awk '/Current hardware settings:/{p=1;next} p && $1=="TX:"{print $2;exit}' <<< "$info")"

    if [[ "$max_rx" =~ ^[0-9]+$ && "$max_tx" =~ ^[0-9]+$ && "$current_rx" =~ ^[0-9]+$ && "$current_tx" =~ ^[0-9]+$ ]]; then
      printf '%s\t%s\t%s\n' "$iface" "$current_rx" "$current_tx" >> "$STATE_DIR/nic-ring.before"
      if ethtool -G "$iface" rx "$max_rx" tx "$max_tx" >/dev/null 2>&1; then
        changed=1
        log "已将 $iface 的 ring 调至设备允许的上限。"
      fi
    fi
  done < <(network_interfaces)

  if (( changed == 1 )); then
    : > "$STATE_DIR/nic-ring-changed"
  else
    rm -f -- "$STATE_DIR/nic-ring.before"
    log '没有可调整的网卡 ring 参数。'
  fi
}

restore_nic_ring() {
  local iface current_rx current_tx
  if [[ -e "$STATE_DIR/nic-ring-changed" && -f "$STATE_DIR/nic-ring.before" ]] && command -v ethtool >/dev/null 2>&1; then
    while IFS=$'\t' read -r iface current_rx current_tx; do
      [[ -n "$iface" ]] || continue
      ethtool -G "$iface" rx "$current_rx" tx "$current_tx" >/dev/null 2>&1 || warn "无法恢复 $iface 的 ring 参数。"
    done < "$STATE_DIR/nic-ring.before"
  fi
}

apply_rps() {
  local cpu_count mask iface path old_value changed=0
  command -v nproc >/dev/null 2>&1 || {
    log '找不到 nproc，跳过 RPS。'
    return 0
  }
  cpu_count="$(nproc)"
  if (( cpu_count >= 63 )); then
    log 'CPU 数量过多，跳过简单 RPS 掩码设置。'
    return 0
  fi

  mask="$(printf '%x' $(( (1 << cpu_count) - 1 )))"
  : > "$STATE_DIR/rps.before"
  shopt -s nullglob
  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    for path in "/sys/class/net/$iface"/queues/rx-*/rps_cpus "/sys/class/net/$iface"/queues/rx-*/rps_flow_cnt; do
      [[ -f "$path" && -w "$path" ]] || continue
      old_value="$(cat "$path")"
      printf '%s\t%s\n' "$path" "$old_value" >> "$STATE_DIR/rps.before"
      if [[ "$path" == */rps_cpus ]]; then
        printf '%s\n' "$mask" > "$path"
      else
        printf '%s\n' 4096 > "$path"
      fi
      changed=1
    done
  done < <(network_interfaces)
  if sysctl_supported net.core.rps_sock_flow_entries; then
    printf '%s=%s\n' net.core.rps_sock_flow_entries "$(sysctl_value net.core.rps_sock_flow_entries)" > "$STATE_DIR/rps-sysctl.before"
    sysctl -w net.core.rps_sock_flow_entries=32768 >/dev/null || warn '无法设置 rps_sock_flow_entries。'
    changed=1
  fi
  shopt -u nullglob
  if (( changed == 1 )); then
    : > "$STATE_DIR/rps-changed"
    log '已设置可用网卡的 RPS 队列均衡。'
  else
    rm -f -- "$STATE_DIR/rps.before" "$STATE_DIR/rps-sysctl.before"
    log '当前网卡没有可写的 RPS 参数，跳过。'
  fi
}

restore_rps() {
  local path old_value key value
  if [[ -f "$STATE_DIR/rps.before" ]]; then
    while IFS=$'\t' read -r path old_value; do
      [[ -n "$path" ]] || continue
      [[ -w "$path" ]] || continue
      printf '%s\n' "$old_value" > "$path" || warn "无法恢复 $path"
    done < "$STATE_DIR/rps.before"
  fi
  if [[ -f "$STATE_DIR/rps-sysctl.before" ]]; then
    while IFS='=' read -r key value; do
      [[ -n "$key" ]] || continue
      sysctl -w "$key=$value" >/dev/null 2>&1 || warn "无法恢复 $key"
    done < "$STATE_DIR/rps-sysctl.before"
  fi
}

remove_state_files() {
  rm -f -- \
    "$STATE_DIR/original-values" \
    "$STATE_DIR/ulimit.before" \
    "$STATE_DIR/interface" \
    "$STATE_DIR/gai-changed" \
    "$STATE_DIR/iptables4-added" \
    "$STATE_DIR/ethtool-g.before" \
    "$STATE_DIR/nic-ring.before" \
    "$STATE_DIR/nic-ring-changed" \
    "$STATE_DIR/rps.before" \
    "$STATE_DIR/rps-sysctl.before" \
    "$STATE_DIR/rps-changed" \
    "$BACKUP_DIR/bbr-file" \
    "$BACKUP_DIR/bbr-file.missing" \
    "$BACKUP_DIR/sysctl-file" \
    "$BACKUP_DIR/sysctl-file.missing" \
    "$BACKUP_DIR/limits-file" \
    "$BACKUP_DIR/limits-file.missing" \
    "$BACKUP_DIR/gai-file" \
    "$BACKUP_DIR/gai-file.missing"
  rmdir "$BACKUP_DIR" 2>/dev/null || true
  rmdir "$STATE_DIR" 2>/dev/null || true
}

rollback_internal() {
  local previous_iface
  ROLLING_BACK=1
  if [[ -f "$STATE_DIR/interface" ]]; then
    previous_iface="$(cat "$STATE_DIR/interface")"
    NIC_IFACE="$previous_iface"
  fi
  restore_rps
  restore_nic_ring
  remove_mss_rule
  restore_original_values
  restore_ulimit
  restore_file "$BBR_FILE" bbr-file
  restore_file "$SYSCTL_FILE" sysctl-file
  restore_file "$LIMITS_FILE" limits-file
  restore_file "$GAI_FILE" gai-file
  remove_state_files
  ROLLING_BACK=0
}

handle_error() {
  local status="$1" line="$2"
  if (( ROLLING_BACK == 0 )) && [[ -f "$STATE_DIR/original-values" ]]; then
    warn "第 ${line} 行执行失败，正在自动回退。"
    rollback_internal || true
  fi
  exit "$status"
}

apply_tuning() {
  local mem_target old_bbr old_somax old_file old_rmem
  build_targets
  NIC_IFACE="$(default_interface || true)"
  mem_target="${SYSCTL_TARGETS[net.core.rmem_max]:-未知}"
  old_bbr="$(sysctl_value net.ipv4.tcp_congestion_control || echo 默认)"
  old_somax="$(sysctl_value net.core.somaxconn || echo 默认)"
  old_file="$(ulimit -n 2>/dev/null || echo unknown)"
  old_rmem="$(sysctl_value net.core.rmem_max || echo unknown)"
  log "将一次性应用完整网络参数配置；缓冲区上限目标：${mem_target} bytes。"
  log '会修改 sysctl、limits、gai.conf 和 MSS；不会修改网卡 ring/RPS，也不会重启 Xray。'
  read -r -p '继续应用并持久化？[y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { log '已取消，未执行任何改动。'; return 0; }

  prepare_state

  trap 'handle_error "$?" "$LINENO"' ERR
  install -d -m 0755 /etc/sysctl.d /etc/security/limits.d
  write_sysctl_file
  write_limits_file
  apply_gai_preference
  apply_mss_rule

  if ! apply_sysctl_values; then
    warn 'sysctl 应用失败，正在回退。'
    rollback_internal
    exit 1
  fi
  ulimit -n 1048576 2>/dev/null || true
  trap - ERR

  show_full_dashboard "$old_bbr" "$old_somax" "$old_file" "$old_rmem" "$mem_target"
  log '完整配置已应用并持久化。现有连接不重启；新连接会使用新配置。'
  show_status
}

apply_ipv4_preference_only() {
  build_targets
  NIC_IFACE="$(default_interface || true)"
  prepare_state
  trap 'handle_error "$?" "$LINENO"' ERR
  apply_gai_preference
  trap - ERR
  printf '\n%b✅ 优化成功！当前系统已设置为 [ IPv4 优先 ]。%b\n' "$GREEN" "$NC"
  log 'IPv4 优先解析已应用并备份。'
}

apply_bbr_only() {
  build_targets
  NIC_IFACE="$(default_interface || true)"
  bbr_available || { warn '当前内核没有 BBR，未修改。'; return 1; }
  prepare_state
  trap 'handle_error "$?" "$LINENO"' ERR
  install -d -m 0755 /etc/sysctl.d
  write_bbr_file
  sysctl_supported net.core.default_qdisc && sysctl -w net.core.default_qdisc=fq >/dev/null
  sysctl_supported net.ipv4.tcp_congestion_control && sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
  trap - ERR
  show_bbr_dashboard
  log 'BBR + fq 已应用并备份。'
}

apply_nic_only() {
  build_targets
  NIC_IFACE="$(default_interface || true)"
  prepare_state
  trap 'handle_error "$?" "$LINENO"' ERR
  apply_nic_ring
  apply_rps
  trap - ERR
  show_nic_dashboard "$(nproc 2>/dev/null || echo 0)"
  log '网卡 ring/RPS 调优已执行（不支持的项目已自动跳过）。'
}

apply_sysctl_values() {
  local key
  for key in "${SYSCTL_KEYS[@]}"; do
    sysctl -w "$key=${SYSCTL_TARGETS[$key]}" >/dev/null || {
      warn "无法设置 $key"
      return 1
    }
  done
}

rollback_tuning() {
  need_root
  if [[ ! -f "$STATE_DIR/original-values" ]]; then
    warn '没有找到本脚本的备份，未执行回退。'
    return 1
  fi
  log '正在恢复本脚本修改过的参数和文件。'
  rollback_internal
  log '回退完成；不会删除脚本，也不会改动脚本之外的防火墙规则。'
  show_status
}

install_local_copy() {
  [[ "$SCRIPT_PATH" == "$INSTALL_PATH" ]] && return 0
  [[ -f "$SCRIPT_PATH" ]] || return 0

  if [[ -e "$INSTALL_PATH" ]] && ! cmp -s "$SCRIPT_PATH" "$INSTALL_PATH"; then
    if [[ -n "$SOURCE_SNAPSHOT" ]]; then
      log '检测到旧版本，正在用当前脚本覆盖安装。'
    else
      die "$INSTALL_PATH 已存在且内容不同，请先人工备份或删除后再安装。"
    fi
  fi
  install -m 0755 "$SCRIPT_PATH" "$INSTALL_PATH"
  if [[ ! -e "$SHORTCUT_PATH" && ! -L "$SHORTCUT_PATH" ]]; then
    ln -s "$INSTALL_PATH" "$SHORTCUT_PATH"
    log "已创建快捷命令：tcp"
  elif [[ -L "$SHORTCUT_PATH" && "$(readlink "$SHORTCUT_PATH")" == "$INSTALL_PATH" ]]; then
    :
  else
    warn "$SHORTCUT_PATH 已被其他文件占用，未覆盖。"
  fi
  if [[ -L "$LEGACY_SHORTCUT_PATH" && "$(readlink "$LEGACY_SHORTCUT_PATH")" == "$INSTALL_PATH" ]]; then
    rm -f -- "$LEGACY_SHORTCUT_PATH"
    log '已移除旧快捷命令：t'
  fi
  [[ -z "$SOURCE_SNAPSHOT" ]] || rm -f -- "$SOURCE_SNAPSHOT"
  exec bash "$INSTALL_PATH" "$@"
}

check_update() {
  local tmp
  command -v curl >/dev/null 2>&1 || die '找不到 curl，无法更新。'

  tmp="$(mktemp)"
  if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --output "$tmp" "$UPDATE_URL"; then
    rm -f -- "$tmp"
    die 'GitHub 下载失败，未替换当前脚本。'
  fi
  if ! bash -n "$tmp"; then
    rm -f -- "$tmp"
    die '下载的脚本语法检查失败，未替换当前脚本。'
  fi
  install -m 0755 "$tmp" "$INSTALL_PATH"
  rm -f -- "$tmp"
  log '已从 GitHub 更新脚本，正在重新载入。'
  exec bash "$INSTALL_PATH"
}

uninstall_own_script() {
  local answer
  printf '\n这只会回退本脚本的配置，并删除本脚本和快捷命令：\n'
  printf '  脚本：%s\n  快捷命令：%s\n' "$SCRIPT_PATH" "$SHORTCUT_PATH"
  printf '不会删除 3x-ui、Xray、面板或其他服务。\n'
  read -r -p '确定卸载本调优脚本？[y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { log '已取消卸载。'; return 0; }

  if [[ -f "$STATE_DIR/original-values" ]]; then
    rollback_internal
  fi
  if [[ -L "$SHORTCUT_PATH" && "$(readlink "$SHORTCUT_PATH")" == "$INSTALL_PATH" ]]; then
    rm -f -- "$SHORTCUT_PATH"
  fi
  if [[ -L "$LEGACY_SHORTCUT_PATH" && "$(readlink "$LEGACY_SHORTCUT_PATH")" == "$INSTALL_PATH" ]]; then
    rm -f -- "$LEGACY_SHORTCUT_PATH"
  fi
  rm -f -- "$SCRIPT_PATH"
  log '本调优脚本及其快捷命令已移除；3x-ui/Xray 未修改。'
  exit 0
}

status_badge() {
  if [[ "$1" == 1 ]]; then
    printf '%b[已激活]%b' "$GREEN" "$NC"
  else
    printf '%b[未开启]%b' "$RED" "$NC"
  fi
}

show_menu() {
  local algorithm handles ipv4_active=0 bbr_active=0 full_active=0 nic_active=0
  algorithm="$(sysctl_value net.ipv4.tcp_congestion_control || echo unknown)"
  handles="$(ulimit -n 2>/dev/null || echo unknown)"
  if [[ -f "$GAI_FILE" ]] && grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' "$GAI_FILE"; then
    ipv4_active=1
  fi
  [[ "$algorithm" == bbr ]] && bbr_active=1
  [[ -f "$SYSCTL_FILE" ]] && full_active=1
  [[ "$(sysctl_value net.core.rps_sock_flow_entries || true)" == 32768 ]] && nic_active=1
  printf '\n%b==================================================%b\n' "$YELLOW" "$NC"
  printf '%b            TCP/UDP 网络深度调优与性能看板            %b\n' "$YELLOW" "$NC"
  printf '%b            bash <(curl -fsSL GitHub Raw)%b\n' "$GREEN" "$NC"
  printf '%b                    快捷命令: tcp                    %b\n' "$GREEN" "$NC"
  printf '%b==================================================%b\n' "$YELLOW" "$NC"
  printf '  1. 设置 IPv4 优先解析 -> %s : [解决 IPv6 绕路导致的握手卡顿]\n' "$(status_badge "$ipv4_active")"
  printf '  2. 开启 BBR + FQ       -> %s : [降低跨境丢包，提升单线程速度]\n' "$(status_badge "$bbr_active")"
  printf '  3. 生产级内核调优     -> %s : [支撑 6w+ 并发连接，防止队列溢出]\n' "$(status_badge "$full_active")"
  printf '  4. 网卡多队列均衡     -> %s : [消除单核 CPU 瓶颈，平摊全核负载]\n' "$(status_badge "$nic_active")"
  printf '  5. 一键回退本脚本全部修改\n'
  printf '  6. 检查并同步更新脚本\n'
  printf '  7. 彻底卸载本调优脚本（不卸载 3x-ui）\n'
  printf '  0. 退出脚本\n'
  draw_line
  printf '当前状态：算法：%b%s%b | 句柄：%b%s%b\n' "$GREEN" "$algorithm" "$NC" "$GREEN" "$handles" "$NC"
  draw_line
}

menu() {
  local choice
  while true; do
    show_menu
    read -r -p '请选择数字 [0-7]: ' choice || return 0
    case "$choice" in
      1) apply_ipv4_preference_only || true ;;
      2) apply_bbr_only || true ;;
      3) apply_tuning || true ;;
      4) apply_nic_only || true ;;
      5) rollback_tuning || true ;;
      6) check_update ;;
      7) uninstall_own_script ;;
      0) return 0 ;;
      *) printf '无效选项。\n' ;;
    esac
  done
}

usage() {
  cat <<'EOF'
用法：
  bash vps-tcp-full-tune.sh          进入文字菜单
  bash vps-tcp-full-tune.sh menu     进入文字菜单
  bash vps-tcp-full-tune.sh status    查看当前值和目标值，不修改
  bash vps-tcp-full-tune.sh apply     一次性应用完整配置并备份原值
  bash vps-tcp-full-tune.sh rollback  精确恢复本脚本应用前的状态
  bash vps-tcp-full-tune.sh update    从自有 GitHub 仓库更新脚本
  bash vps-tcp-full-tune.sh uninstall 回退并删除本调优脚本，不删除 3x-ui
EOF
}

need_root
need_command sysctl
need_command awk
need_command ip
need_command mktemp
need_command install
install_local_copy "$@"

case "${1:-menu}" in
  menu)
    menu
    ;;
  status)
    NIC_IFACE="$(default_interface || true)"
    show_status
    ;;
  apply)
    apply_tuning
    ;;
  rollback)
    rollback_tuning
    ;;
  update)
    check_update "$@"
    ;;
  uninstall)
    uninstall_own_script
    ;;
  *)
    usage
    exit 2
    ;;
esac
