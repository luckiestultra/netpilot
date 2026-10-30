#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 4 )); then
  printf '%s\n' 'This script requires Bash 4 or newer.' >&2
  return 2 2>/dev/null || exit 2
fi
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

# Capability-aware TCP recommendations, bounded measurements and verified rollback.
#
# Optional dependencies are never installed implicitly. Updating is explicit.
# Read-only commands never install or tune. Changes preserve a baseline snapshot.

readonly STATE_DIR="/var/lib/vps-tcp-full-tune"
readonly BACKUP_DIR="$STATE_DIR/backup"
readonly INSTALL_PATH="/usr/local/bin/tcp.sh"
readonly BBR_FILE="/etc/sysctl.d/10-bbr.conf"
readonly BBR_MODULE_FILE="/etc/modules-load.d/vps-tcp-full-tune.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-network-performance.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-network-performance.conf"
readonly GAI_FILE="/etc/gai.conf"
readonly MSS_COMMENT="vps-tcp-full-tune"
readonly SHORTCUT_PATH="/usr/local/bin/tcp"
readonly LEGACY_SHORTCUT_PATH="/usr/local/bin/t"
readonly UPDATE_URL="https://github.com/liuxr0814/vps-tcp-tune/raw/refs/heads/main/vps-tcp-full-tune.sh"
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[0;33m'
readonly NC=$'\033[0m'
SOURCE_PATH="${BASH_SOURCE[0]}"
SOURCE_SNAPSHOT=""
SCRIPT_PATH=""
RESOLVED_SOURCE=""

declare -a SYSCTL_KEYS=()
declare -A SYSCTL_TARGETS=()
NIC_IFACE=""

log() { printf '[vps-tcp-full-tune] %s\n' "$*"; }
warn() { printf '[vps-tcp-full-tune] 警告：%s\n' "$*" >&2; }
die() { printf '[vps-tcp-full-tune] 错误：%s\n' "$*" >&2; exit 1; }

draw_line() {
  printf '%b\n' "${YELLOW}--------------------------------------------------${NC}"
}



show_bbr_dashboard() {
  printf '\nBBR/default qdisc read-back:\n'
  printf '  congestion control: %s\n' "$(sysctl_value net.ipv4.tcp_congestion_control || echo unknown)"
  printf '  default qdisc: %s\n' "$(sysctl_value net.core.default_qdisc || echo unknown)"
  log 'BBR version and performance gains require separate verification.'
  show_actual_qdisc
}


show_nic_dashboard() {
  printf '\nNIC configuration result:\n'
  [[ ! -e "$STATE_DIR/nic-ring-changed" ]] || log 'Ring settings were changed; original settings are backed up.'
  [[ ! -e "$STATE_DIR/rps-changed" ]] || log 'RPS settings were changed; original settings are backed up.'
  log 'CPU distribution and performance gains have not been measured.'
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
  adaptive_default_interface
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


build_targets() {
  adaptive_plan
}

bbr_available() {
  local available_cc
  available_cc="$(sysctl_value net.ipv4.tcp_available_congestion_control || true)"
  [[ " $available_cc " == *' bbr '* ]]
}

load_bbr_module() {
  local module_error

  bbr_available && return 0

  if ! command -v modprobe >/dev/null 2>&1; then
    warn '系统没有 modprobe，无法加载 tcp_bbr 内核模块。'
    return 1
  fi

  if ! module_error="$(modprobe tcp_bbr 2>&1)"; then
    warn '无法加载 tcp_bbr 内核模块；当前 VPS 内核可能不支持 BBR。'
    [[ -n "$module_error" ]] && warn "$module_error"
    return 1
  fi

  if ! bbr_available; then
    warn 'tcp_bbr 已尝试加载，但内核仍未提供 BBR。'
    return 1
  fi
}

bbr_fq_active() {
  [[ "$(sysctl_value net.ipv4.tcp_congestion_control || true)" == bbr ]] &&
    [[ "$(sysctl_value net.core.default_qdisc || true)" == fq ]]
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

backup_file_once() {
  local name="$2"
  if [[ -e "$BACKUP_DIR/$name" || -L "$BACKUP_DIR/$name" || -e "$BACKUP_DIR/$name.missing" ]]; then
    return 0
  fi
  backup_file "$1" "$name"
}

restore_file() {
  local path="$1" name="$2" tmp
  if [[ -e "$BACKUP_DIR/$name" || -L "$BACKUP_DIR/$name" ]]; then
    mkdir -p -- "$(dirname "$path")" || return 1
    tmp="$(mktemp "${path}.restore.XXXXXX")" || return 1
    rm -f -- "$tmp" || return 1
    if ! cp -a -- "$BACKUP_DIR/$name" "$tmp" || ! mv -fT -- "$tmp" "$path"; then
      rm -f -- "$tmp"
      warn "Unable to restore $path"
      return 1
    fi
  elif [[ -e "$BACKUP_DIR/$name.missing" ]]; then
    rm -f -- "$path" || return 1
  else
    warn "Missing backup metadata for $path; leaving it unchanged."
    return 1
  fi
}

write_lines() {
  local path="$1" mode="$2" tmp
  shift 2
  tmp="$(mktemp "${path}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$@" > "$tmp" || ! chmod "$mode" "$tmp" || ! chown root:root "$tmp" || ! mv -fT -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

write_sysctl_file() {
  local tmp key line value
  local -A merged=()
  if [[ -e "$SYSCTL_FILE" || -L "$SYSCTL_FILE" ]]; then
    if [[ -L "$SYSCTL_FILE" ]] || ! grep -qx '# Managed by vps-tcp-full-tune.sh.' "$SYSCTL_FILE"; then
      warn "Refusing to replace unowned configuration: $SYSCTL_FILE"
      return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      [[ "$line" == *'='* ]] || continue
      key="$(awk -F= '{gsub(/^[ \t]+|[ \t]+$/, "", $1);print $1}' <<< "$line")"
      [[ "$key" =~ ^net\.[a-zA-Z0-9_.]+$ ]] || continue
      value="$(awk -F= '{gsub(/^[ \t]+|[ \t]+$/, "", $2);print $2}' <<< "$line")"
      [[ -n "$value" ]] && merged["$key"]="$value"
    done < "$SYSCTL_FILE"
  fi
  for key in "${SYSCTL_KEYS[@]}"; do merged["$key"]="${SYSCTL_TARGETS[$key]}"; done
  tmp="$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX")" || return 1
  if ! {
    printf '%s\n' '# Managed by vps-tcp-full-tune.sh.' '# Run rollback to restore the saved state.'
    for key in "${!merged[@]}"; do
      printf '%s = %s\n' "$key" "${merged[$key]}" || return 1
    done
  } > "$tmp"; then
    rm -f -- "$tmp"; return 1
  fi
  if ! chmod 0644 "$tmp" || ! chown root:root "$tmp" || ! mv -fT -- "$tmp" "$SYSCTL_FILE"; then
    rm -f -- "$tmp"; return 1
  fi
}

owned_config_target() {
  local path="$1"
  if [[ -L "$path" ]] || { [[ -e "$path" ]] && { [[ ! -f "$path" ]] || ! grep -qx '# Managed by vps-tcp-full-tune.sh.' "$path"; }; }; then
    warn "拒绝覆盖非本工具管理的配置：$path"
    return 1
  fi
}

write_bbr_file() {
  owned_config_target "$BBR_FILE" || return 1
  write_lines "$BBR_FILE" 0644 \
    '# Managed by vps-tcp-full-tune.sh.' \
    'net.core.default_qdisc = fq' \
    'net.ipv4.tcp_congestion_control = bbr'
}

write_bbr_module_file() {
  owned_config_target "$BBR_MODULE_FILE" || return 1
  install -d -m 0755 "$(dirname "$BBR_MODULE_FILE")" || return 1
  write_lines "$BBR_MODULE_FILE" 0644 '# Managed by vps-tcp-full-tune.sh.' 'tcp_bbr'
}

save_original_values() {
  local key value tmp
  tmp="$(mktemp "$STATE_DIR/original-values.tmp.XXXXXX")" || return 1
  if [[ -f "$STATE_DIR/original-values" ]]; then
    cat "$STATE_DIR/original-values" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  for key in "${SYSCTL_KEYS[@]}"; do
    if awk -F = -v n="$key" '$1==n{found=1} END{exit !found}' "$tmp"; then continue; fi
    value="$(sysctl_value "$key")" || { rm -f -- "$tmp"; return 1; }
    [[ -n "$value" ]] || { rm -f -- "$tmp"; return 1; }
    printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  done
  mv -f -- "$tmp" "$STATE_DIR/original-values"
}

managed_file_path() {
  case "$1" in
    bbr-file) printf '%s\n' "$BBR_FILE" ;;
    bbr-module-file) printf '%s\n' "$BBR_MODULE_FILE" ;;
    sysctl-file) printf '%s\n' "$SYSCTL_FILE" ;;
    limits-file) printf '%s\n' "$LIMITS_FILE" ;;
    gai-file) printf '%s\n' "$GAI_FILE" ;;
    *) return 2 ;;
  esac
}

prepare_state() {
  local name path
  if [[ -e "$STATE_DIR" && ! -f "$STATE_DIR/original-values" ]]; then
    warn 'State directory is incomplete; inspect it before applying changes.'
    return 1
  fi
  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR" || return 1
  for name in "$@"; do
    path="$(managed_file_path "$name")" || { warn "未知备份项目：$name"; return 1; }
    backup_file_once "$path" "$name" || return 1
  done
  save_original_values || return 1
  if [[ ! -f "$STATE_DIR/ulimit.before" ]]; then
    printf '%s\n' "$(ulimit -n)" > "$STATE_DIR/ulimit.before" || return 1
  fi
  if [[ ! -f "$STATE_DIR/interface" ]]; then
    printf '%s\n' "$NIC_IFACE" > "$STATE_DIR/interface" || return 1
  fi
}

restore_original_values() {
  local key value failed=0
  [[ -f "$STATE_DIR/original-values" ]] || return 0
  while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    if ! sysctl -w "$key=$value" >/dev/null 2>&1 || ! sysctl_matches "$key" "$value"; then
      warn "Unable to restore and verify $key"
      failed=1
    fi
  done < "$STATE_DIR/original-values"
  return "$failed"
}

restore_ulimit() {
  local value
  if [[ -f "$STATE_DIR/ulimit.before" ]]; then
    value="$(cat "$STATE_DIR/ulimit.before")" || return 1
    ulimit -n "$value" 2>/dev/null || { warn 'Unable to restore this process file limit.'; return 1; }
  fi
}


gai_preference_active() {
  [[ -f "$GAI_FILE" ]] && grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' "$GAI_FILE"
}

apply_gai_preference() {
  if gai_preference_active; then
    log 'IPv4 preference already exists; no duplicate rule added.'
    return 0
  fi
  # The backup was taken by prepare_state before this append.
  printf '\n# Added by vps-tcp-full-tune.sh.\nprecedence ::ffff:0:0/96 100\n' >> "$GAI_FILE" || return 1
  : > "$STATE_DIR/gai-changed" || return 1
}

mss_rule_args() {
  printf '%s\n' '-p' 'tcp' '--tcp-flags' 'SYN,RST' 'SYN' '-m' 'comment' '--comment' "$MSS_COMMENT" '-j' 'TCPMSS' '--clamp-mss-to-pmtu'
}



remove_mss_rule() {
  local rule_args=() status=0
  [[ -e "$STATE_DIR/iptables4-added" ]] || return 0
  command -v iptables >/dev/null 2>&1 || { warn 'iptables unavailable; cannot verify MSS rollback.'; return 1; }
  mapfile -t rule_args < <(mss_rule_args)
  iptables -t mangle -C POSTROUTING "${rule_args[@]}" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) iptables -t mangle -D POSTROUTING "${rule_args[@]}" >/dev/null 2>&1 || return 1 ;;
    1) return 0 ;;
    *) warn 'Cannot inspect MSS rule; keeping rollback state.'; return 1 ;;
  esac
  status=0
  iptables -t mangle -C POSTROUTING "${rule_args[@]}" >/dev/null 2>&1 || status=$?
  case "$status" in
    1) return 0 ;;
    0) warn 'MSS rule is still present.'; return 1 ;;
    *) warn 'Cannot verify MSS removal; keeping rollback state.'; return 1 ;;
  esac
}

ensure_ethtool() {
  command -v ethtool >/dev/null 2>&1 && return 0
  warn 'ethtool is unavailable; install it separately to change NIC ring settings.'
  return 1
}

apply_nic_ring() {
  local iface info max_rx max_tx current_rx current_tx changed=0
  ensure_ethtool || return 0
  touch "$STATE_DIR/nic-ring.before" || return 1
  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    info="$(ethtool -g "$iface" 2>/dev/null || true)"
    [[ -n "$info" ]] || continue
    max_rx="$(awk '/Pre-set maximums:/{p=1;next} /Current hardware settings:/{p=0} p && $1=="RX:"{print $2;exit}' <<< "$info")"
    max_tx="$(awk '/Pre-set maximums:/{p=1;next} /Current hardware settings:/{p=0} p && $1=="TX:"{print $2;exit}' <<< "$info")"
    current_rx="$(awk '/Current hardware settings:/{p=1;next} p && $1=="RX:"{print $2;exit}' <<< "$info")"
    current_tx="$(awk '/Current hardware settings:/{p=1;next} p && $1=="TX:"{print $2;exit}' <<< "$info")"
    if [[ "$max_rx" =~ ^[0-9]+$ && "$max_tx" =~ ^[0-9]+$ && "$current_rx" =~ ^[0-9]+$ && "$current_tx" =~ ^[0-9]+$ ]]; then
      if ! awk -F '\t' -v n="$iface" '$1==n{found=1} END{exit !found}' "$STATE_DIR/nic-ring.before"; then
        printf '%s\t%s\t%s\n' "$iface" "$current_rx" "$current_tx" >> "$STATE_DIR/nic-ring.before" || return 1
      fi
      # Mark ownership before mutation so interrupted operations remain recoverable.
      : > "$STATE_DIR/nic-ring-changed" || return 1
      ethtool -G "$iface" rx "$max_rx" tx "$max_tx" >/dev/null 2>&1 || return 1
      changed=1
      log "Updated $iface ring; initial settings are retained."
    fi
  done < <(network_interfaces)
  (( changed == 1 )) || log 'No supported NIC ring settings were changed.'
  return 0
}

restore_nic_ring() {
  local iface current_rx current_tx info actual_rx actual_tx failed=0
  [[ -e "$STATE_DIR/nic-ring-changed" ]] || return 0
  [[ -f "$STATE_DIR/nic-ring.before" ]] || return 1
  command -v ethtool >/dev/null 2>&1 || return 1
  while IFS=$'\t' read -r iface current_rx current_tx; do
    [[ -n "$iface" ]] || continue
    if ! ethtool -G "$iface" rx "$current_rx" tx "$current_tx" >/dev/null 2>&1; then
      warn "Unable to restore $iface ring"; failed=1; continue
    fi
    info="$(ethtool -g "$iface" 2>/dev/null)" || { failed=1; continue; }
    actual_rx="$(awk '/Current hardware settings:/{p=1;next} p && $1=="RX:"{print $2;exit}' <<< "$info")"
    actual_tx="$(awk '/Current hardware settings:/{p=1;next} p && $1=="TX:"{print $2;exit}' <<< "$info")"
    [[ "$actual_rx" == "$current_rx" && "$actual_tx" == "$current_tx" ]] || failed=1
  done < "$STATE_DIR/nic-ring.before"
  return "$failed"
}

rps_mask_for_cpus() {
  local allowed="$1" wanted="$2" group first last cpu selected=0 mask=0
  local -a groups=()
  [[ "$allowed" =~ ^[0-9,-]+$ && "$wanted" =~ ^[1-9][0-9]*$ ]] || return 1
  IFS=, read -r -a groups <<< "$allowed"
  for group in "${groups[@]}"; do
    [[ "$group" =~ ^([0-9]{1,4})(-([0-9]{1,4}))?$ ]] || return 1
    first=$((10#${BASH_REMATCH[1]}))
    last=$first
    [[ -z ${BASH_REMATCH[3]:-} ]] || last=$((10#${BASH_REMATCH[3]}))
    ((first <= last && last <= 62)) || return 1
    for ((cpu=first; cpu<=last; cpu++)); do
      mask=$((mask | (1 << cpu)))
      selected=$((selected + 1))
      if ((selected == wanted)); then printf '%x\n' "$mask"; return 0; fi
    done
  done
  return 1
}

apply_rps() {
  local cpu_count mask iface path old_value changed=0
  command -v nproc >/dev/null 2>&1 || { log 'nproc unavailable; skipping RPS.'; return 0; }
  if declare -F adaptive_cpu_count >/dev/null; then
    cpu_count="$(adaptive_cpu_count)" || return 1
  else
    cpu_count="$(nproc)" || return 1
  fi || return 1
  if [[ ! "$cpu_count" =~ ^[0-9]+$ ]] || (( cpu_count <= 1 || cpu_count >= 63 )); then
    log 'RPS skipped: requires 2 to 62 available CPUs for this mask implementation.'
    return 0
  fi
  mask="$(rps_mask_for_cpus "$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status)" "$cpu_count")" || {
    log 'RPS skipped: CPU affinity cannot be safely represented by this implementation.'
    return 0
  }
  touch "$STATE_DIR/rps.before" || return 1
  shopt -s nullglob
  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    for path in "/sys/class/net/$iface"/queues/rx-*/rps_cpus "/sys/class/net/$iface"/queues/rx-*/rps_flow_cnt; do
      [[ -f "$path" && -w "$path" ]] || continue
      if ! awk -F '\t' -v n="$path" '$1==n{found=1} END{exit !found}' "$STATE_DIR/rps.before"; then
        old_value="$(cat "$path")" || return 1
        printf '%s\t%s\n' "$path" "$old_value" >> "$STATE_DIR/rps.before" || return 1
      fi
      : > "$STATE_DIR/rps-changed" || return 1
      if [[ "$path" == */rps_cpus ]]; then
        printf '%s\n' "$mask" > "$path" || return 1
      else
        printf '%s\n' 4096 > "$path" || return 1
      fi
      changed=1
    done
  done < <(network_interfaces)
  shopt -u nullglob
  if (( changed == 1 )) && sysctl_supported net.core.rps_sock_flow_entries; then
    if [[ ! -f "$STATE_DIR/rps-sysctl.before" ]]; then
      old_value="$(sysctl_value net.core.rps_sock_flow_entries)" || return 1
      printf 'net.core.rps_sock_flow_entries=%s\n' "$old_value" > "$STATE_DIR/rps-sysctl.before" || return 1
    fi
    sysctl -w net.core.rps_sock_flow_entries=32768 >/dev/null || return 1
    sysctl_matches net.core.rps_sock_flow_entries 32768 || return 1
  fi
  (( changed == 1 )) && log 'Available RPS queues updated; benchmark to assess their effect.'
  return 0
}

restore_rps() {
  local path old_value key value actual failed=0
  if [[ -f "$STATE_DIR/rps.before" ]]; then
    while IFS=$'\t' read -r path old_value; do
      [[ -n "$path" ]] || continue
      if [[ ! -w "$path" ]] || ! printf '%s\n' "$old_value" > "$path"; then
        warn "Unable to restore $path"; failed=1; continue
      fi
      actual="$(cat "$path")" || { failed=1; continue; }
      [[ "$actual" == "$old_value" ]] || failed=1
    done < "$STATE_DIR/rps.before"
  fi
  if [[ -f "$STATE_DIR/rps-sysctl.before" ]]; then
    while IFS='=' read -r key value; do
      [[ -n "$key" ]] || continue
      if ! sysctl -w "$key=$value" >/dev/null 2>&1 || ! sysctl_matches "$key" "$value"; then
        warn "Unable to restore $key"; failed=1
      fi
    done < "$STATE_DIR/rps-sysctl.before"
  fi
  return "$failed"
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
    "$BACKUP_DIR/bbr-module-file" \
    "$BACKUP_DIR/bbr-module-file.missing" \
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
  local previous_iface name path failed=0
  if [[ -f "$STATE_DIR/interface" ]]; then
    previous_iface="$(cat "$STATE_DIR/interface")" || failed=1
    NIC_IFACE="${previous_iface:-}"
  fi
  restore_rps || failed=1
  restore_nic_ring || failed=1
  remove_mss_rule || failed=1
  restore_original_values || failed=1
  restore_ulimit || failed=1
  # Old versions recorded every file. New operations own only explicit backups.
  for name in bbr-file bbr-module-file sysctl-file limits-file gai-file; do
    if [[ -e "$BACKUP_DIR/$name" || -L "$BACKUP_DIR/$name" || -e "$BACKUP_DIR/$name.missing" ]]; then
      path="$(managed_file_path "$name")" || { failed=1; continue; }
      restore_file "$path" "$name" || failed=1
    fi
  done
  if (( failed == 0 )); then
    remove_state_files || failed=1
  else
    warn 'Rollback is incomplete. Backups are retained; inspect errors and retry rollback.'
  fi
  return "$failed"
}


apply_tuning() {
  local answer yes=0 arg
  local -a plan_args=()
  for arg in "$@"; do
    if [[ "$arg" == --yes ]]; then yes=1; else plan_args+=("$arg"); fi
  done
  adaptive_plan "${plan_args[@]}" || return $?
  adaptive_print_plan
  if ((${#SYSCTL_KEYS[@]} == 0)); then
    log '当前支持的参数已满足建议，无需改动。'
    return 0
  fi
  if ((yes == 0)); then
    read -r -p '按以上计划应用并持久化？[y/N] ' answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]] || { log '已取消。'; return 0; }
  fi
  NIC_IFACE="$(default_interface || true)"
  prepare_state sysctl-file || return 1
  install -d -m 0755 /etc/sysctl.d || { transaction_failed 'Cannot create sysctl directory.'; return 1; }
  write_sysctl_file || { transaction_failed 'Cannot persist planned parameters.'; return 1; }
  apply_sysctl_values || { transaction_failed 'Cannot apply or verify planned parameters.'; return 1; }
  log '计划已应用且读回一致；使用 verify 检查后续漂移，bench 测量实际效果。'
}

apply_ipv4_preference_only() {
  if gai_preference_active; then
    log 'IPv4 preference already exists; no changes or rollback claim created.'
    return 0
  fi
  SYSCTL_KEYS=(); SYSCTL_TARGETS=()
  NIC_IFACE="$(default_interface || true)"
  prepare_state gai-file || return 1
  apply_gai_preference || { transaction_failed 'Unable to write IPv4 preference.'; return 1; }
  log 'IPv4 preference applied and backed up.'
}

apply_bbr_only() {
  load_bbr_module || return 1
  SYSCTL_KEYS=(net.core.default_qdisc net.ipv4.tcp_congestion_control)
  SYSCTL_TARGETS=([net.core.default_qdisc]=fq [net.ipv4.tcp_congestion_control]=bbr)
  NIC_IFACE="$(default_interface || true)"
  prepare_state bbr-file bbr-module-file sysctl-file || return 1
  install -d -m 0755 /etc/sysctl.d || { transaction_failed 'Cannot create sysctl directory.'; return 1; }
  write_bbr_file || { transaction_failed 'Cannot write BBR configuration.'; return 1; }
  write_sysctl_file || { transaction_failed 'Cannot persist BBR configuration.'; return 1; }
  write_bbr_module_file || { transaction_failed 'Cannot persist BBR module.'; return 1; }
  sysctl -w net.core.default_qdisc=fq >/dev/null || { transaction_failed 'Cannot set default qdisc.'; return 1; }
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || { transaction_failed 'Cannot select BBR.'; return 1; }
  if ! bbr_fq_active; then
    transaction_failed 'BBR/default FQ read-back failed.'
    return 1
  fi
  show_bbr_dashboard
  log 'BBR + fq applied and backed up.'
}

apply_nic_only() {
  SYSCTL_KEYS=(); SYSCTL_TARGETS=()
  NIC_IFACE="$(default_interface || true)"
  prepare_state || return 1
  apply_nic_ring || { transaction_failed 'Unable to set NIC ring.'; return 1; }
  apply_rps || { transaction_failed 'Unable to set RPS.'; return 1; }
  show_nic_dashboard "$(nproc 2>/dev/null || echo 0)"
}

apply_sysctl_values() {
  local key
  for key in "${SYSCTL_KEYS[@]}"; do
    if ! sysctl -w "$key=${SYSCTL_TARGETS[$key]}" >/dev/null || ! sysctl_matches "$key" "${SYSCTL_TARGETS[$key]}"; then
      warn "Unable to apply and verify $key"
      return 1
    fi
  done
}

rollback_tuning() {
  need_root
  if [[ ! -f "$STATE_DIR/original-values" ]]; then
    warn 'No saved state found; nothing was restored.'
    return 1
  fi
  log 'Restoring saved values and owned files.'
  rollback_internal || return 1
  log 'Rollback completed and verified.'
  show_status
}

install_script_atomic() {
  local source="$1" destination="$2" tmp
  [[ -f "$source" && -s "$source" ]] || { warn '安装源文件不存在或为空。'; return 1; }
  [[ ! -L "$destination" ]] || { warn "安装目标是符号链接，拒绝覆盖：$destination"; return 1; }
  bash -n "$source" || { warn '脚本语法检查失败，保留当前版本。'; return 1; }
  install -d -m 0755 "$(dirname "$destination")" || return 1
  tmp="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
  if ! install -m 0755 "$source" "$tmp" || ! bash -n "$tmp" || ! mv -fT -- "$tmp" "$destination"; then
    rm -f -- "$tmp"
    warn '脚本安装失败，未替换当前版本。'
    return 1
  fi
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
  install_script_atomic "$SCRIPT_PATH" "$INSTALL_PATH" || return 1
  if [[ ! -e "$SHORTCUT_PATH" && ! -L "$SHORTCUT_PATH" ]]; then
    ln -s "$INSTALL_PATH" "$SHORTCUT_PATH" || return 1
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
  exec 9>&-
  exec bash "$INSTALL_PATH" "$@"
}

check_update() {
  local tmp
  command -v curl >/dev/null 2>&1 || die '找不到 curl，无法更新。'

  tmp="$(mktemp)" || return 1
  if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --output "$tmp" "$UPDATE_URL"; then
    rm -f -- "$tmp"
    warn 'GitHub 下载失败，未替换当前脚本。'
    return 1
  fi
  if [[ ! -s "$tmp" ]] || ! bash -n "$tmp"; then
    rm -f -- "$tmp"
    warn '下载的脚本为空或语法检查失败，未替换当前脚本。'
    return 1
  fi
  if ! install_script_atomic "$tmp" "$INSTALL_PATH"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
  log '已从 GitHub 更新脚本，正在重新载入。'
  exec 9>&-
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
    rollback_internal || return 1
  fi
  if [[ -L "$SHORTCUT_PATH" && "$(readlink "$SHORTCUT_PATH")" == "$INSTALL_PATH" ]]; then
    rm -f -- "$SHORTCUT_PATH"
  fi
  if [[ -L "$LEGACY_SHORTCUT_PATH" && "$(readlink "$LEGACY_SHORTCUT_PATH")" == "$INSTALL_PATH" ]]; then
    rm -f -- "$LEGACY_SHORTCUT_PATH"
  fi
  rm -f -- "$SCRIPT_PATH" || return 1
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
  local algorithm qdisc handles ipv4_active=0 bbr_active=0 full_active=0 nic_active=0
  algorithm="$(sysctl_value net.ipv4.tcp_congestion_control || echo unknown)"
  qdisc="$(sysctl_value net.core.default_qdisc || echo unknown)"
  handles="$(ulimit -n 2>/dev/null || echo unknown)"
  if [[ -f "$GAI_FILE" ]] && grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' "$GAI_FILE"; then
    ipv4_active=1
  fi
  [[ "$algorithm" == bbr && "$qdisc" == fq ]] && bbr_active=1
  [[ -f "$SYSCTL_FILE" ]] && full_active=1
  [[ "$(sysctl_value net.core.rps_sock_flow_entries || true)" == 32768 ]] && nic_active=1
  printf '\n%b==================================================%b\n' "$YELLOW" "$NC"
  printf '%b            TCP/UDP 网络深度调优与性能看板            %b\n' "$YELLOW" "$NC"
  printf '%b            bash <(curl -fsSL GitHub Raw)%b\n' "$GREEN" "$NC"
  printf '%b                    快捷命令: tcp                    %b\n' "$GREEN" "$NC"
  printf '%b==================================================%b\n' "$YELLOW" "$NC"
  printf '  1. 设置 IPv4 优先解析 -> %s : [改变地址选择顺序，按需启用]\n' "$(status_badge "$ipv4_active")"
  printf '  2. 开启 BBR + FQ       -> %s : [切换算法与默认队列，需实测效果]\n' "$(status_badge "$bbr_active")"
  printf '  3. 自适应内核调优     -> %s : [预览并应用参数，不保证性能提升]\n' "$(status_badge "$full_active")"
  printf '  4. 网卡多队列均衡     -> %s : [高级选项，单核跳过RPS]\n' "$(status_badge "$nic_active")"
  printf '  5. 一键回退本脚本全部修改\n'
  printf '  6. 检查并同步更新脚本\n'
  printf '  7. 彻底卸载本调优脚本（不卸载 3x-ui）\n'
  printf '  8. 新功能：机器诊断 / 参数计划 / 测速对比 / 验证\n'
  printf '  0. 退出脚本\n'
  draw_line
  printf '当前状态：算法：%b%s%b | 句柄：%b%s%b\n' "$GREEN" "$algorithm" "$NC" "$GREEN" "$handles" "$NC"
  draw_line
}

menu() {
  local choice
  while true; do
    show_menu
    read -r -p '请选择数字 [0-8]: ' choice || return 0
    case "$choice" in
      1) run_mutation apply_ipv4_preference_only || warn "Operation failed." ;;
      2) run_mutation apply_bbr_only || warn "Operation failed." ;;
      3) run_mutation menu_apply_tuning || warn "Operation failed." ;;
      4) run_mutation apply_nic_only || warn "Operation failed." ;;
      5) run_mutation rollback_tuning || warn "Rollback incomplete." ;;
      6) run_mutation check_update ;;
      7) run_mutation uninstall_own_script ;;
      8) feature_menu || warn '新功能操作未完成。' ;;
      0) return 0 ;;
      *) printf '无效选项。\n' ;;
    esac
  done
}

# BEGIN ADAPTIVE
# Conservative recommendations; no command in this block writes system state.
declare -A PLAN_REASONS=()
declare -a PLAN_NOTES=()

adaptive_cgroup_dirs() {
  local controller="$1" proc_root="${2:-/proc}" path root mount candidate dir
  [[ -r "$proc_root/self/cgroup" && -r "$proc_root/self/mountinfo" ]] || return 0
  path="$(awk -F: -v c="$controller" '$1=="0" && $2=="" {print $3; exit} index("," $2 ",", "," c ",") {print $3; exit}' "$proc_root/self/cgroup")"
  [[ "$path" == /* ]] || return 0
  while IFS=$'\t' read -r root mount; do
    [[ "$root" == /* && "$mount" == /* ]] || continue
    # Kernel mountinfo paths use octal escapes for spaces and backslashes.
    printf -v root '%b' "$root"
    printf -v mount '%b' "$mount"
    if [[ "$root" == / ]]; then candidate="$mount$path"
    elif [[ "$path" == "$root" ]]; then candidate="$mount"
    elif [[ "$path" == "$root/"* ]]; then candidate="$mount${path#"$root"}"
    else candidate="$mount$path"; fi
    [[ -d "$candidate" ]] || candidate="$mount"
    dir="${candidate%/}"
    while [[ "$dir" == "$mount" || "$dir" == "$mount/"* ]]; do
      printf '%s\n' "$dir"
      [[ "$dir" == "$mount" ]] && break
      dir="${dir%/*}"
    done
  done < <(awk -v c="$controller" '
    { for(i=7;i<=NF;i++) if($i=="-") {
      if($(i+1)=="cgroup2" || ($(i+1)=="cgroup" && index("," $(i+3) ",", "," c ",")))
        print $4 "\t" $5
      break
    }}' "$proc_root/self/mountinfo")
}

adaptive_cgroup_values() {
  local controller="$1" name="$2" dir quota period
  while IFS= read -r dir; do
    if [[ -r "$dir/$name" ]]; then
      cat "$dir/$name"
    elif [[ "$name" == cpu.max && -r "$dir/cpu.cfs_quota_us" && -r "$dir/cpu.cfs_period_us" ]]; then
      quota="$(cat "$dir/cpu.cfs_quota_us")"; period="$(cat "$dir/cpu.cfs_period_us")"
      printf '%s %s\n' "$quota" "$period"
    fi
  done < <(adaptive_cgroup_dirs "$controller")
}

adaptive_physical_memory_bytes() {
  awk '/^MemTotal:/ {printf "%.0f\n", $2*1024; exit}' /proc/meminfo
}

adaptive_memory_bytes() {
  local memory limit
  memory="$(adaptive_physical_memory_bytes)" || return 1
  [[ "$memory" =~ ^[1-9][0-9]*$ ]] || return 1
  while IFS= read -r limit; do
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || continue
    memory="$(awk -v m="$memory" -v l="$limit" 'BEGIN {printf "%.0f", l<m ? l : m}')"
  done < <(adaptive_cgroup_values memory memory.max; adaptive_cgroup_values memory memory.limit_in_bytes)
  printf '%s\n' "$memory"
}

adaptive_online_cpus() {
  if command -v nproc >/dev/null 2>&1; then nproc
  else getconf _NPROCESSORS_ONLN; fi
}

adaptive_cpu_count() {
  local count quota period limited
  count="$(adaptive_online_cpus)" || return 1
  [[ "$count" =~ ^[1-9][0-9]*$ ]] || return 1
  while read -r quota period; do
    [[ "$quota" =~ ^[1-9][0-9]*$ && "$period" =~ ^[1-9][0-9]*$ ]] || continue
    limited="$(awk -v q="$quota" -v p="$period" 'BEGIN {v=q/p; printf "%.0f", int(v)+(v>int(v))}')"
    if (( limited > 0 && limited < count )); then count="$limited"; fi
  done < <(adaptive_cgroup_values cpu cpu.max)
  printf '%s\n' "$count"
}

adaptive_default_interface() {
  local routes iface
  routes="$(ip -o route get 192.0.2.1 2>/dev/null || ip -o route show default 2>/dev/null || true)"
  iface="$(awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}' <<< "$routes")"
  if [[ -z "$iface" ]]; then
    routes="$(ip -6 -o route get 2001:db8::1 2>/dev/null || ip -6 -o route show default 2>/dev/null || true)"
    iface="$(awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}' <<< "$routes")"
  fi
  [[ -n "$iface" ]] && printf '%s\n' "$iface"
}

adaptive_positive_number() {
  [[ ${#1} -le 16 && "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
    awk -v n="$1" -v ceiling="$2" 'BEGIN {exit !(n>0 && n<=ceiling)}'
}

adaptive_buffer_limit() {
  local memory="$1" profile="$2" bandwidth="$3" rtt="$4" divisor=24
  case "$profile" in proxy) divisor=32 ;; bulk) divisor=16 ;; esac
  # BDP * 2 allows protocol overhead; the profile limits new per-socket ceilings.
  # These policy bounds are recommendations, not proof of optimal performance.
  awk -v m="$memory" -v d="$divisor" -v b="$bandwidth" -v r="$rtt" 'BEGIN {
    desired=b*1000000/8*r/1000*2+262144
    cap=int(m/d); if(cap>268435456) cap=268435456
    value=desired<cap ? desired : cap
    if(value<1) value=1
    printf "%.0f\n", value
  }'
}

adaptive_add_change() {
  local key="$1" target="$2" reason="$3" current
  if ! current="$(sysctl_value "$key")"; then
    PLAN_NOTES+=("$key：当前内核未提供，跳过。")
    return 0
  fi
  current="$(awk '{$1=$1; print}' <<< "$current")"
  [[ "$current" == "$target" ]] && return 0
  SYSCTL_KEYS+=("$key")
  SYSCTL_TARGETS["$key"]="$target"
  PLAN_REASONS["$key"]="$reason"
}

adaptive_plan() {
  local memory available limit key current minimum initial maximum reason
  PLAN_PROFILE=balanced; PLAN_BANDWIDTH=""; PLAN_RTT=""; PLAN_MEMORY_BYTES=""; PLAN_BUFFER_BYTES=""
  SYSCTL_KEYS=(); SYSCTL_TARGETS=(); PLAN_REASONS=(); PLAN_NOTES=()
  while (( $# )); do
    case "$1" in
      --profile|--bandwidth|--rtt)
        if (( $# < 2 )); then printf '参数 %s 缺少值。\n' "$1" >&2; return 2; fi
        case "$1" in
          --profile) PLAN_PROFILE="$2" ;;
          --bandwidth) PLAN_BANDWIDTH="$2" ;;
          --rtt) PLAN_RTT="$2" ;;
        esac
        shift 2 ;;
      *) printf '未知参数：%s\n' "$1" >&2; return 2 ;;
    esac
  done
  case "$PLAN_PROFILE" in balanced|proxy|bulk) ;; *) printf 'profile 必须是 balanced、proxy 或 bulk。\n' >&2; return 2 ;; esac
  if [[ -n "$PLAN_BANDWIDTH" || -n "$PLAN_RTT" ]]; then
    if ! adaptive_positive_number "$PLAN_BANDWIDTH" 1000000 || ! adaptive_positive_number "$PLAN_RTT" 60000; then
      printf '请同时提供正数 --bandwidth Mbps（≤1000000）和 --rtt ms（≤60000）。\n' >&2
      return 2
    fi
  fi
  memory="$(adaptive_memory_bytes)" || { printf '无法确定有效内存，未生成修改计划。\n' >&2; return 1; }
  PLAN_MEMORY_BYTES="$memory"
  available="$(sysctl_value net.ipv4.tcp_available_congestion_control || true)"
  if [[ " $available " == *' bbr '* ]]; then
    adaptive_add_change net.ipv4.tcp_congestion_control bbr '当前内核已提供 BBR；代际版本未确认。'
    adaptive_add_change net.core.default_qdisc fq '设置新建队列的默认值；不会替换当前网卡队列。'
  else
    PLAN_NOTES+=('当前内核尚未提供 BBR；只读规划不加载模块或安装内核。')
  fi
  adaptive_add_change net.ipv4.tcp_moderate_rcvbuf 1 '保留接收缓冲区自动调节能力。'
  if [[ -z "$PLAN_BANDWIDTH" ]]; then
    PLAN_NOTES+=('未提供路径带宽与 RTT，保留现有缓冲区；未执行测速。')
    return 0
  fi
  limit="$(adaptive_buffer_limit "$memory" "$PLAN_PROFILE" "$PLAN_BANDWIDTH" "$PLAN_RTT")"
  PLAN_BUFFER_BYTES="$limit"
  reason="根据输入 BDP 和 ${PLAN_PROFILE} 有效内存预算计算，上限 ${limit} bytes；非预分配、非性能保证。"
  for key in net.core.rmem_max net.core.wmem_max; do
    current="$(sysctl_value "$key" || true)"
    if [[ "$current" =~ ^[0-9]+$ ]] && awk -v a="$limit" -v b="$current" 'BEGIN {exit !(a>b)}'; then
      adaptive_add_change "$key" "$limit" "$reason"
    fi
  done
  for key in net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
    current="$(sysctl_value "$key" || true)"
    read -r minimum initial maximum <<< "$current"
    if [[ "$minimum" =~ ^[0-9]+$ && "$initial" =~ ^[0-9]+$ && "$maximum" =~ ^[0-9]+$ ]] &&
      awk -v a="$limit" -v b="$maximum" -v c="$initial" -v d="$minimum" 'BEGIN {exit !(a>b && a>=c && a>=d)}'; then
      adaptive_add_change "$key" "$minimum $initial $limit" "$reason"
    fi
  done
  PLAN_NOTES+=('保守模式只提高不足的缓冲上限；不降低已有上限，也不增加每连接初始缓冲。')
  PLAN_NOTES+=('tcp_mem、重试次数、ECN、TFO、TIME_WAIT、IPv4/IPv6 策略均保留；真实效果需要同条件复测。')
}

adaptive_print_plan() {
  local key note
  printf '配置档：%s | 有效内存：%s bytes\n' "$PLAN_PROFILE" "$PLAN_MEMORY_BYTES"
  if [[ -n "$PLAN_BANDWIDTH" ]]; then
    printf '路径输入：%s Mbps / %s ms（用户输入；未自动声称为实测）\n' "$PLAN_BANDWIDTH" "$PLAN_RTT"
    printf '新建议缓冲上限：%s bytes（已有更高值不降低）\n' "$PLAN_BUFFER_BYTES"
  fi
  for key in "${SYSCTL_KEYS[@]}"; do
    printf '%s\n  当前：%s\n  建议：%s\n  原因：%s\n' "$key" "$(sysctl_value "$key" || true)" "${SYSCTL_TARGETS[$key]}" "${PLAN_REASONS[$key]}"
  done
  if (( ${#SYSCTL_KEYS[@]} == 0 )); then printf '没有需要修改的支持参数。\n'; fi
  for note in "${PLAN_NOTES[@]}"; do printf '说明：%s\n' "$note"; done
  printf '以上仅为计划，尚未应用。\n'
}

adaptive_show_plan() {
  adaptive_plan "$@" || return $?
  adaptive_print_plan
}

adaptive_doctor() {
  local iface memory cpus
  memory="$(adaptive_memory_bytes || true)"; cpus="$(adaptive_cpu_count || true)"
  printf '只读机器诊断（不安装、不测速、不加载模块）\n'
  printf '内核：%s\n有效内存：%s bytes\n可用 CPU（含亲和性/配额）：%s\n' "$(uname -r)" "${memory:-未知}" "${cpus:-未知}"
  printf '可用拥塞算法：%s\n当前拥塞算法：%s\n默认 qdisc：%s\n' \
    "$(sysctl_value net.ipv4.tcp_available_congestion_control || true)" \
    "$(sysctl_value net.ipv4.tcp_congestion_control || true)" \
    "$(sysctl_value net.core.default_qdisc || true)"
  iface="$(adaptive_default_interface || true)"
  if [[ -n "$iface" ]]; then
    printf '出口网卡：%s\n实际 qdisc（与默认值分开查看）：\n' "$iface"
    if command -v tc >/dev/null 2>&1; then tc -s qdisc show dev "$iface" || true
    else printf '未安装 tc，无法查看实际队列。\n'; fi
  else printf '未找到默认出口网卡。\n'; fi
  [[ "$cpus" != 1 ]] || printf '单核环境：默认跳过 RPS，不承诺多核分摊。\n'
  if [[ -f /etc/tuned/active_profile ]]; then
    printf '检测到 tuned 配置记录：%s；应用前需检查是否由外部调优器管理。\n' "$(head -n 1 /etc/tuned/active_profile)"
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet tuned 2>/dev/null; then
    printf '警告：tuned 服务正在运行，可能覆盖或重设相同参数。\n'
  fi
  printf 'BBR 代际版本与端到端性能未由本次诊断确认。\n'
}
# END ADAPTIVE


# BEGIN INSPECTION
# Verify our persisted intent; never execute configuration as shell code.
verify_tuning() {
  local file line key expected current count=0 failures=0
  local -A targets=()
  for file in "$BBR_FILE" "$SYSCTL_FILE"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      [[ "$line" == *'='* ]] || continue
      key="$(awk -F= '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}' <<< "$line")"
      [[ "$key" =~ ^net\.[a-zA-Z0-9_.]+$ ]] || continue
      expected="$(awk -F= '{gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/[ \t]+/, " ", $2); print $2}' <<< "$line")"
      [[ -n "$expected" ]] || continue
      targets["$key"]="$expected"
    done < "$file"
  done
  for key in "${!targets[@]}"; do
    count=$((count + 1))
    if ! current="$(sysctl_value "$key")"; then
      printf '不可读取 %-38s 期望=%s\n' "$key" "${targets[$key]}"
      failures=$((failures + 1))
      continue
    fi
    current="$(awk '{$1=$1; print}' <<< "$current")"
    if [[ "$current" == "${targets[$key]}" ]]; then
      printf '一致 %-42s %s\n' "$key" "$current"
    else
      printf '偏离 %-42s 当前=%s 持久配置=%s\n' "$key" "$current" "${targets[$key]}"
      failures=$((failures + 1))
    fi
  done
  if ((count == 0)); then
    printf '%s\n' '未找到本工具的持久配置；不能据此判定已调优。'
    return 1
  fi
  printf '检查 %s 项，偏离/不可读取 %s 项。只验证参数，不代表性能提升。\n' "$count" "$failures"
  ((failures == 0))
}

network_named_counters() {
  local file="$1" prefix="$2"
  [[ -r "$file" ]] || return 0
  awk -v prefix="$prefix" '
    $1 == prefix ":" && !header {for(i=2;i<=NF;i++)name[i]=$i;header=1;next}
    $1 == prefix ":" && header {
      for(i=2;i<=NF;i++){
        if(name[i]=="ListenDrops")printf "listen_drops\t%s\n",$i
        if(name[i]=="ListenOverflows")printf "listen_overflows\t%s\n",$i
        if(name[i]=="RetransSegs")printf "tcp_retrans_segs\t%s\n",$i
        if(name[i]=="OutSegs")printf "tcp_out_segs\t%s\n",$i
      };exit
    }' "$file"
}

network_counter_snapshot() {
  local proc_root="${1:-/proc}" _processed b c rest dropped=0 squeezed=0
  if [[ -r "$proc_root/net/softnet_stat" ]]; then
    while read -r _processed b c rest; do
      [[ "$b" =~ ^[0-9a-fA-F]{1,15}$ && "$c" =~ ^[0-9a-fA-F]{1,15}$ ]] || continue
      dropped=$((dropped + 16#$b))
      squeezed=$((squeezed + 16#$c))
    done < "$proc_root/net/softnet_stat"
    printf 'softnet_dropped\t%s\nsoftnet_squeezed\t%s\n' "$dropped" "$squeezed"
  fi
  network_named_counters "$proc_root/net/netstat" TcpExt
  network_named_counters "$proc_root/net/snmp" Tcp
}

diagnose_command() {
  local seconds=0 key value delta
  local -A before=() after=()
  while (($#)); do
    case "$1" in
      --seconds)
        [[ $# -ge 2 && "$2" =~ ^[0-9]{1,2}$ ]] || { warn '--seconds 需要1到60的整数。'; return 2; }
        seconds=$((10#$2))
        ((seconds >= 1 && seconds <= 60)) || { warn '--seconds 需要1到60的整数。'; return 2; }
        shift 2 ;;
      *) warn "未知诊断选项：$1"; return 2 ;;
    esac
  done
  printf '%s\n' '只读网络计数：计数可能包含其他业务；重传不是端到端丢包率。'
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] && before["$key"]="$value"
  done < <(network_counter_snapshot /proc)
  if ((seconds > 0)); then
    printf '观察 %s 秒（不发测速流量）…\n' "$seconds"
    sleep "$seconds" || return 1
    while IFS=$'\t' read -r key value; do
      [[ -n "$key" ]] && after["$key"]="$value"
    done < <(network_counter_snapshot /proc)
  fi
  for key in softnet_dropped softnet_squeezed listen_overflows listen_drops tcp_retrans_segs tcp_out_segs; do
    if [[ ! ${before[$key]+exists} ]]; then
      printf '%-24s 不可读取\n' "$key"
      continue
    fi
    if ((seconds == 0)); then
      printf '%-24s 累计=%s\n' "$key" "${before[$key]}"
    elif [[ ${after[$key]+exists} && ${after[$key]} -ge ${before[$key]} ]]; then
      delta=$((${after[$key]} - ${before[$key]}))
      printf '%-24s 增量=%s\n' "$key" "$delta"
    else
      printf '%-24s 计数重置或不可读取，无法比较\n' "$key"
    fi
  done
  printf '%s\n' 'softnet_dropped 增长可提示接收积压；squeezed 增长可提示处理预算耗尽；需结合CPU和流量定位。'
}
# END INSPECTION


read_plan_options() {
  local profile bandwidth rtt
  MENU_PLAN_ARGS=()
  read -r -p '用途 balanced（通用）/proxy（代理）/bulk（大流），默认 balanced：' profile || return 1
  MENU_PLAN_ARGS=(--profile "${profile:-balanced}")
  read -r -p '已知路径带宽 Mbps（留空保留现有缓冲区，不填网卡标称速率）：' bandwidth || return 1
  if [[ -n "$bandwidth" ]]; then
    read -r -p '同路径 RTT 毫秒：' rtt || return 1
    MENU_PLAN_ARGS+=(--bandwidth "$bandwidth" --rtt "$rtt")
  fi
}

menu_apply_tuning() {
  read_plan_options || return 1
  apply_tuning "${MENU_PLAN_ARGS[@]}"
}

feature_menu() {
  local choice peer budget latency before after seconds
  local -a args=()
  printf '\n1. 机器诊断\n2. 参数建议（只读）\n3. 有预算的双向测速\n4. 对比两份报告\n5. 核对持久配置\n6. 观察网络计数增量\n0. 返回\n'
  read -r -p '选择 [0-6]：' choice || return 1
  case "$choice" in
    1) adaptive_doctor ;;
    2) read_plan_options && adaptive_show_plan "${MENU_PLAN_ARGS[@]}" ;;
    3)
      read -r -p '你有权测速的 iperf3 对端（主机名或IP）：' peer || return 1
      read -r -p '本次总测试数据预算 MiB（默认1024）：' budget || return 1
      read -r -p '同时采样空闲/负载延迟？需ping [y/N]：' latency || return 1
      args=(--peer "$peer" --budget-mib "${budget:-1024}")
      [[ "$latency" =~ ^[Yy]$ ]] && args+=(--latency)
      bench_command "${args[@]}" ;;
    4)
      read -r -p '调优前 JSON 报告路径：' before || return 1
      read -r -p '调优后 JSON 报告路径：' after || return 1
      bench_compare "$before" "$after" ;;
    5) verify_tuning ;;
    6)
      read -r -p '观察秒数（默认5）：' seconds || return 1
      diagnose_command --seconds "${seconds:-5}" ;;
    0) return 0 ;;
    *) warn '无效选项。'; return 2 ;;
  esac
}

# BEGIN BENCH
# Bounded measurement only: these functions never change kernel/network settings.
bench_usage() {
  cat <<'EOF'
用法：tcp bench --peer HOST [--port 5201] [--budget-mib 1024]
               [--direction both|send|receive] [--streams 1] [--timeout 30]
               [--latency] [--output FILE] [--yes]
      tcp compare BEFORE.json AFTER.json
预算为全部方向和流的测试 payload 预算；协议开销、重传和商家计费不等同于该值。
--latency 额外测量空闲/负载下 ICMP RTT；不能据此确定排队或丢包原因。
EOF
}

bench_integer() {
  [[ "$1" =~ ^[0-9]{1,9}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

bench_command() {
  local peer='' port=5201 budget=1024 direction=both streams=1 deadline=30
  local output='' consent=0 latency=0 option answer dep rounds quota
  local bench_dir='' bench_pid='' ping_pid='' report_tmp='' result=0 index=0 mode rc saved_traps saved_umask
  while (( $# )); do
    option="$1"; shift
    case "$option" in
      --yes) consent=1 ;;
      --latency) latency=1 ;;
      -h|--help) bench_usage; return 0 ;;
      --peer|--port|--budget-mib|--direction|--streams|--timeout|--output)
        (( $# )) || { printf '缺少 %s 的值。\n' "$option" >&2; return 2; }
        case "$option" in
          --peer) peer="$1" ;; --port) port="$1" ;; --budget-mib) budget="$1" ;;
          --direction) direction="$1" ;; --streams) streams="$1" ;;
          --timeout) deadline="$1" ;; --output) output="$1" ;;
        esac
        shift ;;
      *) printf '未知测速选项：%s\n' "$option" >&2; return 2 ;;
    esac
  done
  [[ ${#peer} -le 253 && "$peer" =~ ^[a-zA-Z0-9_:][a-zA-Z0-9_.:%-]*$ ]] || {
    printf '请提供合法的对端主机名、IPv4 或 IPv6 地址。\n' >&2; return 2;
  }
  bench_integer "$port" 1 65535 && bench_integer "$budget" 1 1048576 &&
    bench_integer "$streams" 1 32 && bench_integer "$deadline" 2 600 || {
      printf '端口、预算、流数或超时超出允许范围。\n' >&2; return 2;
    }
  port=$((10#$port)); budget=$((10#$budget)); streams=$((10#$streams)); deadline=$((10#$deadline))
  case "$direction" in both) rounds=2 ;; send|receive) rounds=1 ;;
    *) printf 'direction 只能是 both、send 或 receive。\n' >&2; return 2 ;; esac
  # iperf3 -n stops on aggregate test bytes, not bytes per parallel stream.
  # Reserve one default 128 KiB block per stream for concurrent final writes.
  quota=$(( (budget * 1048576 / rounds / 131072 - streams) * 131072 ))
  (( quota >= 131072 )) || { printf '预算不足，请减少流数或提高预算。\n' >&2; return 2; }
  [[ -n "$output" ]] || output="./tcp-bench-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  [[ ! -e "$output" && ! -L "$output" && -d "$(dirname -- "$output")" ]] || {
    printf '报告路径必须尚不存在，且父目录必须存在。\n' >&2; return 2;
  }
  printf '测速对端：%s:%s；方向：%s；每方向 %s 流。\n' "$peer" "$port" "$direction" "$streams"
  printf '总 payload 预算：%s MiB；每方向超时：%s 秒；计费流量可能更高。\n' "$budget" "$deadline"
  if (( consent == 0 )); then
    [[ -t 0 ]] || { printf '非交互模式需显式 --yes；未开始测速。\n' >&2; return 1; }
    read -r -p '确认向此对端运行有预算的测速？[y/N] ' answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]] || return 1
  fi
  for dep in iperf3 python3 timeout; do
    command -v "$dep" >/dev/null 2>&1 || { printf '缺少测速依赖：%s；请自行安装后重试。\n' "$dep" >&2; return 1; }
  done
  if (( latency )); then
    command -v ping >/dev/null 2>&1 || { printf '缺少可选延迟测量依赖：ping。\n' >&2; return 1; }
  fi
  saved_umask="$(umask)"
  umask 077
  bench_dir="$(mktemp -d)" || { umask "$saved_umask"; return 1; }
  saved_traps="$(trap -p EXIT INT TERM HUP)"
  bench_cleanup() {
    if [[ -n "$ping_pid" ]]; then kill -TERM "$ping_pid" 2>/dev/null || true; wait "$ping_pid" 2>/dev/null || true; fi
    if [[ -n "$bench_pid" ]]; then
      kill -TERM -- "-$bench_pid" 2>/dev/null || kill -TERM "$bench_pid" 2>/dev/null || true
      wait "$bench_pid" 2>/dev/null || true
    fi
    [[ -z "$report_tmp" ]] || rm -f -- "$report_tmp"
    [[ -z "$bench_dir" ]] || rm -rf -- "$bench_dir"
  }
  bench_finish() {
    local status="$1"
    bench_cleanup
    umask "$saved_umask"
    trap - EXIT INT TERM HUP
    # This is Bash's own saved trap definition, never report/user input.
    [[ -z "$saved_traps" ]] || eval "$saved_traps"
    return "$status"
  }
  trap bench_cleanup EXIT
  trap 'printf "测速已取消。\n" >&2; bench_finish 0; return 130' INT
  trap 'printf "测速已终止。\n" >&2; bench_finish 0; return 143' TERM HUP
  if (( latency )); then
    ping -n -c 10 -i 0.2 -w 4 -W 1 "$peer" > "$bench_dir/idle.ping" 2>/dev/null &
    ping_pid=$!
    wait "$ping_pid" 2>/dev/null || true
    ping_pid=''
  fi
  local modes=("$direction") args=()
  [[ "$direction" != both ]] || modes=(send receive)
  for mode in "${modes[@]}"; do
    index=$((index + 1))
    args=(-J -c "$peer" -p "$port" -P "$streams" -n "$quota" -l 131072)
    [[ "$mode" != receive ]] || args+=(-R)
    if (( latency )); then
      ping -n -i 0.2 -w "$deadline" -W 1 "$peer" > "$bench_dir/$index.ping" 2>/dev/null &
      ping_pid=$!
    fi
    timeout --kill-after=2 "$deadline" iperf3 "${args[@]}" > "$bench_dir/$index.json" 2> "$bench_dir/$index.err" &
    bench_pid=$!
    if wait "$bench_pid"; then rc=0; else rc=$?; result=1; fi
    bench_pid=''
    if [[ -n "$ping_pid" ]]; then kill -TERM "$ping_pid" 2>/dev/null || true; wait "$ping_pid" 2>/dev/null || true; ping_pid=''; fi
    printf '%s\n' "$mode" > "$bench_dir/$index.direction"
    printf '%s\n' "$rc" > "$bench_dir/$index.rc"
    # A failed/busy peer must not automatically trigger another full-budget retry.
    (( rc == 0 )) || break
  done
  report_tmp="$(mktemp "$(dirname -- "$output")/.tcp-bench.XXXXXX")" || { bench_finish 0; return 1; }
  if ! python3 - "$bench_dir" "$peer" "$port" "$budget" "$streams" "$deadline" "$direction" "$quota" "$latency" > "$report_tmp" <<'PY'
import datetime, json, math, pathlib, re, sys
folder=pathlib.Path(sys.argv[1]); peer=sys.argv[2]
port,budget,streams,timeout=map(int,sys.argv[3:7]); direction=sys.argv[7]
quota=int(sys.argv[8]); latency=bool(int(sys.argv[9]))
def number(value):
    return value if isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value) and value>=0 else None
def rtt(path):
    values=[]
    if path.exists():
        for line in path.read_text(errors='replace').splitlines():
            match=re.search(r'time[=<]([0-9]+(?:\.[0-9]+)?)\s*ms',line)
            if match: values.append(float(match.group(1)))
    values.sort(); count=len(values)
    return {'samples':count,'status':'ok' if count>=3 else 'unavailable_or_insufficient',
            'average_ms':sum(values)/count if count else None,
            'p95_ms':values[max(0,math.ceil(count*.95)-1)] if count else None}
idle=rtt(folder/'idle.ping') if latency else None
runs=[]
for path in sorted(folder.glob('*.direction'),key=lambda p:int(p.stem)):
    n=path.stem; run={'direction':path.read_text().strip()}; rc=int((folder/(n+'.rc')).read_text())
    try:
        raw=json.loads((folder/(n+'.json')).read_text())
        if not isinstance(raw,dict): raise ValueError('measurement JSON must be an object')
        if rc or raw.get('error'): raise ValueError(raw.get('error') or 'iperf3 exited with code '+str(rc))
        end=raw['end']
        if not isinstance(end,dict): raise ValueError('invalid measurement end object')
        received=end.get('sum_received',{}); sent=end.get('sum_sent',{})
        if not isinstance(received,dict) or not isinstance(sent,dict): raise ValueError('invalid measurement totals')
        throughput=number(received.get('bits_per_second'))
        seconds=number(received.get('seconds'))
        transferred=max(number(received.get('bytes')) or 0,number(sent.get('bytes')) or 0)
        if throughput is None or throughput<=0 or seconds is None or seconds<=0 or not transferred: raise ValueError('missing/invalid measurement totals')
        cpu=end.get('cpu_utilization_percent',{})
        if not isinstance(cpu,dict): cpu={}
        run.update(status='ok',bytes=transferred,mbps=throughput/1e6,seconds=seconds,
                   sample_quality='short_sample' if seconds<3 else 'bounded_sample',
                   retransmits=number(sent.get('retransmits')),
                   cpu_host_percent=number(cpu.get('host_total')),
                   cpu_remote_percent=number(cpu.get('remote_total')))
    except (ValueError,KeyError,TypeError) as error:
        stderr=(folder/(n+'.err')).read_text(errors='replace')[:2000]
        run.update(status='failed',exit_code=rc,error=str(error)+((': '+stderr) if stderr else ''))
    if latency:
        loaded=rtt(folder/(n+'.ping'))
        loaded['p95_delta_ms']=(loaded['p95_ms']-idle['p95_ms']) if loaded['status']==idle['status']=='ok' else None
        run['loaded_latency']=loaded
    runs.append(run)
report={'schema_version':1,'kind':'vps-tcp-tune-benchmark',
        'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'peer':peer,'port':port,'budget_bytes':budget*1048576,'streams':streams,
        'timeout_seconds':timeout,'direction':direction,'bytes_per_run_target':quota,
        'latency_enabled':latency,'idle_latency':idle,'runs':runs,
        'note':'Payload budget excludes protocol overhead/retransmissions and is not a provider billing guarantee. ICMP RTT does not identify a queueing cause.'}
json.dump(report,sys.stdout,ensure_ascii=False,indent=2); print()
PY
  then rm -f -- "$report_tmp"; bench_finish 0; return 1; fi
  # Hard-link publication fails atomically if any file/symlink appeared meanwhile.
  if ! ln -T -- "$report_tmp" "$output"; then rm -f -- "$report_tmp"; bench_finish 0; return 1; fi
  rm -f -- "$report_tmp"
  if ! bench_summary "$output"; then result=1; fi
  printf '私有报告：%s\n' "$output"
  bench_finish 0
  return "$result"
}

bench_summary() {
  python3 - "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); failed=False
for r in d['runs']:
    if r['status']!='ok':
        print(r['direction']+': 测量失败，原因见私有报告。'); failed=True; continue
    print('%s: %.2f Mbps，%.2fs，重传=%s，CPU=%s%%，%s' %
          (r['direction'],r['mbps'],r['seconds'],r['retransmits'],r['cpu_host_percent'],
           '样本过短，不能确定峰值' if r['sample_quality']=='short_sample' else '仅代表此对端/方向/时段'))
    if d['latency_enabled']:
        latency=r['loaded_latency']
        if latency['p95_delta_ms'] is None: print('ICMP 延迟：不可用或样本不足。')
        else: print('ICMP 负载p95=%.2fms，相对空闲变化=%+.2fms。' % (latency['p95_ms'],latency['p95_delta_ms']))
print('计费流量可能高于 payload；单次测量不能证明代理体验或调优收益。')
sys.exit(1 if failed else 0)
PY
}

bench_compare() {
  [[ $# == 2 ]] || { bench_usage >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || { printf 'compare 需要 python3。\n' >&2; return 1; }
  python3 - "$1" "$2" <<'PY'
import json,math,sys
try:
    before,after=(json.load(open(p)) for p in sys.argv[1:])
    def valid_number(value):
        return type(value) in (int,float) and math.isfinite(value) and value>0
    def validate(report):
        if not isinstance(report,dict): raise ValueError('报告必须是JSON对象')
        if type(report.get('schema_version')) is not int or report['schema_version']!=1 or report.get('kind')!='vps-tcp-tune-benchmark':
            raise ValueError('不支持的报告格式')
        if not isinstance(report.get('peer'),str) or not report['peer']: raise ValueError('缺少对端')
        for key,low,high in [('port',1,65535),('streams',1,32),('budget_bytes',1048576,1099511627776),('timeout_seconds',2,600)]:
            value=report.get(key)
            if type(value) is not int or not low<=value<=high: raise ValueError('无效字段：'+key)
        if type(report.get('latency_enabled')) is not bool: raise ValueError('无效延迟选项')
        direction=report.get('direction')
        if direction not in ('send','receive','both'): raise ValueError('无效方向')
        expected=['send','receive'] if direction=='both' else [direction]
        runs=report.get('runs')
        if not isinstance(runs,list) or len(runs)!=len(expected): raise ValueError('缺少测速结果')
        mapped={}
        for run in runs:
            if not isinstance(run,dict) or run.get('status')!='ok': raise ValueError('存在失败结果')
            name=run.get('direction')
            if name not in expected or name in mapped: raise ValueError('重复或错误方向')
            if not valid_number(run.get('mbps')) or not valid_number(run.get('seconds')) or not valid_number(run.get('bytes')):
                raise ValueError('无效测量值')
            if run.get('sample_quality') not in ('short_sample','bounded_sample'): raise ValueError('缺少样本状态')
            mapped[name]=run
        return expected,mapped
    expected,left=validate(before)
    _,right=validate(after)
    for key in ('peer','port','direction','streams','budget_bytes','timeout_seconds','latency_enabled'):
        if before[key]!=after[key]: raise ValueError('测试条件不同：'+key)
    for name in expected:
        a,b=left[name],right[name]
        print('%s: %.2f → %.2f Mbps，变化 %+.1f%%' % (name,a['mbps'],b['mbps'],(b['mbps']/a['mbps']-1)*100))
        if a['sample_quality']=='short_sample' or b['sample_quality']=='short_sample': print('样本过短：仅供观察，不能确定峰值或收益。')
    print('同条件的时点对比；线路波动和对端负载仍会影响结果，不能据此保证提升。')
except (OSError,ValueError,KeyError,TypeError) as error:
    print('无法对比：'+str(error),file=sys.stderr); sys.exit(1)
PY
}

# END BENCH

usage() {
  cat <<'EOF'
用法：tcp <命令> [参数]（也可 bash vps-tcp-full-tune.sh <命令>）
  menu                 中文交互菜单
  doctor               只读查看内存/CPU/BBR/实际qdisc/外部调优器
  plan [--profile balanced|proxy|bulk] [--bandwidth Mbps --rtt ms]
                       生成自适应计划，不写入、不测速
  apply [同plan参数] [--yes]  预览、确认后应用并持久化；--yes显式跳过确认
  status               当前值与建议，不修改系统
  verify               核对持久配置和当前参数，偏离时返回非零
  diagnose [--seconds 1..60]  只读丢弃/重传/监听队列计数或观察增量
  bench --peer HOST [--port 5201] [--budget-mib 1024]
        [--direction both|send|receive] [--streams 1] [--latency]
        [--output FILE] [--yes]  有预算的双向测速，需iperf3/python3/timeout
  compare BEFORE.json AFTER.json  比较同条件测速报告
  rollback             恢复首次记录的原值；失败保留备份
  install              显式安装本脚本及tcp快捷命令
  update               从自有仓库下载并检查更新
  uninstall            回退并卸载本工具
  help                 显示帮助
基础命令需要Linux/Bash4+。测速依赖按需安装，脚本不自动安装测速工具。
EOF
}

normalize_sysctl_value() {
  awk '{$1=$1; print}' <<< "$1"
}

sysctl_matches() {
  local current
  current="$(sysctl_value "$1")" || return 1
  [[ "$(normalize_sysctl_value "$current")" == "$(normalize_sysctl_value "$2")" ]]
}

show_actual_qdisc() {
  local iface
  iface="$(default_interface || true)"
  if [[ -n "$iface" ]] && command -v tc >/dev/null 2>&1; then
    printf 'Actual qdisc on %s (distinct from default_qdisc):\n' "$iface"
    tc -s qdisc show dev "$iface" 2>/dev/null || warn 'Unable to read actual qdisc.'
  else
    log 'Actual qdisc is unavailable (missing route or tc).'
  fi
}

transaction_failed() {
  warn "$1"
  rollback_internal || warn 'Recovery incomplete; saved state is retained.'
  return 1
}

run_mutation() {
  local status=0
  need_root
  command -v flock >/dev/null 2>&1 || { warn 'flock is required for changes.'; return 1; }
  exec 9>/run/vps-tcp-full-tune.lock || return 1
  if ! flock -n 9; then
    warn 'Another tuning operation is running.'
    exec 9>&-
    return 1
  fi
  if "$@"; then status=0; else status=$?; fi
  flock -u 9 || status=1
  exec 9>&-
  return "$status"
}

resolve_source_path() {
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
    if ! bash -n "$SOURCE_SNAPSHOT"; then
      rm -f -- "$SOURCE_SNAPSHOT"
      warn '下载的安装脚本语法检查失败，未安装。'
      return 1
    fi
    SCRIPT_PATH="$SOURCE_SNAPSHOT"
  fi
}

# CLI entry point: sourcing this file only defines functions and constants.
main() {
  [[ "$(uname -s)" == Linux ]] || { warn 'This tool requires Linux.'; return 2; }
  need_command sysctl
  need_command awk
  case "${1:-menu}" in
    help|--help|-h) usage; return ;;
    doctor) adaptive_doctor; return ;;
    plan) adaptive_show_plan "${@:2}"; return ;;
    status)
      NIC_IFACE="$(default_interface || true)"
      show_status
      return ;;
    verify) verify_tuning; return ;;
    diagnose) diagnose_command "${@:2}"; return ;;
    bench) bench_command "${@:2}"; return ;;
    compare) bench_compare "${@:2}"; return ;;
    menu) menu; return ;;
  esac
  need_root
  need_command mktemp
  need_command install
  case "${1:-menu}" in
    apply) run_mutation apply_tuning "${@:2}" ;;
    rollback) run_mutation rollback_tuning ;;
    install)
      resolve_source_path || return 1
      run_mutation install_local_copy "${@:2}" ;;
    update) run_mutation check_update ;;
    uninstall)
      resolve_source_path || return 1
      run_mutation uninstall_own_script ;;
    *) usage; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
