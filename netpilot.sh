#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 4 )); then
  printf '%s\n' 'This script requires Bash 4 or newer.' >&2
  return 2 2>/dev/null || exit 2
fi
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

# NetPilot: capability-aware TCP recommendations, bounded measurements and verified rollback.
#
# Optional dependencies are never installed implicitly. Updating is explicit.
# Read-only commands never install or tune. Changes preserve a baseline snapshot.

# BEGIN I18N
# Templates are static call-site strings; substitution arguments remain literal data.
np_msg() {
  local template="$1"
  [[ "${NETPILOT_LANG:-zh}" != en ]] || template="$2"
  shift 2
  # shellcheck disable=SC2059
  printf -- "$template" "$@"
}

np_set_language() {
  case "$1" in
    zh|en) NETPILOT_LANG="$1"; export NETPILOT_LANG ;;
    *) printf '%s\n' '语言仅支持 zh 或 en / Language must be zh or en.' >&2; return 2 ;;
  esac
}
# END I18N

# All persisted state, owned files and locks use the NetPilot namespace.
readonly STATE_DIR="/var/lib/netpilot"
readonly BACKUP_DIR="$STATE_DIR/backup"
readonly INSTALL_PATH="/usr/local/bin/netpilot.sh"
readonly BBR_FILE="/etc/sysctl.d/10-netpilot-bbr.conf"
readonly BBR_MODULE_FILE="/etc/modules-load.d/netpilot.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-netpilot.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-netpilot.conf"
readonly GAI_FILE="/etc/gai.conf"
readonly MSS_COMMENT="netpilot"
readonly SHORTCUT_PATH="/usr/local/bin/netpilot"
readonly UPDATE_URL="https://github.com/luckiestultra/netpilot/raw/refs/heads/main/netpilot.sh"
readonly AUTO_DEFAULT_ENDPOINT="https://speed.cloudflare.com"
readonly AUTO_REPORT_ROOT="/tmp/netpilot-reports"
readonly AUTO_LEGACY_REPORT_ROOT="/var/log/netpilot"
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

log() { printf '[NetPilot] %s\n' "$*"; }
warn() { printf '[NetPilot] %s%s\n' "$(np_msg '警告：' 'Warning: ')" "$*" >&2; }
die() { printf '[NetPilot] %s%s\n' "$(np_msg '错误：' 'Error: ')" "$*" >&2; exit 1; }

draw_line() {
  printf '%b\n' "${YELLOW}--------------------------------------------------${NC}"
}



show_bbr_dashboard() {
  np_msg '\nBBR/默认 qdisc 读回结果：\n' '\nBBR/default qdisc read-back:\n'
  np_msg '  拥塞算法：%s\n' '  congestion control: %s\n' "$(sysctl_value net.ipv4.tcp_congestion_control || echo unknown)"
  np_msg '  默认 qdisc：%s\n' '  default qdisc: %s\n' "$(sysctl_value net.core.default_qdisc || echo unknown)"
  log "$(np_msg 'BBR 代际版本和性能收益需要另行验证。' 'BBR version and performance gains require separate verification.')"
  show_actual_qdisc
}


show_nic_dashboard() {
  np_msg '\n网卡配置结果：\n' '\nNIC configuration result:\n'
  [[ ! -e "$STATE_DIR/nic-ring-changed" ]] || log "$(np_msg '已修改 ring 设置，原值已备份。' 'Ring settings were changed; original settings are backed up.')"
  [[ ! -e "$STATE_DIR/rps-changed" ]] || log "$(np_msg '已修改 RPS 设置，原值已备份。' 'RPS settings were changed; original settings are backed up.')"
  log "$(np_msg '尚未测量 CPU 分摊或性能收益。' 'CPU distribution and performance gains have not been measured.')"
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "$(np_msg '请用 root 运行。' 'Please run as root.')";
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "$(np_msg '找不到命令：%s' 'Command not found: %s' "$1")";
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
    warn "$(np_msg '系统没有 modprobe，无法加载 tcp_bbr 内核模块。' 'modprobe is unavailable; cannot load the tcp_bbr kernel module.')"
    return 1
  fi

  if ! module_error="$(modprobe tcp_bbr 2>&1)"; then
    warn "$(np_msg '无法加载 tcp_bbr 内核模块；当前 VPS 内核可能不支持 BBR。' 'Cannot load tcp_bbr; this VPS kernel may not support BBR.')"
    [[ -n "$module_error" ]] && warn "$module_error"
    return 1
  fi

  if ! bbr_available; then
    warn "$(np_msg 'tcp_bbr 已尝试加载，但内核仍未提供 BBR。' 'Attempted to load tcp_bbr, but BBR is still unavailable.')"
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
  echo "$(np_msg '当前值 / 本脚本目标：' 'Current values / NetPilot targets:')"
  for key in "${SYSCTL_KEYS[@]}"; do
    current="$(sysctl_value "$key" || true)"
    target="${SYSCTL_TARGETS[$key]}"
    np_msg '%-42s 当前=%-24s 目标=%s\n' '%-42s current=%-24s target=%s\n' "$key" "$current" "$target"
  done
  echo
  echo "$(np_msg '只读信息：' 'Read-only information:')"
  sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true
  if [[ -n "$NIC_IFACE" ]]; then
    np_msg '默认网卡：%s\n' 'Default interface: %s\n' "$NIC_IFACE"
  fi
  if [[ -e "$STATE_DIR/original-values" ]]; then
    echo "$(np_msg '状态：已应用；可执行 rollback。' 'State: applied; rollback is available.')"
  else
    echo "$(np_msg '状态：未发现本脚本的应用记录。' 'State: no NetPilot application record was found.')"
  fi
}

backup_file() {
  local path="$1" name="$2" tmp
  tmp="$(mktemp "$BACKUP_DIR/.${name}.tmp.XXXXXX")" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    # Publish only a complete copy; retries must never accept a partial backup.
    if ! rm -f -- "$tmp" || ! cp -a -- "$path" "$tmp" || ! mv -fT -- "$tmp" "$BACKUP_DIR/$name"; then
      rm -f -- "$tmp"
      return 1
    fi
  elif ! mv -fT -- "$tmp" "$BACKUP_DIR/$name.missing"; then
    rm -f -- "$tmp"
    return 1
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
      warn "$(np_msg '无法恢复 %s' 'Unable to restore %s' "$path")"
      return 1
    fi
  elif [[ -e "$BACKUP_DIR/$name.missing" ]]; then
    rm -f -- "$path" || return 1
  else
    warn "$(np_msg '缺少 %s 的备份元数据，保留原文件。' 'Missing backup metadata for %s; leaving it unchanged.' "$path")"
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
    if [[ -L "$SYSCTL_FILE" ]] || ! grep -Fqx '# Managed by netpilot.sh.' "$SYSCTL_FILE"; then
      warn "$(np_msg '拒绝覆盖非本工具管理的配置：%s' 'Refusing to replace unowned configuration: %s' "$SYSCTL_FILE")"
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
    printf '%s\n' '# Managed by netpilot.sh.' '# Run rollback to restore the saved state.'
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
  if [[ -L "$path" ]] || { [[ -e "$path" ]] && { [[ ! -f "$path" ]] || ! grep -Fqx '# Managed by netpilot.sh.' "$path"; }; }; then
    warn "$(np_msg '拒绝覆盖非本工具管理的配置：%s' 'Refusing to replace unowned configuration: %s' "$path")"
    return 1
  fi
}

write_bbr_file() {
  owned_config_target "$BBR_FILE" || return 1
  write_lines "$BBR_FILE" 0644 \
    '# Managed by netpilot.sh.' \
    'net.core.default_qdisc = fq' \
    'net.ipv4.tcp_congestion_control = bbr'
}

write_bbr_module_file() {
  owned_config_target "$BBR_MODULE_FILE" || return 1
  install -d -m 0755 "$(dirname "$BBR_MODULE_FILE")" || return 1
  write_lines "$BBR_MODULE_FILE" 0644 '# Managed by netpilot.sh.' 'tcp_bbr'
}

save_original_values() {
  local key value tmp last_char
  tmp="$(mktemp "$STATE_DIR/original-values.tmp.XXXXXX")" || return 1
  if [[ -f "$STATE_DIR/original-values" ]]; then
    cat "$STATE_DIR/original-values" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  # A valid final record may lack LF; separate new keys in the private copy.
  if [[ -s "$tmp" ]]; then
    last_char="$(tail -c 1 -- "$tmp")" || { rm -f -- "$tmp"; return 1; }
    if [[ -n "$last_char" ]]; then
      printf '\n' >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
  fi
  for key in "${SYSCTL_KEYS[@]}"; do
    if awk -F = -v n="$key" '$1==n{found=1} END{exit !found}' "$tmp"; then continue; fi
    value="$(sysctl_value "$key")" || { rm -f -- "$tmp"; return 1; }
    [[ -n "$value" ]] || { rm -f -- "$tmp"; return 1; }
    printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  done
  if ! mv -f -- "$tmp" "$STATE_DIR/original-values"; then
    rm -f -- "$tmp"
    return 1
  fi
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
  local name path dir fresh_state=0 cleanup_failed=0
  if [[ -e "$STATE_DIR" && ! -f "$STATE_DIR/original-values" ]]; then
    warn "$(np_msg '状态目录不完整，请先检查，再应用变更。' 'State directory is incomplete; inspect it before applying changes.')"
    return 1
  fi
  [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]] || fresh_state=1
  # Publish original values first so later preparation failures can be retried.
  if ! install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR" || ! save_original_values; then
    if ((fresh_state)); then
      for dir in "$BACKUP_DIR" "$STATE_DIR"; do
        [[ -d "$dir" ]] || continue
        if ! rmdir -- "$dir" 2>/dev/null; then cleanup_failed=1; fi
      done
      if ((cleanup_failed)); then
        warn "$(np_msg '首次状态准备失败；非空或无法删除的目录已保留。' 'Initial state preparation failed; nonempty or unremovable directories were retained.')"
      fi
    fi
    return 1
  fi
  for name in "$@"; do
    path="$(managed_file_path "$name")" || { warn "$(np_msg '未知备份项目：%s' 'Unknown backup item: %s' "$name")"; return 1; }
    backup_file_once "$path" "$name" || return 1
  done
  if [[ ! -f "$STATE_DIR/interface" ]]; then
    printf '%s\n' "$NIC_IFACE" > "$STATE_DIR/interface" || return 1
  fi
}

restore_original_values() {
  local key value failed=0
  [[ -f "$STATE_DIR/original-values" ]] || return 0
  while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
    [[ -n "$key" ]] || continue
    if ! sysctl -w "$key=$value" >/dev/null 2>&1 || ! sysctl_matches "$key" "$value"; then
      warn "$(np_msg '无法恢复并核验 %s' 'Unable to restore and verify %s' "$key")"
      failed=1
    fi
  done < "$STATE_DIR/original-values" || failed=1
  return "$failed"
}


gai_preference_active() {
  [[ -f "$GAI_FILE" ]] && grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' "$GAI_FILE"
}

apply_gai_preference() {
  if gai_preference_active; then
    log "$(np_msg 'IPv4 优先规则已存在，未重复添加。' 'IPv4 preference already exists; no duplicate rule added.')"
    return 0
  fi
  if [[ -L "$GAI_FILE" ]]; then
    warn "$(np_msg '拒绝通过符号链接修改 IPv4 优先规则：%s' 'Refusing to modify IPv4 preference through a symbolic link: %s' "$GAI_FILE")"
    return 1
  fi
  # The backup was taken by prepare_state before this append.
  printf '\n# Added by netpilot.sh.\nprecedence ::ffff:0:0/96 100\n' >> "$GAI_FILE" || return 1
  : > "$STATE_DIR/gai-changed" || return 1
}

mss_rule_args() {
  printf '%s\n' '-p' 'tcp' '--tcp-flags' 'SYN,RST' 'SYN' '-m' 'comment' '--comment' "$MSS_COMMENT" '-j' 'TCPMSS' '--clamp-mss-to-pmtu'
}



remove_mss_rule() {
  local rule_args=() status=0
  [[ -e "$STATE_DIR/iptables4-added" ]] || return 0
  command -v iptables >/dev/null 2>&1 || { warn "$(np_msg 'iptables 不可用，无法核验 MSS 回退。' 'iptables unavailable; cannot verify MSS rollback.')"; return 1; }
  mapfile -t rule_args < <(mss_rule_args)
  iptables -t mangle -C POSTROUTING "${rule_args[@]}" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) iptables -t mangle -D POSTROUTING "${rule_args[@]}" >/dev/null 2>&1 || return 1 ;;
    1) return 0 ;;
    *) warn "$(np_msg '无法检查 MSS 规则，保留回退状态。' 'Cannot inspect MSS rule; keeping rollback state.')"; return 1 ;;
  esac
  status=0
  iptables -t mangle -C POSTROUTING "${rule_args[@]}" >/dev/null 2>&1 || status=$?
  case "$status" in
    1) return 0 ;;
    0) warn "$(np_msg 'MSS 规则仍然存在。' 'MSS rule is still present.')"; return 1 ;;
    *) warn "$(np_msg '无法核验 MSS 规则删除结果，保留回退状态。' 'Cannot verify MSS removal; keeping rollback state.')"; return 1 ;;
  esac
}

ensure_ethtool() {
  command -v ethtool >/dev/null 2>&1 && return 0
  warn "$(np_msg 'ethtool 不可用；如需调整网卡 ring，请自行安装。' 'ethtool is unavailable; install it separately to change NIC ring settings.')"
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
      log "$(np_msg '已更新 %s 的 ring，首次原值已保留。' 'Updated %s ring; initial settings are retained.' "$iface")"
    fi
  done < <(network_interfaces)
  (( changed == 1 )) || log "$(np_msg '未修改任何受支持的网卡 ring 设置。' 'No supported NIC ring settings were changed.')"
  return 0
}

restore_nic_ring() {
  local iface current_rx current_tx info actual_rx actual_tx failed=0 records=0
  [[ -e "$STATE_DIR/nic-ring-changed" ]] || return 0
  [[ -f "$STATE_DIR/nic-ring.before" ]] || return 1
  command -v ethtool >/dev/null 2>&1 || return 1
  while IFS=$'\t' read -r iface current_rx current_tx || [[ -n "$iface$current_rx$current_tx" ]]; do
    [[ "$iface$current_rx$current_tx" =~ ^[[:space:]]*$ ]] && continue
    if [[ -z "$iface" || "$iface" == *[[:space:]/]* || ! "$current_rx" =~ ^[0-9]+$ || ! "$current_tx" =~ ^[0-9]+$ ]]; then
      warn "$(np_msg '网卡 ring 原值记录无效，保留回退状态。' 'Invalid NIC ring snapshot; keeping rollback state.')"
      failed=1; continue
    fi
    records=$((records + 1))
    if ! ethtool -G "$iface" rx "$current_rx" tx "$current_tx" >/dev/null 2>&1; then
      warn "$(np_msg '无法恢复 %s 的 ring' 'Unable to restore %s ring' "$iface")"; failed=1; continue
    fi
    info="$(ethtool -g "$iface" 2>/dev/null)" || { failed=1; continue; }
    actual_rx="$(awk '/Current hardware settings:/{p=1;next} p && $1=="RX:"{print $2;exit}' <<< "$info")"
    actual_tx="$(awk '/Current hardware settings:/{p=1;next} p && $1=="TX:"{print $2;exit}' <<< "$info")"
    [[ "$actual_rx" == "$current_rx" && "$actual_tx" == "$current_tx" ]] || failed=1
  done < "$STATE_DIR/nic-ring.before" || failed=1
  if ((records == 0)); then
    warn "$(np_msg '网卡 ring 原值记录为空，保留回退状态。' 'NIC ring snapshot is empty; keeping rollback state.')"
    failed=1
  fi
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
  command -v nproc >/dev/null 2>&1 || { log "$(np_msg 'nproc 不可用，跳过 RPS。' 'nproc unavailable; skipping RPS.')"; return 0; }
  if declare -F adaptive_cpu_count >/dev/null; then
    cpu_count="$(adaptive_cpu_count)" || return 1
  else
    cpu_count="$(nproc)" || return 1
  fi || return 1
  if [[ ! "$cpu_count" =~ ^[0-9]+$ ]] || (( cpu_count <= 1 || cpu_count >= 63 )); then
    log "$(np_msg '已跳过 RPS：当前掩码实现需要 2 到 62 个可用 CPU。' 'RPS skipped: requires 2 to 62 available CPUs for this mask implementation.')"
    return 0
  fi
  mask="$(rps_mask_for_cpus "$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status)" "$cpu_count")" || {
    log "$(np_msg '已跳过 RPS：当前实现无法安全表示 CPU 亲和性。' 'RPS skipped: CPU affinity cannot be safely represented by this implementation.')"
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
      if [[ -e "$STATE_DIR/rps-sysctl-changed" ]]; then
        warn "$(np_msg '缺少 RPS sysctl 原值记录，保留回退状态。' 'Missing RPS sysctl snapshot; keeping rollback state.')"
        return 1
      fi
      old_value="$(sysctl_value net.core.rps_sock_flow_entries)" || return 1
      printf 'net.core.rps_sock_flow_entries=%s\n' "$old_value" > "$STATE_DIR/rps-sysctl.before" || return 1
    fi
    : > "$STATE_DIR/rps-sysctl-changed" || return 1
    sysctl -w net.core.rps_sock_flow_entries=32768 >/dev/null || return 1
    sysctl_matches net.core.rps_sock_flow_entries 32768 || return 1
  fi
  (( changed == 1 )) && log "$(np_msg '已更新可用 RPS 队列；请通过测速判断实际效果。' 'Available RPS queues updated; benchmark to assess their effect.')"
  return 0
}

restore_rps() {
  local path old_value key value actual failed=0 records=0 sysctl_records=0
  if [[ -e "$STATE_DIR/rps-sysctl-changed" && ! -f "$STATE_DIR/rps-sysctl.before" ]]; then
    warn "$(np_msg '缺少 RPS sysctl 原值记录，保留回退状态。' 'Missing RPS sysctl snapshot; keeping rollback state.')"
    return 1
  fi
  if [[ -e "$STATE_DIR/rps-changed" && ! -f "$STATE_DIR/rps.before" ]]; then
    warn "$(np_msg '缺少 RPS 原值记录，保留回退状态。' 'Missing RPS snapshot; keeping rollback state.')"
    return 1
  fi
  if [[ -f "$STATE_DIR/rps.before" ]]; then
    while IFS=$'\t' read -r path old_value || [[ -n "$path$old_value" ]]; do
      [[ "$path$old_value" =~ ^[[:space:]]*$ ]] && continue
      if [[ "$path" == */rps_cpus && "$old_value" =~ ^[[:xdigit:]]{1,8}(,[[:xdigit:]]{1,8})*$ ]] ||
         [[ "$path" == */rps_flow_cnt && "$old_value" =~ ^[0-9]+$ ]]; then
        records=$((records + 1))
      else
        warn "$(np_msg 'RPS 原值记录无效，保留回退状态。' 'Invalid RPS snapshot; keeping rollback state.')"
        failed=1; continue
      fi
      if [[ ! -w "$path" ]] || ! printf '%s\n' "$old_value" > "$path"; then
        warn "$(np_msg '无法恢复 %s' 'Unable to restore %s' "$path")"; failed=1; continue
      fi
      actual="$(cat "$path")" || { failed=1; continue; }
      [[ "$actual" == "$old_value" ]] || failed=1
    done < "$STATE_DIR/rps.before" || failed=1
  fi
  if [[ -e "$STATE_DIR/rps-changed" ]] && ((records == 0)); then
    warn "$(np_msg 'RPS 原值记录为空，保留回退状态。' 'RPS snapshot is empty; keeping rollback state.')"
    return 1
  fi
  if [[ -f "$STATE_DIR/rps-sysctl.before" ]]; then
    while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
      [[ "$key$value" =~ ^[[:space:]]*$ ]] && continue
      if [[ "$key" != net.core.rps_sock_flow_entries || ! "$value" =~ ^[0-9]+$ ]]; then
        warn "$(np_msg 'RPS sysctl 原值记录无效，保留回退状态。' 'Invalid RPS sysctl snapshot; keeping rollback state.')"
        failed=1; continue
      fi
      sysctl_records=$((sysctl_records + 1))
      if ! sysctl -w "$key=$value" >/dev/null 2>&1 || ! sysctl_matches "$key" "$value"; then
        warn "$(np_msg '无法恢复 %s' 'Unable to restore %s' "$key")"; failed=1
      fi
    done < "$STATE_DIR/rps-sysctl.before" || failed=1
    if ((sysctl_records == 0)); then
      warn "$(np_msg 'RPS sysctl 原值记录为空，保留回退状态。' 'RPS sysctl snapshot is empty; keeping rollback state.')"
      failed=1
    fi
  fi
  return "$failed"
}

remove_state_files() {
  local dir entry nonempty
  # Remove change markers before snapshots. A partially failed rm must never
  # leave a change marker behind after deleting the snapshot needed to retry.
  # Keep original-values until all other owned files have been removed.
  if ! rm -f -- "$STATE_DIR/rps-sysctl-changed" || ! rm -f -- \
    "$STATE_DIR/gai-changed" \
    "$STATE_DIR/iptables4-added" \
    "$STATE_DIR/nic-ring-changed" \
    "$STATE_DIR/rps-changed" || ! rm -f -- \
    "$STATE_DIR/ulimit.before" \
    "$STATE_DIR/interface" \
    "$STATE_DIR/ethtool-g.before" \
    "$STATE_DIR/nic-ring.before" \
    "$STATE_DIR/rps.before" \
    "$STATE_DIR/rps-sysctl.before" \
    "$BACKUP_DIR/bbr-file" \
    "$BACKUP_DIR/bbr-file.missing" \
    "$BACKUP_DIR/bbr-module-file" \
    "$BACKUP_DIR/bbr-module-file.missing" \
    "$BACKUP_DIR/sysctl-file" \
    "$BACKUP_DIR/sysctl-file.missing" \
    "$BACKUP_DIR/limits-file" \
    "$BACKUP_DIR/limits-file.missing" \
    "$BACKUP_DIR/gai-file" \
    "$BACKUP_DIR/gai-file.missing"; then
    warn "$(np_msg '无法删除保存的状态文件；修复错误后可重试清理。' 'Unable to remove saved state files; retry cleanup after fixing the error.')"
    return 1
  fi
  if ! rm -f -- "$STATE_DIR/original-values"; then
    warn "$(np_msg '无法删除原值状态标记。' 'Unable to remove the saved-state marker.')"
    return 1
  fi
  for dir in "$BACKUP_DIR" "$STATE_DIR"; do
    [[ -d "$dir" ]] || continue
    nonempty=0
    for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
      if [[ -e "$entry" || -L "$entry" ]]; then nonempty=1; break; fi
    done
    if (( nonempty )); then
      warn "$(np_msg '目录中存在非本工具文件，予以保留：%s' 'Retaining directory containing unowned files: %s' "$dir")"
    elif ! rmdir -- "$dir"; then
      warn "$(np_msg '无法删除空状态目录：%s' 'Unable to remove empty state directory: %s' "$dir")"
      return 1
    fi
  done
  return 0
}

rollback_internal() {
  local previous_iface name path failed=0 keep_state=0
  [[ "${1:-}" != --keep-state ]] || keep_state=1
  if [[ -f "$STATE_DIR/interface" ]]; then
    previous_iface="$(cat "$STATE_DIR/interface")" || failed=1
    NIC_IFACE="${previous_iface:-}"
  fi
  restore_rps || failed=1
  restore_nic_ring || failed=1
  remove_mss_rule || failed=1
  restore_original_values || failed=1
  # Restore only files with recorded backup metadata.
  for name in bbr-file bbr-module-file sysctl-file limits-file gai-file; do
    if [[ -e "$BACKUP_DIR/$name" || -L "$BACKUP_DIR/$name" || -e "$BACKUP_DIR/$name.missing" ]]; then
      path="$(managed_file_path "$name")" || { failed=1; continue; }
      restore_file "$path" "$name" || failed=1
    fi
  done
  if (( failed == 0 )); then
    if ((keep_state == 0)); then remove_state_files || failed=1; fi
  else
    warn "$(np_msg '回退未完成，备份已保留；检查错误后重试回退。' 'Rollback is incomplete. Backups are retained; inspect errors and retry rollback.')"
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
  if [[ "${AUTO_TUNE_ACTIVE:-0}" == 1 ]] && ((${auto_cancel_code:-0})); then return "$auto_cancel_code"; fi
  if ((${#SYSCTL_KEYS[@]} == 0)); then
    log "$(np_msg '当前支持的参数已满足建议，无需改动。' 'Supported parameters already meet the recommendations; no changes are needed.')"
    return 0
  fi
  if ((yes == 0)); then
    read -r -p "$(np_msg '按以上计划应用并持久化？[y/N] ' 'Apply and persist the plan above? [y/N] ')" answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]] || { log "$(np_msg '已取消。' Cancelled.)"; return 0; }
  fi
  NIC_IFACE="$(default_interface || true)"
  prepare_state sysctl-file || return 1
  if [[ "${AUTO_TUNE_ACTIVE:-0}" == 1 ]]; then
    ((${auto_cancel_code:-0} == 0)) || return "$auto_cancel_code"
    AUTO_TUNE_WRITING=1
  fi
  install -d -m 0755 /etc/sysctl.d || { transaction_failed "$(np_msg '无法创建 sysctl 目录。' 'Cannot create sysctl directory.')"; return 1; }
  write_sysctl_file || { transaction_failed "$(np_msg '无法保存计划参数。' 'Cannot persist planned parameters.')"; return 1; }
  apply_sysctl_values || { transaction_failed "$(np_msg '无法应用或核验计划参数。' 'Cannot apply or verify planned parameters.')"; return 1; }
  log "$(np_msg '计划已应用且读回一致；后续可用 verify 检查配置漂移。' 'Plan applied and read back consistently; use verify to check for later configuration drift.')"
}

apply_ipv4_preference_only() {
  if gai_preference_active; then
    log "$(np_msg 'IPv4 优先规则已存在，未修改，也未创建回退记录。' 'IPv4 preference already exists; no changes or rollback claim created.')"
    return 0
  fi
  SYSCTL_KEYS=(); SYSCTL_TARGETS=()
  NIC_IFACE="$(default_interface || true)"
  prepare_state gai-file || return 1
  apply_gai_preference || { transaction_failed "$(np_msg '无法写入 IPv4 优先规则。' 'Unable to write IPv4 preference.')"; return 1; }
  log "$(np_msg '已应用 IPv4 优先规则并保存备份。' 'IPv4 preference applied and backed up.')"
}

apply_bbr_only() {
  load_bbr_module || return 1
  SYSCTL_KEYS=(net.core.default_qdisc net.ipv4.tcp_congestion_control)
  SYSCTL_TARGETS=([net.core.default_qdisc]=fq [net.ipv4.tcp_congestion_control]=bbr)
  NIC_IFACE="$(default_interface || true)"
  prepare_state bbr-file bbr-module-file sysctl-file || return 1
  install -d -m 0755 /etc/sysctl.d || { transaction_failed "$(np_msg '无法创建 sysctl 目录。' 'Cannot create sysctl directory.')"; return 1; }
  write_bbr_file || { transaction_failed "$(np_msg '无法写入 BBR 配置。' 'Cannot write BBR configuration.')"; return 1; }
  write_sysctl_file || { transaction_failed "$(np_msg '无法保存 BBR 配置。' 'Cannot persist BBR configuration.')"; return 1; }
  write_bbr_module_file || { transaction_failed "$(np_msg '无法保存 BBR 模块配置。' 'Cannot persist BBR module.')"; return 1; }
  sysctl -w net.core.default_qdisc=fq >/dev/null || { transaction_failed "$(np_msg '无法设置默认 qdisc。' 'Cannot set default qdisc.')"; return 1; }
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || { transaction_failed "$(np_msg '无法切换到 BBR。' 'Cannot select BBR.')"; return 1; }
  if ! bbr_fq_active; then
    transaction_failed "$(np_msg 'BBR/默认 FQ 读回核验失败。' 'BBR/default FQ read-back failed.')"
    return 1
  fi
  show_bbr_dashboard
  log "$(np_msg '已应用 BBR + fq 并保存备份。' 'BBR + fq applied and backed up.')"
}

apply_nic_only() {
  SYSCTL_KEYS=(); SYSCTL_TARGETS=()
  NIC_IFACE="$(default_interface || true)"
  prepare_state || return 1
  apply_nic_ring || { transaction_failed "$(np_msg '无法设置网卡 ring。' 'Unable to set NIC ring.')"; return 1; }
  apply_rps || { transaction_failed "$(np_msg '无法设置 RPS。' 'Unable to set RPS.')"; return 1; }
  show_nic_dashboard "$(nproc 2>/dev/null || echo 0)"
}

apply_sysctl_values() {
  local key
  for key in "${SYSCTL_KEYS[@]}"; do
    if ! sysctl -w "$key=${SYSCTL_TARGETS[$key]}" >/dev/null || ! sysctl_matches "$key" "${SYSCTL_TARGETS[$key]}"; then
      warn "$(np_msg '无法应用并核验 %s' 'Unable to apply and verify %s' "$key")"
      return 1
    fi
  done
}

rollback_tuning() {
  local name has_record=0
  need_root
  if [[ ! -d "$STATE_DIR" || -L "$STATE_DIR" ]]; then
    warn "$(np_msg '未找到原值状态记录，未执行恢复。' 'No saved state found; nothing was restored.')"
    return 1
  fi
  [[ -f "$STATE_DIR/original-values" && ! -L "$STATE_DIR/original-values" ]] && has_record=1
  # Interrupted preparation can leave complete file backups without kernel records.
  for name in bbr-file bbr-module-file sysctl-file limits-file gai-file; do
    if [[ -e "$BACKUP_DIR/$name" || -L "$BACKUP_DIR/$name" || -f "$BACKUP_DIR/$name.missing" ]]; then
      has_record=1
      break
    fi
  done
  if ((has_record == 0)); then
    warn "$(np_msg '未找到可识别的回退记录，未执行恢复；现有文件保留。' 'No recognizable rollback records found; nothing was restored. Existing files are retained.')"
    return 1
  fi
  log "$(np_msg '正在恢复保存的原值和受管文件。' 'Restoring saved values and owned files.')"
  rollback_internal || return 1
  log "$(np_msg '回退已完成并通过核验。' 'Rollback completed and verified.')"
  show_status
}

install_script_atomic() {
  local source="$1" destination="$2" tmp
  [[ -f "$source" && -s "$source" ]] || { warn "$(np_msg '安装源文件不存在或为空。' 'Installation source is missing or empty.')"; return 1; }
  [[ ! -L "$destination" ]] || { warn "$(np_msg '安装目标是符号链接，拒绝覆盖：%s' 'Installation target is a symbolic link; refusing to replace: %s' "$destination")"; return 1; }
  bash -n "$source" || { warn "$(np_msg '脚本语法检查失败，保留当前版本。' 'Script syntax check failed; keeping the current version.')"; return 1; }
  install -d -m 0755 "$(dirname "$destination")" || return 1
  tmp="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
  if ! install -m 0755 "$source" "$tmp" || ! bash -n "$tmp" || ! mv -fT -- "$tmp" "$destination"; then
    rm -f -- "$tmp"
    warn "$(np_msg '脚本安装失败，未替换当前版本。' 'Script installation failed; the current version was not replaced.')"
    return 1
  fi
}

install_shortcuts() {
  if [[ ! -e "$SHORTCUT_PATH" && ! -L "$SHORTCUT_PATH" ]]; then
    ln -s "$INSTALL_PATH" "$SHORTCUT_PATH" || return 1
    log "$(np_msg '已创建快捷命令：netpilot' 'Created shortcut command: netpilot')"
  elif [[ -L "$SHORTCUT_PATH" && "$(readlink "$SHORTCUT_PATH")" == "$INSTALL_PATH" ]]; then
    :
  else
    warn "$(np_msg '%s 已被其他文件占用，未覆盖。' '%s is occupied by another file; not replaced.' "$SHORTCUT_PATH")"
  fi
  return 0
}

install_local_copy() {
  [[ -f "$SCRIPT_PATH" && -s "$SCRIPT_PATH" ]] || {
    warn "$(np_msg '安装源文件不存在或为空，未打开菜单。' 'Installation source is missing or empty; the menu was not opened.')"
    return 1
  }
  installed_script_owned "$SCRIPT_PATH" || {
    warn "$(np_msg '安装源不是可识别的 NetPilot 脚本，未替换当前版本。' 'Installation source is not a recognizable NetPilot script; the current version was not replaced.')"
    return 1
  }
  if [[ -e "$INSTALL_PATH" || -L "$INSTALL_PATH" ]] && ! installed_script_owned; then
    warn "$(np_msg '安装位置已有非本工具文件或符号链接，未覆盖：%s' 'Installation path contains an unowned file or symbolic link; not replaced: %s' "$INSTALL_PATH")"
    return 1
  fi
  if [[ "$SCRIPT_PATH" == "$INSTALL_PATH" ]]; then
    install_shortcuts || return 1
    return 0
  fi

  if [[ -e "$INSTALL_PATH" ]] && ! cmp -s "$SCRIPT_PATH" "$INSTALL_PATH"; then
    log "$(np_msg '检测到本工具的已有版本，正在更新安装。' 'An existing NetPilot version was found; updating the installation.')"
  fi
  install_script_atomic "$SCRIPT_PATH" "$INSTALL_PATH" || return 1
  install_shortcuts || return 1
  [[ -z "$SOURCE_SNAPSHOT" ]] || rm -f -- "$SOURCE_SNAPSHOT" || return 1
  exec 9>&-
  exec bash "$INSTALL_PATH" "$@"
}

check_update() {
  local tmp
  if [[ -e "$INSTALL_PATH" || -L "$INSTALL_PATH" ]] && ! installed_script_owned; then
    warn "$(np_msg '无法确认安装文件归属，拒绝更新：%s' 'Cannot establish installation ownership; refusing to update: %s' "$INSTALL_PATH")"
    return 1
  fi
  command -v curl >/dev/null 2>&1 || die "$(np_msg '找不到 curl，无法更新。' 'curl is unavailable; cannot update.')"

  tmp="$(mktemp)" || return 1
  if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --output "$tmp" "$UPDATE_URL"; then
    rm -f -- "$tmp"
    warn "$(np_msg 'GitHub 下载失败，未替换当前脚本。' 'GitHub download failed; the current script was not replaced.')"
    return 1
  fi
  if [[ ! -s "$tmp" ]] || ! bash -n "$tmp"; then
    rm -f -- "$tmp"
    warn "$(np_msg '下载的脚本为空或语法检查失败，未替换当前脚本。' 'Downloaded script is empty or has invalid syntax; the current script was not replaced.')"
    return 1
  fi
  if ! installed_script_owned "$tmp"; then
    rm -f -- "$tmp"
    warn "$(np_msg '下载内容不是可识别的 NetPilot 脚本，保留当前版本。' 'Downloaded content is not a recognizable NetPilot script; keeping the current version.')"
    return 1
  fi
  if ! install_script_atomic "$tmp" "$INSTALL_PATH"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp" || return 1
  install_shortcuts || return 1
  log "$(np_msg '已从 GitHub 更新 NetPilot，正在重新载入。' 'NetPilot was updated from GitHub; reloading.')"
  exec 9>&-
  exec bash "$INSTALL_PATH"
}

installed_script_owned() {
  local candidate="${1:-$INSTALL_PATH}"
  [[ -f "$candidate" && ! -L "$candidate" ]] || return 1
  # Inspect identity as data; never execute a candidate to establish ownership.
  grep -Fqx "readonly UPDATE_URL=\"$UPDATE_URL\"" "$candidate" &&
    grep -Fqx 'uninstall_own_script() {' "$candidate"
}

remove_automatic_reports() {
  local root
  local -a roots=()
  for root in "$AUTO_REPORT_ROOT" "$AUTO_LEGACY_REPORT_ROOT"; do
    [[ ! -e "$root" && ! -L "$root" ]] || roots+=("$root")
  done
  ((${#roots[@]})) || return 0
  command -v python3 >/dev/null 2>&1 || {
    warn "$(np_msg '清理报告需要 python3，未卸载。' 'Python 3 is required to clean reports; NetPilot was not removed.')"
    return 1
  }
  auto_report cleanup "${roots[@]}"
}

uninstall_own_script() {
  local answer option name rollback_requested=0 has_record=0 shortcut_removed=0
  local recovery_dir='' recovery_tmp='' recovery_target='' recovery_failed=0
  for option in "$@"; do
    case "$option" in
      --rollback) rollback_requested=1 ;;
      -h|--help) usage; return 0 ;;
      *) warn "$(np_msg '未知卸载选项：%s' 'Unknown uninstall option: %s' "$option")"; return 2 ;;
    esac
  done
  if ((rollback_requested)); then
    np_msg '\n将先恢复保存的配置，再清理默认报告并删除程序；恢复失败则停止卸载。\n' '\nRestore saved configuration, then clean default reports and remove the tool; failed restoration stops removal.\n'
  else
    np_msg '\n将删除程序和默认目录中的工具报告，保留调优配置和回退备份。\n' '\nRemove the tool and its default reports; keep tuning configuration and rollback backups.\n'
  fi
  np_msg '  脚本：%s\n  快捷命令：%s\n' '  Script: %s\n  Shortcut: %s\n' "$INSTALL_PATH" "$SHORTCUT_PATH"
  np_msg '下载副本、自定义报告目录和无法识别的文件保留；不会删除 3x-ui、Xray 或其他服务。\n' 'Source copies, custom report directories and unrecognized files are kept; 3x-ui, Xray and other services are not removed.\n'
  read -r -p "$(np_msg '确定卸载 NetPilot？[y/N] ' 'Uninstall NetPilot? [y/N] ')" answer || {
    log "$(np_msg '已取消卸载。' 'Uninstall cancelled.')"; return 0;
  }
  [[ "$answer" =~ ^[Yy]$ ]] || { log "$(np_msg '已取消卸载。' 'Uninstall cancelled.')"; return 0; }

  if [[ -e "$INSTALL_PATH" || -L "$INSTALL_PATH" ]]; then
    installed_script_owned || { warn "$(np_msg '无法确认安装文件归属，拒绝删除：%s' 'Cannot establish installation ownership; refusing to delete: %s' "$INSTALL_PATH")"; return 1; }
  fi
  if ((rollback_requested)); then
    [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]] || {
      warn "$(np_msg '未找到回退记录，未卸载；仅删除工具请使用 uninstall。' 'No rollback state found; NetPilot was not removed. Use uninstall to keep the current configuration.')"
      return 1
    }
    [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || { warn "$(np_msg '运行状态路径不是普通目录，拒绝卸载。' 'The state path is not a regular directory; refusing to uninstall.')"; return 1; }
    [[ -f "$STATE_DIR/original-values" && ! -L "$STATE_DIR/original-values" ]] && has_record=1
    # A completed file backup can precede the original-values marker if state
    # preparation was interrupted. Keep those recoverable snapshots usable.
    for name in bbr-file bbr-module-file sysctl-file limits-file gai-file; do
      if [[ -e "$BACKUP_DIR/$name" || -L "$BACKUP_DIR/$name" || -f "$BACKUP_DIR/$name.missing" ]]; then
        has_record=1
        break
      fi
    done
    ((has_record)) || {
      warn "$(np_msg '未找到可识别的回退记录，未执行恢复或卸载；现有文件保留。' 'No recognizable rollback records found; nothing was restored or uninstalled. Existing files are retained.')"
      return 1
    }
    rollback_internal --keep-state || return 1
    # Keep only the known recovery records needed to compensate a final state
    # cleanup failure. Never copy the state directory or its unowned contents.
    recovery_dir="$(mktemp -d /tmp/netpilot-uninstall.XXXXXX)" || return 1
    if ! { [[ ! -e "$INSTALL_PATH" ]] || cp -p -- "$INSTALL_PATH" "$recovery_dir/program"; } ||
      ! { if [[ -f "$STATE_DIR/original-values" && ! -L "$STATE_DIR/original-values" ]]; then
          cp -p -- "$STATE_DIR/original-values" "$recovery_dir/original-values"
        else
          # File-only recovery has completed; an empty original-values record
          # permits cleanup to retry without inventing kernel values.
          : > "$recovery_dir/original-values"
        fi; }; then
      warn "$(np_msg '无法暂存卸载恢复文件，程序和回退记录保留；请检查：%s' 'Unable to stage uninstall recovery files; the tool and rollback records are retained. Inspect: %s' "$recovery_dir")"
      return 1
    fi
  fi
  if ! remove_automatic_reports; then
    [[ -z "$recovery_dir" ]] || rm -rf -- "$recovery_dir" || warn "$(np_msg '无法清理临时恢复副本：%s' 'Unable to remove temporary recovery copies: %s' "$recovery_dir")"
    return 1
  fi
  if [[ -L "$SHORTCUT_PATH" && "$(readlink "$SHORTCUT_PATH")" == "$INSTALL_PATH" ]]; then
    if ! rm -f -- "$SHORTCUT_PATH"; then
      [[ -z "$recovery_dir" ]] || rm -rf -- "$recovery_dir" || warn "$(np_msg '无法清理临时恢复副本：%s' 'Unable to remove temporary recovery copies: %s' "$recovery_dir")"
      return 1
    fi
    shortcut_removed=1
  fi
  if ! rm -f -- "$INSTALL_PATH"; then
    if ((rollback_requested && shortcut_removed)); then
      ln -sT -- "$INSTALL_PATH" "$SHORTCUT_PATH" || warn "$(np_msg '无法恢复快捷命令，未覆盖现有路径：%s' 'Unable to restore the shortcut; no existing path was replaced: %s' "$SHORTCUT_PATH")"
    fi
    [[ -z "$recovery_dir" ]] || rm -rf -- "$recovery_dir" || warn "$(np_msg '无法清理临时恢复副本：%s' 'Unable to remove temporary recovery copies: %s' "$recovery_dir")"
    return 1
  fi
  if ((rollback_requested)); then
    if ! remove_state_files; then
      # Restore through exclusive hard-link publication, so a concurrently
      # created file or symlink is never overwritten by compensation.
      if [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then
        mkdir -m 0700 -- "$STATE_DIR" || recovery_failed=1
      fi
      for name in original-values program; do
        [[ -f "$recovery_dir/$name" ]] || continue
        if [[ "$name" == program ]]; then recovery_target="$INSTALL_PATH"
        elif [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then recovery_target="$STATE_DIR/original-values"
        else recovery_failed=1; continue; fi
        if [[ -e "$recovery_target" || -L "$recovery_target" ]]; then
          if [[ "$name" == original-values && -f "$recovery_target" && ! -L "$recovery_target" ]] &&
            cmp -s -- "$recovery_dir/$name" "$recovery_target"; then continue; fi
          recovery_failed=1
          continue
        fi
        recovery_tmp="$(mktemp "${recovery_target}.recover.XXXXXX")" || { recovery_failed=1; continue; }
        if ! cp -p -- "$recovery_dir/$name" "$recovery_tmp" || ! ln -T -- "$recovery_tmp" "$recovery_target"; then recovery_failed=1; fi
        rm -f -- "$recovery_tmp" || { recovery_failed=1; warn "$(np_msg '无法删除临时恢复文件：%s' 'Unable to remove temporary recovery file: %s' "$recovery_tmp")"; }
      done
      if ((shortcut_removed)); then
        if [[ -f "$recovery_dir/program" ]] && ! installed_script_owned; then recovery_failed=1
        else ln -sT -- "$INSTALL_PATH" "$SHORTCUT_PATH" || recovery_failed=1; fi
      fi
      if ((recovery_failed)); then
        warn "$(np_msg '卸载未完成，补偿恢复遇到错误；未覆盖现有文件，恢复副本保留在：%s' 'Uninstall is incomplete and compensation encountered errors; existing files were not overwritten. Recovery copies remain at: %s' "$recovery_dir")"
      else
        warn "$(np_msg '状态清理失败，程序和重试记录已恢复；修复错误后可重试相同卸载命令。' 'State cleanup failed; the tool and retry records were restored. Fix the error and retry the same uninstall command.')"
        rm -rf -- "$recovery_dir" || warn "$(np_msg '无法清理临时恢复副本：%s' 'Unable to remove temporary recovery copies: %s' "$recovery_dir")"
      fi
      return 1
    fi
    rm -rf -- "$recovery_dir" || warn "$(np_msg '无法清理临时恢复副本：%s' 'Unable to remove temporary recovery copies: %s' "$recovery_dir")"
    log "$(np_msg '回退已完成，程序、自有快捷命令和可识别的默认报告已清理；源码副本保留。' 'Rollback completed; the tool, its owned shortcut and recognized default reports were removed. Source copies are retained.')"
  else
    log "$(np_msg '程序、自有快捷命令和可识别的默认报告已清理；调优配置和回退备份保留。' 'The tool, its owned shortcut and recognized default reports were removed; tuning configuration and rollback backups are retained.')"
  fi
  exit 0
}

uninstall_menu() {
  local choice
  np_msg '\n卸载方式：\n  1. 卸载工具并清理默认报告，保留调优配置和备份（默认）\n  2. 回滚并卸载，清理默认报告；恢复失败则停止\n  0. 取消\n' '\nUninstall mode:\n  1. Remove the tool and default reports; keep tuning configuration and backups (default)\n  2. Roll back and uninstall, cleaning default reports; stop if restoration fails\n  0. Cancel\n'
  read -r -p "$(np_msg '请选择 [1/2/0，默认1]：' 'Select [1/2/0; default 1]: ')" choice || {
    log "$(np_msg '已取消卸载。' 'Uninstall cancelled.')"; return 0;
  }
  case "$choice" in
    1|'') run_mutation uninstall_own_script ;;
    2) run_mutation uninstall_own_script --rollback ;;
    0) log "$(np_msg '已取消卸载。' 'Uninstall cancelled.')" ;;
    *) warn "$(np_msg '无效的卸载选项，未执行卸载。' 'Invalid uninstall mode; nothing was removed.')"; return 2 ;;
  esac
}

status_badge() {
  if [[ "$1" == 1 ]]; then
    np_msg '%b[已激活]%b' '%b[active]%b' "$GREEN" "$NC"
  else
    np_msg '%b[未开启]%b' '%b[inactive]%b' "$RED" "$NC"
  fi
}

show_menu() {
  local algorithm qdisc ipv4_active=0 bbr_active=0
  algorithm="$(sysctl_value net.ipv4.tcp_congestion_control || echo unknown)"
  qdisc="$(sysctl_value net.core.default_qdisc || echo unknown)"
  if [[ -f "$GAI_FILE" ]] && grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' "$GAI_FILE"; then
    ipv4_active=1
  fi
  [[ "$algorithm" == bbr && "$qdisc" == fq ]] && bbr_active=1
  printf '\n%b==================================================%b\n' "$YELLOW" "$NC"
  np_msg '%b            NetPilot 网络诊断与调优            %b\n' '%b       NetPilot Network Diagnostics and Tuning       %b\n' "$YELLOW" "$NC"
  np_msg '%b                    快捷命令: netpilot                    %b\n' '%b                  Shortcut: netpilot                  %b\n' "$GREEN" "$NC"
  printf '%b==================================================%b\n' "$YELLOW" "$NC"
  np_msg '\n常用操作\n' '\nCommon tasks\n'
  np_msg '  9. 一键调优（自动前测/调优/复测/对比，默认128MiB）\n' '  9. One-click tuning (measure/tune/retest/compare; default 128MiB)\n'
  np_msg ' 10. 查看最新报告\n' ' 10. View latest report\n'
  np_msg '  8. 诊断与独立测速\n' '  8. Diagnostics and separate benchmarks\n'
  np_msg '\n维护\n' '\nMaintenance\n'
  np_msg '  5. 恢复首次原值\n' '  5. Restore the original baseline\n'
  np_msg '  6. 更新 NetPilot\n' '  6. Update NetPilot\n'
  np_msg '  7. 卸载（清理默认报告，保留配置；可选回滚）\n' '  7. Uninstall (clean default reports, keep settings; optional rollback)\n'
  np_msg '\n高级设置（按需使用）\n' '\nAdvanced settings (optional)\n'
  np_msg '  1. IPv4 优先配置 %s\n' '  1. IPv4 preference %s\n' "$(status_badge "$ipv4_active")"
  np_msg '  2. BBR 与默认 FQ %s\n' '  2. BBR and default FQ %s\n' "$(status_badge "$bbr_active")"
  np_msg '  3. 手动调优（预览后确认）\n' '  3. Manual tuning (preview and confirm)\n'
  np_msg '  4. 网卡 ring / RPS\n' '  4. NIC ring / RPS\n'
  printf '\n'
  np_msg '  L. 语言 / Language：简体中文 → English\n' '  L. Language / 语言: English → 简体中文\n'
  np_msg '  0. 退出脚本\n' '  0. Exit\n'
  draw_line
  np_msg '当前算法：%s | 默认队列：%s\n' 'Current congestion control: %s | default qdisc: %s\n' "$algorithm" "$qdisc"
  draw_line
}

menu() {
  local choice
  while true; do
    show_menu
    read -r -p "$(np_msg '请选择 [0-10, L]: ' 'Select [0-10, L]: ')" choice || return 0
    case "$choice" in
      1) run_mutation apply_ipv4_preference_only || warn "$(np_msg '操作失败。' 'Operation failed.')" ;;
      2) run_mutation apply_bbr_only || warn "$(np_msg '操作失败。' 'Operation failed.')" ;;
      3) run_mutation menu_apply_tuning || warn "$(np_msg '操作失败。' 'Operation failed.')" ;;
      4) run_mutation apply_nic_only || warn "$(np_msg '操作失败。' 'Operation failed.')" ;;
      5) run_mutation rollback_tuning || warn "$(np_msg '回退未完成。' 'Rollback incomplete.')" ;;
      6) run_mutation check_update ;;
      7) uninstall_menu || warn "$(np_msg '卸载未完成。' 'Uninstall did not complete.')" ;;
      8) feature_menu || warn "$(np_msg '诊断或测速未完成。' 'The diagnostics or measurement operation did not complete.')" ;;
      9) run_mutation auto_tune || warn "$(np_msg '自动调优流程未完成，请查看上方错误信息。' 'Automatic tuning did not complete; inspect the error above.')" ;;
      10) report_command || true ;;
      0) return 0 ;;
      l|L) if [[ "${NETPILOT_LANG:-zh}" == en ]]; then np_set_language zh; else np_set_language en; fi ;;
      *) np_msg '无效选项。\n' 'Invalid option.\n' ;;
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

adaptive_valid_rtt_target() {
  [[ ${#1} -le 253 && "$1" =~ ^[a-zA-Z0-9_:][a-zA-Z0-9_.:%-]*$ ]]
}

adaptive_measure_rtt() {
  local target="${1:-}" dep output average
  adaptive_valid_rtt_target "$target" || {
    np_msg '请输入有效的目标主机名、IPv4 或 IPv6 地址。\n' 'Provide a valid target hostname, IPv4 or IPv6 address.\n' >&2
    return 2
  }
  for dep in ping timeout awk; do
    command -v "$dep" >/dev/null 2>&1 || {
      np_msg '自动测延迟需要 %s；请安装后重试，或手动填写延迟。\n' 'Automatic latency measurement requires %s; install it or enter latency manually.\n' "$dep" >&2
      return 1
    }
  done
  # Foreground mode lets terminal cancellation reach ping as well as timeout.
  if ! output="$(LC_ALL=C timeout --foreground --kill-after=1 8s ping -n -c 5 -W 1 -- "$target" 2>/dev/null)"; then
    np_msg '无法测得 %s 的延迟：目标未响应、测量失败或超时。请检查目标或手动填写延迟。\n' 'Could not measure latency to %s: no response, probe failure or timeout. Check the target or enter latency manually.\n' "$target" >&2
    return 1
  fi
  # iputils and BusyBox use different summary labels and received-count text.
  if ! average="$(LC_ALL=C awk '
    /packets transmitted/ {
      packet_lines++; transmitted=$1
      for(i=2;i<=NF;i++) {
        word=$i; gsub(/,/, "", word)
        if(word=="received") {
          received=$(i-1)
          if(received=="packets" && i>2) received=$(i-2)
          gsub(/,/, "", received)
        }
      }
    }
    /^(rtt|round-trip)[[:space:]]/ {
      stats_lines++
      if(split($0, sides, "=")==2 && split(sides[2], values, "/")>=3) {
        average=values[2]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", average)
      }
    }
    END {
      if(packet_lines==1 && stats_lines==1 && transmitted=="5" &&
         received ~ /^[0-9]+$/ && received>=3 && received<=5 &&
         average ~ /^[0-9]+([.][0-9]+)?$/ && average>0 && average<=60000)
        print average
      else exit 1
    }' <<< "$output")"; then
    np_msg '未获得至少 3 次有效应答及可用平均延迟；请更换目标或手动填写延迟。\n' 'At least 3 valid replies and a usable average latency are required; try another target or enter latency manually.\n' >&2
    return 1
  fi
  printf '%s\n' "$average"
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
    PLAN_NOTES+=("$(np_msg '%s：当前内核未提供，跳过。' '%s: unavailable in the current kernel; skipped.' "$key")")
    return 0
  fi
  current="$(awk '{$1=$1; print}' <<< "$current")"
  [[ "$current" == "$target" ]] && return 0
  SYSCTL_KEYS+=("$key")
  SYSCTL_TARGETS["$key"]="$target"
  PLAN_REASONS["$key"]="$reason"
}

adaptive_plan() {
  local memory available limit key current minimum initial maximum reason bandwidth_supplied=0 rtt_supplied=0 target_supplied=0
  PLAN_PROFILE=balanced; PLAN_BANDWIDTH=""; PLAN_RTT=""; PLAN_RTT_TARGET=""; PLAN_MEMORY_BYTES=""; PLAN_BUFFER_BYTES=""
  SYSCTL_KEYS=(); SYSCTL_TARGETS=(); PLAN_REASONS=(); PLAN_NOTES=()
  while (( $# )); do
    case "$1" in
      --profile|--bandwidth|--rtt|--rtt-target)
        if (( $# < 2 )); then np_msg '参数 %s 缺少值。\n' 'Missing value for %s.\n' "$1" >&2; return 2; fi
        case "$1" in
          --profile) PLAN_PROFILE="$2" ;;
          --bandwidth) PLAN_BANDWIDTH="$2"; bandwidth_supplied=1 ;;
          --rtt) PLAN_RTT="$2"; rtt_supplied=1 ;;
          --rtt-target) PLAN_RTT_TARGET="$2"; target_supplied=1 ;;
        esac
        shift 2 ;;
      *) np_msg '未知参数：%s\n' 'Unknown option: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  case "$PLAN_PROFILE" in balanced|proxy|bulk) ;; *) np_msg 'profile 必须是 balanced、proxy 或 bulk。\n' 'profile must be balanced, proxy or bulk.\n' >&2; return 2 ;; esac
  if ((rtt_supplied && target_supplied)); then
    np_msg '--rtt 与 --rtt-target 只能选择一种。\n' 'Choose either --rtt or --rtt-target, not both.\n' >&2
    return 2
  fi
  if ((target_supplied)); then
    if ! adaptive_positive_number "$PLAN_BANDWIDTH" 1000000; then
      np_msg '--rtt-target 需要同时提供正数 --bandwidth Mbps（≤1000000）。\n' '--rtt-target requires a positive --bandwidth in Mbps (<=1000000).\n' >&2
      return 2
    fi
    adaptive_valid_rtt_target "$PLAN_RTT_TARGET" || {
      np_msg '请输入有效的目标主机名、IPv4 或 IPv6 地址。\n' 'Provide a valid target hostname, IPv4 or IPv6 address.\n' >&2
      return 2
    }
  elif ((bandwidth_supplied || rtt_supplied)); then
    if ! adaptive_positive_number "$PLAN_BANDWIDTH" 1000000 || ! adaptive_positive_number "$PLAN_RTT" 60000; then
      np_msg '请同时提供正数 --bandwidth Mbps（≤1000000）和 --rtt ms（≤60000）。\n' 'Provide both positive --bandwidth Mbps (<=1000000) and --rtt ms (<=60000).\n' >&2
      return 2
    fi
  fi
  memory="$(adaptive_memory_bytes)" || { np_msg '无法确定有效内存，未生成修改计划。\n' 'Cannot determine effective memory; no change plan was generated.\n' >&2; return 1; }
  PLAN_MEMORY_BYTES="$memory"
  if ((target_supplied)); then
    np_msg '正在测量到 %s 的往返延迟（最多约 9 秒）…\n' 'Measuring round-trip latency to %s (up to about 9 seconds)...\n' "$PLAN_RTT_TARGET" >&2
    PLAN_RTT="$(adaptive_measure_rtt "$PLAN_RTT_TARGET")" || return $?
  fi
  available="$(sysctl_value net.ipv4.tcp_available_congestion_control || true)"
  if [[ " $available " == *' bbr '* ]]; then
    adaptive_add_change net.ipv4.tcp_congestion_control bbr "$(np_msg '当前内核已提供 BBR；代际版本未确认。' 'BBR is available in this kernel; its generation is not established.')"
    adaptive_add_change net.core.default_qdisc fq "$(np_msg '设置新建队列的默认值；不会替换当前网卡队列。' 'Set the default for new queues; existing interface queues are not replaced.')"
  else
    PLAN_NOTES+=("$(np_msg '当前内核尚未提供 BBR；只读规划不加载模块或安装内核。' 'BBR is not currently available; read-only planning does not load modules or install kernels.')")
  fi
  adaptive_add_change net.ipv4.tcp_moderate_rcvbuf 1 "$(np_msg '保留接收缓冲区自动调节能力。' 'Preserve receive-buffer autotuning.')"
  if [[ -z "$PLAN_BANDWIDTH" ]]; then
    PLAN_NOTES+=("$(np_msg '未提供路径带宽与 RTT，保留现有缓冲区；未执行测速。' 'No path bandwidth/RTT provided; existing buffers are retained and no benchmark was run.')")
    return 0
  fi
  limit="$(adaptive_buffer_limit "$memory" "$PLAN_PROFILE" "$PLAN_BANDWIDTH" "$PLAN_RTT")"
  PLAN_BUFFER_BYTES="$limit"
  reason="$(np_msg '根据输入 BDP 和 %s 有效内存预算计算，上限 %s bytes；非预分配、非性能保证。' 'Computed from input BDP and the %s effective-memory budget: ceiling %s bytes; not preallocated and not a performance guarantee.' "$PLAN_PROFILE" "$limit")"
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
  PLAN_NOTES+=("$(np_msg '保守模式只提高不足的缓冲上限；不降低已有上限，也不增加每连接初始缓冲。' 'Conservative mode only raises insufficient buffer ceilings; it never lowers existing ceilings or increases initial per-connection buffers.')")
  PLAN_NOTES+=("$(np_msg 'tcp_mem、重试次数、ECN、TFO、TIME_WAIT、IPv4/IPv6 策略均保留；真实效果需要同条件复测。' 'tcp_mem, retries, ECN, TFO, TIME_WAIT and IPv4/IPv6 policy are retained; measure effects again under the same conditions.')")
}

adaptive_print_plan() {
  local key note
  np_msg '配置档：%s | 有效内存：%s bytes\n' 'Profile: %s | Effective memory: %s bytes\n' "$PLAN_PROFILE" "$PLAN_MEMORY_BYTES"
  if [[ -n "$PLAN_BANDWIDTH" ]]; then
    if [[ "${AUTO_TUNE_ACTIVE:-0}" == 1 ]]; then
      np_msg '实测规划：带宽 %s Mbps；TCP 建连延迟估计 %s ms；目标 %s。\n' 'Measured plan: bandwidth %s Mbps; TCP-connect latency estimate %s ms; endpoint %s.\n' "$PLAN_BANDWIDTH" "$PLAN_RTT" "$AUTO_TUNE_ENDPOINT"
    elif [[ -n "${PLAN_RTT_TARGET:-}" ]]; then
      np_msg '路径带宽：%s Mbps（用户输入）；RTT：%s ms（ping 测量，目标 %s）。\n' 'Path bandwidth: %s Mbps (user input); RTT: %s ms (measured with ping to %s).\n' "$PLAN_BANDWIDTH" "$PLAN_RTT" "$PLAN_RTT_TARGET"
    else
      np_msg '路径输入：%s Mbps / %s ms（用户输入；未自动声称为实测）\n' 'Path input: %s Mbps / %s ms (user input, not claimed as a measurement)\n' "$PLAN_BANDWIDTH" "$PLAN_RTT"
    fi
    np_msg '新建议缓冲上限：%s bytes（已有更高值不降低）\n' 'New recommended buffer ceiling: %s bytes (existing higher values are retained)\n' "$PLAN_BUFFER_BYTES"
  fi
  for key in "${SYSCTL_KEYS[@]}"; do
    np_msg '%s\n  当前：%s\n  建议：%s\n  原因：%s\n' '%s\n  Current: %s\n  Suggested: %s\n  Reason: %s\n' "$key" "$(sysctl_value "$key" || true)" "${SYSCTL_TARGETS[$key]}" "${PLAN_REASONS[$key]}"
  done
  if (( ${#SYSCTL_KEYS[@]} == 0 )); then np_msg '没有需要修改的支持参数。\n' 'No supported parameters need changes.\n'; fi
  for note in "${PLAN_NOTES[@]}"; do np_msg '说明：%s\n' 'Note: %s\n' "$note"; done
  np_msg '以上仅为计划，尚未应用。\n' 'This is a plan only; not applied.\n'
}

adaptive_show_plan() {
  adaptive_plan "$@" || return $?
  adaptive_print_plan
}

adaptive_doctor() {
  local iface memory cpus
  memory="$(adaptive_memory_bytes || true)"; cpus="$(adaptive_cpu_count || true)"
  np_msg '只读机器诊断（不安装、不测速、不加载模块）\n' 'Read-only machine diagnostics (no installation, benchmarks or module loading)\n'
  np_msg '内核：%s\n有效内存：%s bytes\n可用 CPU（含亲和性/配额）：%s\n' 'Kernel: %s\nEffective memory: %s bytes\nAvailable CPUs (affinity/quota): %s\n' "$(uname -r)" "${memory:-$(np_msg 未知 unknown)}" "${cpus:-$(np_msg 未知 unknown)}"
  np_msg '可用拥塞算法：%s\n当前拥塞算法：%s\n默认 qdisc：%s\n' 'Available congestion controls: %s\nCurrent congestion control: %s\nDefault qdisc: %s\n' \
    "$(sysctl_value net.ipv4.tcp_available_congestion_control || true)" \
    "$(sysctl_value net.ipv4.tcp_congestion_control || true)" \
    "$(sysctl_value net.core.default_qdisc || true)"
  iface="$(adaptive_default_interface || true)"
  if [[ -n "$iface" ]]; then
    np_msg '出口网卡：%s\n实际 qdisc（与默认值分开查看）：\n' 'Outbound interface: %s\nActual qdisc (distinct from the default):\n' "$iface"
    if command -v tc >/dev/null 2>&1; then tc -s qdisc show dev "$iface" || true
    else np_msg '未安装 tc，无法查看实际队列。\n' 'tc is unavailable; cannot inspect actual queues.\n'; fi
  else np_msg '未找到默认出口网卡。\n' 'No default outbound interface was found.\n'; fi
  [[ "$cpus" != 1 ]] || np_msg '单核环境：默认跳过 RPS，不承诺多核分摊。\n' 'Single-CPU environment: RPS is skipped by default; no multi-CPU distribution is claimed.\n'
  if [[ -f /etc/tuned/active_profile ]]; then
    np_msg '检测到 tuned 配置记录：%s；应用前需检查是否由外部调优器管理。\n' 'Detected tuned profile: %s; check external tuner ownership before applying.\n' "$(head -n 1 /etc/tuned/active_profile)"
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet tuned 2>/dev/null; then
    np_msg '警告：tuned 服务正在运行，可能覆盖或重设相同参数。\n' 'Warning: tuned is running and may overwrite or reset the same parameters.\n'
  fi
  np_msg 'BBR 代际版本与端到端性能未由本次诊断确认。\n' 'This diagnostic does not establish the BBR generation or end-to-end performance.\n'
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
      np_msg '不可读取 %-38s 期望=%s\n' 'Unreadable %-38s expected=%s\n' "$key" "${targets[$key]}"
      failures=$((failures + 1))
      continue
    fi
    current="$(awk '{$1=$1; print}' <<< "$current")"
    if [[ "$current" == "${targets[$key]}" ]]; then
      np_msg '一致 %-42s %s\n' 'Match %-42s %s\n' "$key" "$current"
    else
      np_msg '偏离 %-42s 当前=%s 持久配置=%s\n' 'Drift %-42s current=%s persistent=%s\n' "$key" "$current" "${targets[$key]}"
      failures=$((failures + 1))
    fi
  done
  if ((count == 0)); then
    printf '%s\n' "$(np_msg '未找到本工具的持久配置；不能据此判定已调优。' 'No NetPilot persistent configuration was found; this does not prove tuning was applied.')"
    return 1
  fi
  np_msg '检查 %s 项，偏离/不可读取 %s 项。只验证参数，不代表性能提升。\n' 'Checked %s parameters; drift/unreadable: %s. Parameter consistency only, not proof of performance gains.\n' "$count" "$failures"
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
        [[ $# -ge 2 && "$2" =~ ^[0-9]{1,2}$ ]] || { warn "$(np_msg '--seconds 需要1到60的整数。' '--seconds requires an integer from 1 to 60.')"; return 2; }
        seconds=$((10#$2))
        ((seconds >= 1 && seconds <= 60)) || { warn "$(np_msg '--seconds 需要1到60的整数。' '--seconds requires an integer from 1 to 60.')"; return 2; }
        shift 2 ;;
      *) warn "$(np_msg '未知诊断选项：%s' 'Unknown diagnostic option: %s' "$1")"; return 2 ;;
    esac
  done
  printf '%s\n' "$(np_msg '只读网络计数：计数可能包含其他业务；重传不是端到端丢包率。' 'Read-only network counters: counts may include other traffic; retransmissions are not end-to-end loss rates.')"
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] && before["$key"]="$value"
  done < <(network_counter_snapshot /proc)
  if ((seconds > 0)); then
    np_msg '观察 %s 秒（不发测速流量）…\n' 'Observing for %s seconds (no benchmark traffic)...\n' "$seconds"
    sleep "$seconds" || return 1
    while IFS=$'\t' read -r key value; do
      [[ -n "$key" ]] && after["$key"]="$value"
    done < <(network_counter_snapshot /proc)
  fi
  for key in softnet_dropped softnet_squeezed listen_overflows listen_drops tcp_retrans_segs tcp_out_segs; do
    if [[ ! ${before[$key]+exists} ]]; then
      np_msg '%-24s 不可读取\n' '%-24s unreadable\n' "$key"
      continue
    fi
    if ((seconds == 0)); then
      np_msg '%-24s 累计=%s\n' '%-24s cumulative=%s\n' "$key" "${before[$key]}"
    elif [[ ${after[$key]+exists} && ${after[$key]} -ge ${before[$key]} ]]; then
      delta=$((${after[$key]} - ${before[$key]}))
      np_msg '%-24s 增量=%s\n' '%-24s delta=%s\n' "$key" "$delta"
    else
      np_msg '%-24s 计数重置或不可读取，无法比较\n' '%-24s counter reset or unreadable; comparison unavailable\n' "$key"
    fi
  done
  printf '%s\n' "$(np_msg 'softnet_dropped 增长可提示接收积压；squeezed 增长可提示处理预算耗尽；需结合CPU和流量定位。' 'Rising softnet_dropped can indicate receive backlog; rising squeezed can indicate exhausted processing budget. Check CPU and traffic together.')"
}
# END INSPECTION


read_plan_options() {
  local profile bandwidth rtt target
  MENU_PLAN_ARGS=()
  np_msg '配置档用途：\n  balanced：通用场景（默认）\n  proxy：代理、多连接，单连接缓冲建议更保守\n  bulk：少量大文件传输，允许较大的缓冲建议\n' 'Profiles:\n  balanced: general use (default)\n  proxy: proxies and many connections; more conservative per-connection buffers\n  bulk: a few large transfers; larger per-connection buffer recommendations\n'
  read -r -p "$(np_msg '请选择配置档，默认 balanced：' 'Select a profile; default balanced: ')" profile || return 1
  MENU_PLAN_ARGS=(--profile "${profile:-balanced}")
  read -r -p "$(np_msg '已知路径带宽 Mbps（留空保留现有缓冲区，不填网卡标称速率）：' 'Known path bandwidth in Mbps (blank keeps existing buffers; not the NIC link rate): ')" bandwidth || return 1
  if [[ -n "$bandwidth" ]]; then
    read -r -p "$(np_msg '已知延迟毫秒（不知道请回车，工具自动测量）：' 'Known latency in ms (press Enter to measure automatically): ')" rtt || return 1
    if [[ -n "$rtt" ]]; then
      MENU_PLAN_ARGS+=(--bandwidth "$bandwidth" --rtt "$rtt")
    else
      read -r -p "$(np_msg '测量目标 IP 或域名（与带宽数据同一路径）：' 'Target IP or hostname on the same path as the bandwidth data: ')" target || return 1
      MENU_PLAN_ARGS+=(--bandwidth "$bandwidth" --rtt-target "$target")
    fi
  fi
}

menu_apply_tuning() {
  read_plan_options || return 1
  apply_tuning "${MENU_PLAN_ARGS[@]}"
}

feature_menu() {
  local choice peer budget latency before after seconds
  local -a args=()
  np_msg '\n1. 机器诊断\n2. 参数建议（只读）\n3. 独立 iperf3 双向测速\n4. 比较两份 iperf3 报告\n5. 核对持久配置\n6. 观察网络计数增量\n0. 返回\n' '\n1. Machine diagnostics\n2. Parameter recommendations (read-only)\n3. Separate bidirectional iperf3 benchmark\n4. Compare two iperf3 reports\n5. Verify persistent configuration\n6. Observe network counter deltas\n0. Back\n'
  read -r -p "$(np_msg '选择 [0-6]：' 'Select [0-6]: ')" choice || return 1
  case "$choice" in
    1) adaptive_doctor ;;
    2) read_plan_options && adaptive_show_plan "${MENU_PLAN_ARGS[@]}" ;;
    3)
      read -r -p "$(np_msg '你有权测速的 iperf3 对端（主机名或IP）：' 'Authorized iperf3 peer (hostname or IP): ')" peer || return 1
      read -r -p "$(np_msg '本次总测试数据预算 MiB（默认1024）：' 'Total payload budget in MiB (default 1024): ')" budget || return 1
      read -r -p "$(np_msg '同时采样空闲/负载延迟？需ping [y/N]：' 'Sample idle/load latency with ping? [y/N]: ')" latency || return 1
      args=(--peer "$peer" --budget-mib "${budget:-1024}")
      [[ "$latency" =~ ^[Yy]$ ]] && args+=(--latency)
      bench_command "${args[@]}" ;;
    4)
      read -r -p "$(np_msg '前一份 iperf3 报告路径：' 'First iperf3 report path: ')" before || return 1
      read -r -p "$(np_msg '后一份 iperf3 报告路径：' 'Second iperf3 report path: ')" after || return 1
      bench_compare "$before" "$after" ;;
    5) verify_tuning ;;
    6)
      read -r -p "$(np_msg '观察秒数（默认5）：' 'Observation seconds (default 5): ')" seconds || return 1
      diagnose_command --seconds "${seconds:-5}" ;;
    0) return 0 ;;
    *) warn "$(np_msg '无效选项。' 'Invalid option.')"; return 2 ;;
  esac
}

# BEGIN BENCH
# Bounded measurement only: these functions never change kernel/network settings.
bench_usage() {
  if [[ ${NETPILOT_LANG:-zh} == en ]]; then
    cat <<'EOF'
NetPilot benchmark usage: netpilot bench --peer HOST [--port 5201] [--budget-mib 1024]
                         [--direction both|send|receive] [--streams 1] [--timeout 30]
                         [--latency] [--output FILE] [--yes]
      netpilot compare BEFORE.json AFTER.json
The payload budget covers all directions and streams; protocol overhead, retransmissions and provider billing may differ.
--latency also samples idle/loaded ICMP RTT; it does not identify the cause of queueing or loss.
EOF
  else
  cat <<'EOF'
NetPilot 测速用法：netpilot bench --peer HOST [--port 5201] [--budget-mib 1024]
               [--direction both|send|receive] [--streams 1] [--timeout 30]
               [--latency] [--output FILE] [--yes]
      netpilot compare BEFORE.json AFTER.json
预算为全部方向和流的测试 payload 预算；协议开销、重传和商家计费不等同于该值。
--latency 额外测量空闲/负载下 ICMP RTT；不能据此确定排队或丢包原因。
EOF
  fi
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
        (( $# )) || { np_msg '缺少 %s 的值。\n' 'Missing value for %s.\n' "$option" >&2; return 2; }
        case "$option" in
          --peer) peer="$1" ;; --port) port="$1" ;; --budget-mib) budget="$1" ;;
          --direction) direction="$1" ;; --streams) streams="$1" ;;
          --timeout) deadline="$1" ;; --output) output="$1" ;;
        esac
        shift ;;
      *) np_msg '未知测速选项：%s\n' 'Unknown benchmark option: %s\n' "$option" >&2; return 2 ;;
    esac
  done
  [[ ${#peer} -le 253 && "$peer" =~ ^[a-zA-Z0-9_:][a-zA-Z0-9_.:%-]*$ ]] || {
    np_msg '请提供合法的对端主机名、IPv4 或 IPv6 地址。\n' 'Provide a valid peer hostname, IPv4 or IPv6 address.\n' >&2; return 2;
  }
  bench_integer "$port" 1 65535 && bench_integer "$budget" 1 1048576 &&
    bench_integer "$streams" 1 32 && bench_integer "$deadline" 2 600 || {
      np_msg '端口、预算、流数或超时超出允许范围。\n' 'Port, budget, stream count or timeout is out of range.\n' >&2; return 2;
    }
  port=$((10#$port)); budget=$((10#$budget)); streams=$((10#$streams)); deadline=$((10#$deadline))
  case "$direction" in both) rounds=2 ;; send|receive) rounds=1 ;;
    *) np_msg 'direction 只能是 both、send 或 receive。\n' 'direction must be both, send or receive.\n' >&2; return 2 ;; esac
  # iperf3 -n stops on aggregate test bytes, not bytes per parallel stream.
  # Reserve one default 128 KiB block per stream for concurrent final writes.
  quota=$(( (budget * 1048576 / rounds / 131072 - streams) * 131072 ))
  (( quota >= 131072 )) || { np_msg '预算不足，请减少流数或提高预算。\n' 'Budget is too small; reduce streams or increase the budget.\n' >&2; return 2; }
  [[ -n "$output" ]] || output="./netpilot-bench-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  [[ ! -e "$output" && ! -L "$output" && -d "$(dirname -- "$output")" ]] || {
    np_msg '报告路径必须尚不存在，且父目录必须存在。\n' 'Report path must not exist, and its parent directory must exist.\n' >&2; return 2;
  }
  np_msg '测速对端：%s:%s；方向：%s；每方向 %s 流。\n' 'Benchmark peer: %s:%s; direction: %s; %s streams per direction.\n' "$peer" "$port" "$direction" "$streams"
  np_msg '总 payload 预算：%s MiB；每方向超时：%s 秒；计费流量可能更高。\n' 'Total payload budget: %s MiB; timeout per direction: %s seconds; billed traffic may be higher.\n' "$budget" "$deadline"
  if (( consent == 0 )); then
    [[ -t 0 ]] || { np_msg '非交互模式需显式 --yes；未开始测速。\n' 'Noninteractive mode requires explicit --yes; benchmark not started.\n' >&2; return 1; }
    read -r -p "$(np_msg '确认向此对端运行有预算的测速？[y/N] ' 'Run the budgeted benchmark against this peer? [y/N] ')" answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]] || return 1
  fi
  for dep in iperf3 python3 timeout; do
    command -v "$dep" >/dev/null 2>&1 || { np_msg '缺少测速依赖：%s；请自行安装后重试。\n' 'Missing benchmark dependency: %s; install it and try again.\n' "$dep" >&2; return 1; }
  done
  if (( latency )); then
    command -v ping >/dev/null 2>&1 || { np_msg '缺少可选延迟测量依赖：ping。\n' 'Missing optional latency measurement dependency: ping.\n' >&2; return 1; }
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
  trap 'np_msg "测速已取消。\n" "Benchmark cancelled.\n" >&2; bench_finish 0; return 130' INT
  trap 'np_msg "测速已终止。\n" "Benchmark terminated.\n" >&2; bench_finish 0; return 143' TERM HUP
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
  report_tmp="$(mktemp "$(dirname -- "$output")/.netpilot-bench.XXXXXX")" || { bench_finish 0; return 1; }
  if ! python3 - "$bench_dir" "$peer" "$port" "$budget" "$streams" "$deadline" "$direction" "$quota" "$latency" > "$report_tmp" <<'PY'
import datetime, ipaddress, json, math, pathlib, re, sys
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
        connected=raw['start']['connected']
        if not isinstance(connected,list) or len(connected)!=streams: raise ValueError('missing actual peer identities')
        remote_endpoints=[]
        for item in connected:
            if (not isinstance(item,dict) or not isinstance(item.get('remote_host'),str) or
                    type(item.get('remote_port')) is not int or item['remote_port']!=port):
                raise ValueError('invalid actual peer identity')
            remote_endpoints.append({'address':str(ipaddress.ip_address(item['remote_host'])), 'port':item['remote_port']})
        remote_endpoints.sort(key=lambda item:(item['address'],item['port']))
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
        run.update(status='ok',bytes=transferred,mbps=throughput/1e6,seconds=seconds,remote_endpoints=remote_endpoints,
                   sample_quality='short_sample' if seconds<3 else 'bounded_sample',
                   retransmits=number(sent.get('retransmits')),
                   cpu_host_percent=number(cpu.get('host_total')),
                   cpu_remote_percent=number(cpu.get('remote_total')))
    except (ValueError,KeyError,TypeError,OverflowError) as error:
        stderr=(folder/(n+'.err')).read_text(errors='replace')[:2000]
        run.update(status='failed',exit_code=rc,error=str(error)+((': '+stderr) if stderr else ''))
    if latency:
        loaded=rtt(folder/(n+'.ping'))
        loaded['p95_delta_ms']=(loaded['p95_ms']-idle['p95_ms']) if loaded['status']==idle['status']=='ok' else None
        run['loaded_latency']=loaded
    runs.append(run)
# NetPilot benchmark reports use an explicit versioned wire identifier.
report={'schema_version':1,'kind':'netpilot-benchmark',
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
  np_msg '私有报告：%s\n' 'Private report: %s\n' "$output"
  bench_finish 0
  return "$result"
}

bench_summary() {
  python3 - "$1" "${NETPILOT_LANG:-zh}" <<'PY'
import json,sys
english=sys.argv[2]=='en'
def text(zh,en):
    return en if english else zh
d=json.load(open(sys.argv[1])); failed=False
for r in d['runs']:
    if r['status']!='ok':
        print(r['direction']+text(': 测量失败，原因见私有报告。', ': Measurement failed; see the private report for details.')); failed=True; continue
    print(text('%s: %.2f Mbps，%.2fs，重传=%s，CPU=%s%%，%s',
               '%s: %.2f Mbps, %.2fs, retransmits=%s, CPU=%s%%, %s') %
          (r['direction'],r['mbps'],r['seconds'],r['retransmits'],r['cpu_host_percent'],
           text('样本过短，不能确定峰值', 'sample too short to determine peak throughput')
           if r['sample_quality']=='short_sample' else text('仅代表此对端/方向/时段', 'only this peer/direction/time window')))
    if d['latency_enabled']:
        latency=r['loaded_latency']
        if latency['p95_delta_ms'] is None: print(text('ICMP 延迟：不可用或样本不足。', 'ICMP latency: unavailable or insufficient samples.'))
        else: print(text('ICMP 负载p95=%.2fms，相对空闲变化=%+.2fms。', 'ICMP loaded p95=%.2fms; change from idle=%+.2fms.') % (latency['p95_ms'],latency['p95_delta_ms']))
print(text('计费流量可能高于 payload；单次测量不能证明代理体验或调优收益。',
           'Billed traffic may exceed payload; one measurement cannot establish proxy experience or tuning gains.'))
sys.exit(1 if failed else 0)
PY
}

bench_compare() {
  [[ $# == 2 ]] || { bench_usage >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || { np_msg 'compare 需要 python3。\n' 'compare requires python3.\n' >&2; return 1; }
  python3 - "$1" "$2" "${NETPILOT_LANG:-zh}" <<'PY'
import ipaddress,json,math,os,stat,sys
english=sys.argv[3]=='en'
def text(zh,en):
    return en if english else zh
def load_report(path):
    # Explicit input paths may be symlinks to regular files, but never streams
    # or devices. Nonblocking open prevents a FIFO from hanging the menu.
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 1048576:
            raise ValueError(text('报告必须是至多1MiB的普通文件', 'report must be a regular file of at most 1MiB'))
        payload = stream.read(1048577)
        if len(payload) > 1048576:
            raise ValueError(text('报告超过1MiB', 'report exceeds 1MiB'))
        def invalid_constant(value): raise ValueError(text('JSON含非有限数值', 'JSON contains a non-finite value'))
        return json.loads(payload, parse_constant=invalid_constant)
try:
    before,after=(load_report(p) for p in sys.argv[1:3])
    def valid_number(value):
        return type(value) in (int,float) and math.isfinite(value) and value>0
    def validate(report):
        if not isinstance(report,dict): raise ValueError(text('报告必须是JSON对象', 'report must be a JSON object'))
        if type(report.get('schema_version')) is not int or report['schema_version']!=1 or report.get('kind')!='netpilot-benchmark':
            raise ValueError(text('不支持的报告格式', 'unsupported report format'))
        if not isinstance(report.get('peer'),str) or not report['peer']: raise ValueError(text('缺少对端', 'missing peer'))
        for key,low,high in [('port',1,65535),('streams',1,32),('budget_bytes',1048576,1099511627776),('timeout_seconds',2,600)]:
            value=report.get(key)
            if type(value) is not int or not low<=value<=high: raise ValueError(text('无效字段：', 'invalid field: ')+key)
        if type(report.get('latency_enabled')) is not bool: raise ValueError(text('无效延迟选项', 'invalid latency option'))
        direction=report.get('direction')
        if direction not in ('send','receive','both'): raise ValueError(text('无效方向', 'invalid direction'))
        expected=['send','receive'] if direction=='both' else [direction]
        target=report.get('bytes_per_run_target')
        expected_target=(report['budget_bytes']//len(expected)//131072-report['streams'])*131072
        if type(target) is not int or target<131072 or target!=expected_target:
            raise ValueError(text('无效请求目标', 'invalid request target'))
        runs=report.get('runs')
        if not isinstance(runs,list) or len(runs)!=len(expected): raise ValueError(text('缺少测速结果', 'missing benchmark results'))
        mapped={}
        for run in runs:
            if not isinstance(run,dict) or run.get('status')!='ok': raise ValueError(text('存在失败结果', 'failed result present'))
            name=run.get('direction')
            if name not in expected or name in mapped: raise ValueError(text('重复或错误方向', 'duplicate or incorrect direction'))
            if not valid_number(run.get('mbps')) or not valid_number(run.get('seconds')) or not valid_number(run.get('bytes')):
                raise ValueError(text('无效测量值', 'invalid measurement value'))
            if run.get('sample_quality') not in ('short_sample','bounded_sample'): raise ValueError(text('缺少样本状态', 'missing sample status'))
            endpoints=run.get('remote_endpoints')
            if not isinstance(endpoints,list) or len(endpoints)!=report['streams']:
                raise ValueError(text('缺少实际对端身份，请重新测速', 'actual peer identities are missing; rerun the benchmark'))
            peers=[]
            for endpoint in endpoints:
                if (not isinstance(endpoint,dict) or not isinstance(endpoint.get('address'),str) or
                        type(endpoint.get('port')) is not int or endpoint['port']!=report['port']):
                    raise ValueError(text('无效实际对端身份', 'invalid actual peer identity'))
                peers.append((str(ipaddress.ip_address(endpoint['address'])),endpoint['port']))
            run['remote_endpoints']=sorted(peers)
            mapped[name]=run
        return expected,mapped
    expected,left=validate(before)
    _,right=validate(after)
    for key in ('peer','port','direction','streams','budget_bytes','timeout_seconds','latency_enabled','bytes_per_run_target'):
        if before[key]!=after[key]: raise ValueError(text('测试条件不同：', 'different test conditions: ')+key)
    changes={}
    for name in expected:
        if left[name]['remote_endpoints']!=right[name]['remote_endpoints']:
            raise ValueError(text('实际对端不同：', 'different actual peers: ')+name)
        changes[name]=(right[name]['mbps']/left[name]['mbps']-1)*100
        if not math.isfinite(changes[name]): raise ValueError(text('变化率不是有限数值', 'change percentage is not finite'))
    for name in expected:
        a,b=left[name],right[name]
        print(text('%s: %.2f → %.2f Mbps，变化 %+.1f%%', '%s: %.2f → %.2f Mbps, change %+.1f%%') % (name,a['mbps'],b['mbps'],changes[name]))
        if a['sample_quality']=='short_sample' or b['sample_quality']=='short_sample': print(text('样本过短：仅供观察，不能确定峰值或收益。', 'Short sample: observational only; peak throughput or gains cannot be established.'))
    print(text('同条件的时点对比；线路波动和对端负载仍会影响结果，不能据此保证提升。', 'Same-condition snapshots; path variation and peer load still affect results, so improvement cannot be guaranteed.'))
except (OSError,ValueError,KeyError,TypeError,OverflowError,RecursionError) as error:
    print(text('无法对比：', 'Cannot compare: ')+str(error),file=sys.stderr); sys.exit(1)
PY
}

# END BENCH

# BEGIN HTTP MEASUREMENT
# shellcheck shell=bash
# HTTP probes use synthetic data only and never change network configuration.
http_measure_path() {
  local phase="${1:-}" endpoint="${2:-}" budget="${3:-}" deadline="${4:-}" output="${5:-}" before="${6:-}" dep
  local http_measure_pid='' http_measure_status=0
  if [[ $# -lt 5 || $# -gt 6 || ! "$deadline" =~ ^[0-9]{1,3}$ ]] || ((10#$deadline < 1 || 10#$deadline > 600)); then
    printf '%s\n' 'Invalid HTTP measurement arguments or timeout.' >&2
    return 2
  fi
  for dep in python3 timeout; do
    command -v "$dep" >/dev/null 2>&1 || {
      printf 'HTTP measurement requires %s.\n' "$dep" >&2
      return 1
    }
  done
  # Background the actual timeout monitor, so the caller's cancellation trap can
  # signal it while Bash waits. The monitor forwards TERM to its Python child.
  LC_ALL=C timeout --foreground --kill-after=1 "${deadline}s" python3 - "$phase" "$endpoint" "$budget" "$deadline" "$output" "$before" <<'PY' &
import http.client
import ipaddress
import json
import math
import os
import pathlib
import re
import signal
import socket
import ssl
import stat
import sys
import tempfile
import time
from urllib.parse import urlsplit

phase, raw_endpoint, raw_budget, raw_timeout, output_name, before_name = sys.argv[1:]
language = os.environ.get('NETPILOT_LANG', 'zh')
report = {'type': 'netpilot-http-measurement', 'version': 1, 'ok': False,
          'phase': phase, 'endpoint': raw_endpoint, 'reserved_bytes': 0}
connection = None
output = os.path.abspath(output_name)
started = time.monotonic()
deadline_at = started + int(raw_timeout)
http.client._MAXLINE = 8192
http.client._MAXHEADERS = 32

def text(chinese, english):
    return english if language == 'en' else chinese

class Cancelled(Exception):
    def __init__(self, number):
        super().__init__('measurement cancelled')
        self.code = 128 + number

def cancelled(number, _frame):
    raise Cancelled(number)

signal.signal(signal.SIGINT, cancelled)
signal.signal(signal.SIGTERM, cancelled)
signal.signal(signal.SIGHUP, cancelled)

def remaining():
    value = deadline_at - time.monotonic()
    if value <= 0:
        raise TimeoutError('measurement deadline exceeded')
    return min(5.0, value)

def integer(value, low, high):
    return type(value) is int and low <= value <= high

def positive(value, high=float('inf')):
    return type(value) in (int, float) and math.isfinite(value) and 0 < value <= high

def publish(value):
    # Link a complete private temporary file into place without replacing any
    # existing file or symbolic link. The caller owns the private run directory.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=os.path.dirname(output),
                                         prefix='.http-report-', delete=False) as handle:
            temporary = handle.name
            os.chmod(temporary, 0o600)
            json.dump(value, handle, ensure_ascii=False, allow_nan=False)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.link(temporary, output, follow_symlinks=False)
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass

def read_before(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(descriptor, 'r', encoding='utf-8') as handle:
        metadata = os.fstat(handle.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 1048576:
            raise ValueError('invalid baseline report file')
        value = json.load(handle)
    if (not isinstance(value, dict) or value.get('type') != report['type'] or
            type(value.get('version')) is not int or value['version'] != 1 or
            value.get('ok') is not True or value.get('phase') != 'before' or
            value.get('endpoint') != endpoint or value.get('budget_bytes') != budget or
            type(value.get('budget_bytes')) is not int or
            type(value.get('timeout_seconds')) is not int or value.get('timeout_seconds') != int(raw_timeout) or
            value.get('latency_method') != 'tcp-connect-estimate' or
            not positive(value.get('latency_ms'), 60000) or
            not integer(value.get('port'), 1, 65535) or value['port'] != port):
        raise ValueError('incompatible baseline measurement')
    prior_address = ipaddress.ip_address(value.get('address', ''))
    if cloudflare and not prior_address.is_global:
        raise ValueError('baseline address is not public')
    if scheme == 'http' and not prior_address.is_loopback:
        raise ValueError('plaintext baseline address is not loopback')
    if not isinstance(value.get('node'), str) or not value['node'] or len(value['node']) > 128:
        raise ValueError('invalid baseline node')
    if type(value.get('node_verified')) is not bool or value.get('connection_policy') != 'pinned-preconnected':
        raise ValueError('invalid baseline connection or node-verification policy')
    if cloudflare and (value.get('node_verified') is not True or not re.fullmatch(r'[A-Z0-9]{2,8}', value['node'])):
        raise ValueError('baseline Cloudflare node is not verified')
    total = 0
    for direction in ('download', 'upload'):
        item = value.get(direction)
        if not isinstance(item, dict):
            raise ValueError('missing baseline direction')
        sizes = item.get('request_sizes')
        if (not isinstance(sizes, list) or not 1 <= len(sizes) <= 32 or
                any(not integer(size, 1, min(16777216, slots[direction])) for size in sizes) or
                sum(sizes) > slots[direction] or item.get('payload_bytes') != sum(sizes) or
                type(item.get('payload_bytes')) is not int or
                not positive(item.get('duration_seconds'), int(raw_timeout) + 1) or
                not positive(item.get('bits_per_second')) or
                not math.isclose(item['bits_per_second'], sum(sizes) * 8 / item['duration_seconds'], rel_tol=1e-8) or
                item.get('quality') != ('sampled' if item['duration_seconds'] >= 3 else 'budget-limited')):
            raise ValueError('invalid baseline request schedule or metrics')
        if not positive(value.get(direction + '_bps')) or value[direction + '_bps'] != item['bits_per_second']:
            raise ValueError('inconsistent baseline throughput')
        total += sum(sizes)
    if not integer(value.get('reserved_bytes'), 1, budget) or value['reserved_bytes'] != total:
        raise ValueError('invalid baseline reservation total')
    return value

def dial(address_value, family_value):
    sock = socket.socket(family_value, socket.SOCK_STREAM)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.settimeout(remaining())
    begin = time.perf_counter()
    try:
        destination = (address_value, port, 0, 0) if family_value == socket.AF_INET6 else (address_value, port)
        sock.connect(destination)
        elapsed = (time.perf_counter() - begin) * 1000
        if not positive(elapsed, 60000):
            raise ValueError('invalid TCP connection timing')
        return sock, elapsed
    except BaseException:
        sock.close()
        raise

def check_headers(response):
    if sum(len(key) + len(value) for key, value in response.getheaders()) > 16384:
        raise ValueError('response headers exceed the allowed size')
    if response.status != 200:
        raise ValueError('measurement endpoint returned HTTP %d' % response.status)
    if response.getheader('Content-Encoding', 'identity').lower().strip() != 'identity':
        raise ValueError('encoded measurement responses are not supported')
    identities = []
    for key in ('colo', 'cf-meta-colo'):
        value = response.getheader(key)
        if value is not None:
            value = value.strip().upper()
            if not re.fullmatch(r'[A-Z0-9]{2,8}', value):
                raise ValueError('invalid measurement node header')
            identities.append(value)
    ray = response.getheader('CF-RAY')
    if ray is not None:
        match = re.fullmatch(r'[0-9a-fA-F]+-([A-Za-z0-9]{2,8})', ray.strip())
        if match is None:
            raise ValueError('invalid measurement trace header')
        identities.append(match.group(1).upper())
    if len(set(identities)) > 1:
        raise ValueError('measurement node headers disagree')
    if cloudflare and not identities:
        raise ValueError('Cloudflare measurement node cannot be verified')
    node = identities[0] if identities else 'address:' + address
    expected = report.get('node')
    if expected is not None and node != expected:
        raise ValueError('measurement node changed')
    report['node'] = node
    report['node_verified'] = bool(identities)

def prepare_connection():
    global connection
    if connection is None:
        context = ssl.create_default_context() if scheme == 'https' else None
        class PinnedConnection(http.client.HTTPConnection):
            def connect(self):
                raw_socket, _ = dial(address, family)
                try:
                    self.sock = context.wrap_socket(raw_socket, server_hostname=host) if context else raw_socket
                    self.sock.settimeout(remaining())
                except BaseException:
                    raw_socket.close()
                    raise
        connection = PinnedConnection(host, port, timeout=remaining())
    # A clean server-requested close between completed requests may require a
    # new connection; always reconnect to the pinned address before timing.
    if connection.sock is None:
        connection.connect()
    connection.sock.settimeout(remaining())

def update_timeout():
    limit = remaining()
    if connection is not None and connection.sock is not None:
        connection.sock.settimeout(limit)

def probe(direction, size):
    item = report[direction]
    if report['reserved_bytes'] + size > budget or sum(item['request_sizes']) + size > slots[direction]:
        raise ValueError('measurement payload budget exhausted')
    # Debit before the request. Failed or partially transmitted requests never
    # receive a refund and are never retried.
    report['reserved_bytes'] += size
    item['request_sizes'].append(size)
    prepare_connection()
    begin = time.perf_counter()
    if direction == 'download':
        connection.request('GET', '/__down?bytes=%d' % size,
                           headers={'Accept-Encoding': 'identity', 'User-Agent': 'NetPilot/1'})
        update_timeout()
        response = connection.getresponse()
        check_headers(response)
        length = response.getheader('Content-Length')
        if length is None or not re.fullmatch(r'[0-9]+', length) or int(length) != size or response.getheader('Transfer-Encoding'):
            raise ValueError('download length does not match the reserved payload')
        left = size
        while left:
            update_timeout()
            try:
                data = response.read(min(65536, left))
            except http.client.IncompleteRead as exc:
                item['payload_bytes'] += len(exc.partial)
                raise ValueError('download ended before the reserved payload was received') from exc
            if not data:
                raise ValueError('download ended before the reserved payload was received')
            item['payload_bytes'] += len(data)
            left -= len(data)
        response.close()
    else:
        connection.putrequest('POST', '/__up?bytes=%d' % size, skip_accept_encoding=True)
        connection.putheader('Content-Length', str(size))
        connection.putheader('Content-Type', 'application/octet-stream')
        connection.putheader('Accept-Encoding', 'identity')
        connection.putheader('User-Agent', 'NetPilot/1')
        connection.endheaders()
        left = size
        zeros = b'\0' * min(65536, size)
        while left:
            update_timeout()
            chunk = zeros if left >= len(zeros) else zeros[:left]
            connection.send(chunk)
            item['payload_bytes'] += len(chunk)
            left -= len(chunk)
        update_timeout()
        response = connection.getresponse()
        check_headers(response)
        acknowledged = response.getheader('cf-meta-upload-bytes', '')
        if not re.fullmatch(r'[0-9]+', acknowledged) or int(acknowledged) != size:
            raise ValueError('server did not acknowledge the complete upload')
        length = response.getheader('Content-Length')
        if length is not None and (not re.fullmatch(r'[0-9]+', length) or int(length) != 0):
            raise ValueError('unexpected upload response body')
        update_timeout()
        if response.read(1):
            raise ValueError('unexpected upload response body')
        response.close()
    duration = time.perf_counter() - begin
    if not positive(duration):
        raise ValueError('invalid measurement duration')
    item['duration_seconds'] += duration

exit_code = 1
try:
    if phase not in ('before', 'after') or not re.fullmatch(r'[0-9]+', raw_budget):
        raise ValueError('invalid measurement phase or budget')
    budget = int(raw_budget)
    if not integer(budget, 131072, 536870912):
        raise ValueError('measurement phase budget is out of range')
    if not output_name or os.path.lexists(output) or not os.path.isdir(os.path.dirname(output)):
        raise ValueError('report output must not exist and its directory must already exist')
    if (any(ord(char) < 33 or ord(char) > 126 for char in raw_endpoint) or
            '\\' in raw_endpoint or len(raw_endpoint) > 2048):
        raise ValueError('invalid measurement endpoint')
    parsed = urlsplit(raw_endpoint)
    if parsed.scheme not in ('https', 'http') or not parsed.hostname or parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment or parsed.path not in ('', '/'):
        raise ValueError('endpoint must be a plain HTTP(S) origin without credentials or a path')
    scheme, host = parsed.scheme, parsed.hostname.lower()
    port = parsed.port if parsed.port is not None else (443 if scheme == 'https' else 80)
    if not 1 <= port <= 65535:
        raise ValueError('invalid measurement port')
    literal = None
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        pass
    if scheme == 'http' and not (host == 'localhost' or literal is not None and literal.is_loopback):
        raise ValueError('plaintext HTTP is allowed only for an explicit loopback endpoint')
    cloudflare = scheme == 'https' and host == 'speed.cloudflare.com'
    netloc = '[' + host + ']' if ':' in host else host
    if parsed.port is not None:
        netloc += ':' + str(port)
    endpoint = scheme + '://' + netloc
    slots = {'download': budget // 2, 'upload': budget // 2}
    report.update(endpoint=endpoint, budget_bytes=budget, timeout_seconds=int(raw_timeout),
                  latency_method='tcp-connect-estimate', connection_policy='pinned-preconnected',
                  provider='cloudflare' if cloudflare else 'custom')
    previous = read_before(before_name) if phase == 'after' else None
    if phase == 'before' and before_name:
        raise ValueError('a baseline input is allowed only for the after phase')
    if previous:
        address = previous['address']
        family = socket.AF_INET6 if ipaddress.ip_address(address).version == 6 else socket.AF_INET
        report['node'] = previous['node']
        report['node_verified'] = previous.get('node_verified', False)
        candidates = [(family, socket.SOCK_STREAM, 6, '', (address, port))]
    else:
        candidates = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    timings = []
    seen = set()
    address = None
    for candidate in candidates:
        candidate_address = candidate[4][0]
        if candidate_address in seen:
            continue
        seen.add(candidate_address)
        candidate_ip = ipaddress.ip_address(candidate_address)
        if cloudflare and not candidate_ip.is_global or scheme == 'http' and not candidate_ip.is_loopback:
            continue
        family = candidate[0]
        if family not in (socket.AF_INET, socket.AF_INET6):
            continue
        try:
            sock, timing = dial(candidate_address, family)
            sock.close()
            address = candidate_address
            timings.append(timing)
            break
        except (OSError, TimeoutError):
            continue
    if address is None:
        raise ValueError('no suitable reachable address; private or proxy-mapped Cloudflare addresses are not usable')
    while len(timings) < 3:
        sock, timing = dial(address, family)
        sock.close()
        timings.append(timing)
    report.update(address=address, port=port, family='IPv6' if family == socket.AF_INET6 else 'IPv4',
                  latency_ms=sum(timings) / len(timings), latency_samples=len(timings))
    for direction in ('download', 'upload'):
        report[direction] = {'request_sizes': [], 'payload_bytes': 0, 'duration_seconds': 0.0}
    for direction in ('download', 'upload'):
        if previous:
            for size in previous[direction]['request_sizes']:
                probe(direction, size)
        else:
            ladder = (65536, 262144, 1048576, 4194304, 16777216)
            step = 0
            while sum(report[direction]['request_sizes']) < slots[direction]:
                available = slots[direction] - sum(report[direction]['request_sizes'])
                size = min(ladder[step] if step < len(ladder) else ladder[-1], available)
                probe(direction, size)
                step += 1
                if report[direction]['duration_seconds'] >= 3:
                    break
        item = report[direction]
        item['bits_per_second'] = item['payload_bytes'] * 8 / item['duration_seconds']
        item['quality'] = 'sampled' if item['duration_seconds'] >= 3 else 'budget-limited'
        if not positive(item['bits_per_second']):
            raise ValueError('invalid throughput measurement')
        report[direction + '_bps'] = item['bits_per_second']
    if previous and (report['address'] != previous['address'] or report['node'] != previous['node']):
        raise ValueError('before and after peers do not match')
    report.update(ok=True, duration_seconds=time.monotonic() - started)
    publish(report)
    exit_code = 0
except Exception as exc:
    report.update(ok=False, error=str(exc)[:2048], duration_seconds=time.monotonic() - started)
    if isinstance(exc, Cancelled):
        exit_code = exc.code
    try:
        if not os.path.lexists(output) and os.path.isdir(os.path.dirname(output)):
            publish(report)
    except (OSError, ValueError):
        pass
    print(text('HTTP 测量失败：', 'HTTP measurement failed: ') + str(exc), file=sys.stderr)
finally:
    if connection is not None:
        connection.close()
sys.exit(exit_code)
PY
  http_measure_pid=$!
  if [[ "${AUTO_TUNE_ACTIVE:-0}" == 1 ]] && ((${auto_cancel_code:-0})); then
    kill -TERM "$http_measure_pid" 2>/dev/null || true
  fi
  while :; do
    if wait "$http_measure_pid"; then http_measure_status=0; break; else http_measure_status=$?; fi
    # A trapped signal interrupts wait before the child exits. Wait again to
    # reap the monitor and its child before releasing the mutation lock.
    kill -0 "$http_measure_pid" 2>/dev/null || break
  done
  return "$http_measure_status"
}
# END HTTP MEASUREMENT

# BEGIN AUTO TUNE
# Report operations never change system configuration or execute report data.
auto_report() {
  python3 - "$@" "${NETPILOT_LANG:-zh}" <<'PY'
import ipaddress, json, math, os, stat, sys, tempfile
from pathlib import Path
from urllib.parse import urlsplit

op, *args = sys.argv[1:-1]
english = sys.argv[-1] == 'en'
def text(zh, en): return en if english else zh
def number(value, upper=1e15):
    if type(value) not in (int, float) or not math.isfinite(value) or not 0 < value <= upper:
        raise ValueError('invalid positive measurement')
    return value
def integer(value, minimum=0, maximum=2**40):
    if type(value) is not int or not minimum <= value <= maximum: raise ValueError('invalid integer')
    return value
def load(path):
    p = Path(path)
    if p.is_symlink() or p.stat().st_size > 1048576: raise ValueError('unsafe report')
    def invalid_constant(value): raise ValueError('non-finite JSON constant')
    with p.open() as stream: return json.load(stream, parse_constant=invalid_constant)
def atomic(path, data):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix='.summary.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, ensure_ascii=False, allow_nan=False, indent=2)
            stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        os.link(temporary, str(path))
    finally:
        os.unlink(temporary)
def endpoint(value):
    if len(value) > 2048 or '\\' in value or any(ord(c) < 33 or ord(c) > 126 for c in value):
        raise ValueError('invalid measurement endpoint')
    u = urlsplit(value)
    if u.username is not None or u.password is not None or u.query or u.fragment or u.path not in ('', '/') or not u.hostname:
        raise ValueError('invalid measurement endpoint')
    if u.scheme != 'https' and not (u.scheme == 'http' and u.hostname in ('localhost', '127.0.0.1', '::1')):
        raise ValueError('HTTPS is required except for explicit loopback endpoints')
    port = u.port if u.port is not None else (443 if u.scheme == 'https' else 80)
    if not 1 <= port <= 65535:
        raise ValueError('invalid endpoint port')
    host = u.hostname.lower()
    authority = '[' + host + ']' if ':' in host else host
    if u.port is not None: authority += ':' + str(port)
    return u.scheme + '://' + authority
def measurement_data(d, phase, expected_endpoint=None, budget=None, timeout=None):
    if not isinstance(d, dict) or d.get('type') != 'netpilot-http-measurement' or type(d.get('version')) is not int or d['version'] != 1:
        raise ValueError('incompatible HTTP measurement report')
    if d.get('ok') is not True or d.get('phase') != phase: raise ValueError('measurement did not succeed')
    endpoint(d['endpoint'])
    if expected_endpoint is not None and d['endpoint'] != expected_endpoint: raise ValueError('endpoint changed')
    ipaddress.ip_address(d['address'])
    integer(d['port'], 1, 65535)
    integer(d['timeout_seconds'], 1, 600)
    if timeout is not None and d['timeout_seconds'] != timeout: raise ValueError('measurement timeout changed')
    if d.get('node') is not None and (not isinstance(d['node'], str) or not 1 <= len(d['node']) <= 64):
        raise ValueError('invalid node identity')
    if d.get('latency_method') != 'tcp-connect-estimate': raise ValueError('unexpected latency method')
    number(d['latency_ms'], 60000)
    integer(d['budget_bytes'], 1)
    if budget is not None and d['budget_bytes'] != budget: raise ValueError('measurement budget changed')
    integer(d['reserved_bytes'], 0, d['budget_bytes'])
    used = 0
    for direction in ('download', 'upload'):
        stream = d[direction]
        sizes = stream['request_sizes']
        if not isinstance(sizes, list) or not 1 <= len(sizes) <= 32: raise ValueError('invalid request schedule')
        for size in sizes: integer(size, 1, d['budget_bytes'])
        payload = sum(sizes)
        if payload > d['budget_bytes'] // 2 or stream['payload_bytes'] != payload:
            raise ValueError('direction payload exceeds its budget')
        duration = number(stream['duration_seconds'], 600)
        rate = number(stream['bits_per_second'], 1e12)
        if not math.isclose(rate, payload * 8 / duration, rel_tol=1e-5): raise ValueError('inconsistent throughput')
        if not math.isclose(number(d[direction + '_bps'], 1e12), rate, rel_tol=1e-5): raise ValueError('inconsistent reported rate')
        if stream['quality'] != ('sampled' if duration >= 3 else 'budget-limited'):
            raise ValueError('sample quality does not match measurement duration')
        used += payload
    if used > d['reserved_bytes']: raise ValueError('unaccounted measurement payload')
    return d
def measurement(path, phase, expected_endpoint=None, budget=None, timeout=None):
    return measurement_data(load(path), phase, expected_endpoint, budget, timeout)
def summary_configuration_state(data):
    if data['rollback_status'] == 'failed': return 'unknown'
    if data['rollback_status'] == 'completed': return 'restored'
    if data['verified'] and data['applied']: return 'verified'
    return 'applied' if data['applied'] else 'unchanged'
def compare(before, after):
    for key in ('endpoint', 'address', 'port', 'node', 'latency_method', 'budget_bytes', 'timeout_seconds'):
        if before[key] != after[key]: raise ValueError('test condition changed: ' + key)
    for key in ('family', 'connection_policy', 'node_verified'):
        if before.get(key) != after.get(key): raise ValueError('test policy changed: ' + key)
    for direction in ('download', 'upload'):
        if before[direction]['request_sizes'] != after[direction]['request_sizes']:
            raise ValueError('request schedule changed')
    return {
        'download_change_pct': (after['download_bps'] / before['download_bps'] - 1) * 100,
        'upload_change_pct': (after['upload_bps'] / before['upload_bps'] - 1) * 100,
        'latency_delta_ms': after['latency_ms'] - before['latency_ms'],
        'causal_claim': False,
        'budget_limited': any(d[k]['quality'] == 'budget-limited' for d in (before, after) for k in ('download', 'upload')),
    }
SUMMARY_CHOICES = {
    'stage': ('before', 'apply', 'verify', 'after', 'completed'),
    'profile': ('balanced', 'proxy', 'bulk'),
    'verify_status': ('not-needed', 'verified', 'failed'),
    'rollback_status': ('not-needed', 'completed', 'failed'),
    'configuration_state': ('unchanged', 'applied', 'verified', 'restored', 'unknown'),
}
def validate_summary(data):
    if (not isinstance(data, dict) or data.get('type') != 'netpilot-tune-report' or
            type(data.get('version')) is not int or data['version'] != 1 or
            data.get('status') not in ('completed', 'failed', 'partial', 'cancelled')):
        raise ValueError('not a supported NetPilot summary')
    if any(data.get(key) not in values for key, values in SUMMARY_CHOICES.items()):
        raise ValueError('missing or invalid summary state')
    if (any(type(data.get(key)) is not bool for key in ('changed', 'applied', 'verified')) or
            (data.get('error') is not None and not isinstance(data['error'], str))):
        raise ValueError('invalid summary flags or error')
    code = integer(data.get('exit_code'), 0, 255)
    if data['configuration_state'] != summary_configuration_state(data):
        raise ValueError('configuration state disagrees with application or restoration records')
    if data['verified'] != (data['verify_status'] == 'verified'):
        raise ValueError('verification flag disagrees with verification status')
    if data['applied'] and not data['changed']:
        raise ValueError('applied settings must be marked changed')
    if data['rollback_status'] != 'not-needed' and data['verified']:
        raise ValueError('verified settings cannot also have an automatic restoration result')
    if data['rollback_status'] == 'completed' and data['applied']:
        raise ValueError('restored settings cannot also remain applied')
    status, stage = data['status'], data['stage']
    if stage == 'before' and (any(data[key] for key in ('changed', 'applied', 'verified')) or
                              data['verify_status'] != 'not-needed' or data['rollback_status'] != 'not-needed'):
        raise ValueError('baseline stage cannot contain application, verification or restoration results')
    if status in ('completed', 'partial') and data['verify_status'] == 'failed':
        raise ValueError('a verification failure cannot reach retesting or completion')
    if status == 'completed':
        if (code != 0 or stage != 'completed' or data.get('error') or
                data['rollback_status'] != 'not-needed' or data['changed'] != data['applied'] or
                data['applied'] and not data['verified']):
            raise ValueError('completed flow has inconsistent stage, exit code or settings')
    elif status == 'partial':
        if (code != 1 or stage != 'after' or data['rollback_status'] != 'not-needed' or
                data['changed'] != data['applied'] or data['applied'] and not data['verified']):
            raise ValueError('partial flow has inconsistent stage, exit code or settings')
    elif status == 'failed':
        if code != 1 or stage not in ('before', 'apply', 'verify'):
            raise ValueError('failed flow has inconsistent stage or exit code')
    elif code not in (130, 143):
        raise ValueError('cancelled flow must contain a cancellation exit code')
    comparison = data.get('comparison')
    if status != 'completed':
        if comparison is not None: raise ValueError('unfinished summary cannot contain a comparison')
        return
    if not isinstance(comparison, dict): raise ValueError('completed summary has no comparison')
    total = integer(data.get('budget_bytes'), 1048576, 1073741824)
    before = measurement_data(data.get('before'), 'before', budget=total // 2)
    after = measurement_data(data.get('after'), 'after', before['endpoint'], total // 2)
    if before['reserved_bytes'] + after['reserved_bytes'] > total:
        raise ValueError('run budget exceeded')
    expected = compare(before, after)
    for key in ('download_change_pct', 'upload_change_pct', 'latency_delta_ms'):
        value = comparison.get(key)
        if (type(value) not in (int, float) or not math.isfinite(value) or
                not math.isclose(value, expected[key], rel_tol=1e-9, abs_tol=1e-9)):
            raise ValueError('comparison disagrees with measurements: ' + key)
    for key in ('causal_claim', 'budget_limited'):
        if type(comparison.get(key)) is not bool or comparison[key] != expected[key]:
            raise ValueError('comparison disagrees with measurement limits: ' + key)
try:
    if op == 'endpoint':
        print(endpoint(args[0]))
    elif op == 'prepare':
        requested = Path(args[0]).absolute()
        if requested.is_symlink(): raise ValueError('report directory must not be a symbolic link')
        # Resolve ancestors once, but never follow a final symlink, including a
        # leaf raced into place before mkdir/lstat. Subsequent I/O uses this path.
        parent = requested.parent.resolve()
        root = parent.parent if requested.name == '..' else parent / requested.name
        state_root = Path(args[1]).resolve()
        if root == state_root or state_root in root.parents:
            raise ValueError(text('报告目录不能放在调优备份目录内', 'report directory cannot be inside tuning state'))
        for directory in reversed((root, *root.parents)):
            try:
                info = directory.lstat()
            except FileNotFoundError:
                try: directory.mkdir(mode=0o700)
                except FileExistsError: pass
                info = directory.lstat()
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid()) or
                    info.st_mode & 0o022 and (directory == root or not info.st_mode & stat.S_ISVTX)):
                raise ValueError(text('报告路径目录权限不安全：%s（权限 %04o，属主 UID %d）',
                                      'Unsafe report path directory: %s (mode %04o, owner UID %d)') %
                                 (repr(str(directory)), stat.S_IMODE(info.st_mode), info.st_uid))
        if root.lstat().st_uid != os.geteuid():
            raise ValueError('report directory must be owned by this user')
        run = Path(tempfile.mkdtemp(prefix='run.', dir=str(root)))
        try:
            atomic(run / '.netpilot-report', dict(type='netpilot-report-directory', version=1))
        except OSError:
            run.rmdir()
            raise
        print(run)
    elif op == 'cleanup':
        import errno
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
        def open_directory_chain(path):
            descriptors, bindings = [], []
            try:
                descriptors.append(os.open(path.anchor, flags | os.O_DIRECTORY))
                for part in path.parts[1:]:
                    if part == '..':
                        raise ValueError('parent traversal is not allowed during report cleanup')
                    parent_fd = descriptors[-1]
                    child_fd = os.open(part, flags | os.O_DIRECTORY, dir_fd=parent_fd)
                    descriptors.append(child_fd)
                    bindings.append((parent_fd, part, child_fd))
                return descriptors, bindings
            except BaseException:
                for fd in reversed(descriptors):
                    os.close(fd)
                raise
        def attached(bindings):
            for parent_fd, name, child_fd in bindings:
                entry = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                opened = os.fstat(child_fd)
                if not stat.S_ISDIR(entry.st_mode) or (entry.st_dev, entry.st_ino) != (opened.st_dev, opened.st_ino):
                    raise ValueError('report directory changed before cleanup: ' + repr(name))
        def recognized(data, kind):
            return (isinstance(data, dict) and data.get('type') == kind and
                    type(data.get('version')) is int and data['version'] == 1)
        def owned_json(directory_fd, name):
            try:
                fd = os.open(name, flags | os.O_NONBLOCK, dir_fd=directory_fd)
            except FileNotFoundError:
                return None
            with os.fdopen(fd, encoding='utf-8') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_size > 1048576:
                    raise ValueError('unsafe report identity file: ' + repr(name))
                try:
                    data = json.loads(stream.read(1048577))
                except (ValueError, RecursionError):
                    return None
                return data if isinstance(data, dict) else None
        for value in args:
            root = Path(value).absolute()
            try:
                descriptors, bindings = open_directory_chain(root)
            except FileNotFoundError:
                continue
            root_fd = descriptors[-1]
            try:
                root_info = os.fstat(root_fd)
                attached(bindings)
                if root_info.st_uid != os.geteuid() or root_info.st_mode & 0o022:
                    raise ValueError('unsafe report cleanup directory: ' + repr(str(root)))
                with os.scandir(root_fd) as entries:
                    names = [entry.name for entry in entries if entry.name.startswith('run.') and entry.is_dir(follow_symlinks=False)]
                for name in names:
                    run_fd = os.open(name, flags | os.O_DIRECTORY, dir_fd=root_fd)
                    try:
                        info = os.fstat(run_fd)
                        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
                            raise ValueError('unsafe report run directory: ' + repr(name))
                        marker = owned_json(run_fd, '.netpilot-report')
                        summary = None if marker else owned_json(run_fd, 'summary.json')
                        identified = (recognized(marker, 'netpilot-report-directory') or
                                      recognized(summary, 'netpilot-tune-report'))
                        if not identified:
                            continue
                        with os.scandir(run_fd) as entries:
                            files = [(entry.name, entry.stat(follow_symlinks=False)) for entry in entries]
                        if any(filename not in ('.netpilot-report', 'before.json', 'after.json', 'summary.json') for filename, _ in files):
                            print(text('报告目录包含其他文件，已保留：', 'Report directory contains other files and was kept: ') + repr(str(root / name)), file=sys.stderr)
                            continue
                        if any(not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() for _, info in files):
                            raise ValueError('unsafe file in report directory: ' + repr(name))
                        # Remove the ownership marker last, so interrupted cleanup
                        # can still recognize and retry an otherwise empty run.
                        identity = '.netpilot-report' if marker else 'summary.json'
                        for filename, _ in sorted(files, key=lambda item: item[0] == identity):
                            attached(bindings + [(root_fd, name, run_fd)])
                            os.unlink(filename, dir_fd=run_fd)
                        attached(bindings + [(root_fd, name, run_fd)])
                    finally:
                        os.close(run_fd)
                    os.rmdir(name, dir_fd=root_fd)
                attached(bindings)
            finally:
                for fd in reversed(descriptors):
                    os.close(fd)
            current = root.lstat()
            if (current.st_dev, current.st_ino) != (root_info.st_dev, root_info.st_ino):
                raise ValueError('report directory changed during cleanup: ' + repr(str(root)))
            try:
                root.rmdir()
            except OSError as exc:
                if exc.errno not in (errno.ENOTEMPTY, errno.EEXIST):
                    raise
    elif op == 'plan':
        d = measurement(args[0], 'before', args[1], int(args[2]), int(args[3]))
        bandwidth = max(d['download_bps'], d['upload_bps']) / 1e6
        print(format(bandwidth, '.6f'), format(d['latency_ms'], '.6f'))
    elif op == 'view':
        root = Path(args[0]).absolute()
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
        try:
            try:
                root_fd = os.open(root, flags | os.O_DIRECTORY)
            except FileNotFoundError:
                print(text('此目录暂无报告；尚未调优可选菜单 9，自定义目录请加 --report-dir DIR。', 'No reports in this directory. If tuning has not run, choose menu 9; for custom reports, add --report-dir DIR.'), file=sys.stderr)
                sys.exit(1)
            try:
                candidates = []
                with os.scandir(root_fd) as entries:
                    for entry in entries:
                        if not entry.name.startswith('run.') or not entry.is_dir(follow_symlinks=False):
                            continue
                        try:
                            run_fd = os.open(entry.name, flags | os.O_DIRECTORY, dir_fd=root_fd)
                        except FileNotFoundError:
                            continue
                        try:
                            try:
                                info = os.stat('summary.json', dir_fd=run_fd, follow_symlinks=False)
                            except FileNotFoundError:
                                continue
                            candidates.append((info.st_mtime_ns, entry.name))
                        finally:
                            os.close(run_fd)
                if not candidates:
                    print(text('此目录暂无报告；尚未调优可选菜单 9，自定义目录请加 --report-dir DIR。', 'No reports in this directory. If tuning has not run, choose menu 9; for custom reports, add --report-dir DIR.'), file=sys.stderr)
                    sys.exit(1)
                _, name = max(candidates)
                run_fd = os.open(name, flags | os.O_DIRECTORY, dir_fd=root_fd)
                try:
                    fd = os.open('summary.json', flags | os.O_NONBLOCK, dir_fd=run_fd)
                    with os.fdopen(fd, encoding='utf-8') as stream:
                        info = os.fstat(stream.fileno())
                        if not stat.S_ISREG(info.st_mode) or info.st_size > 1048576:
                            raise ValueError('expected a regular report of at most 1MiB')
                        raw = stream.read(1048577)
                        if len(raw) > 1048576:
                            raise ValueError('report exceeds 1MiB')
                        def invalid_constant(value): raise ValueError('non-finite JSON constant')
                        data = json.loads(raw, parse_constant=invalid_constant)
                finally:
                    os.close(run_fd)
            finally:
                os.close(root_fd)
            validate_summary(data)
            choices = SUMMARY_CHOICES
            comparison = data.get('comparison')
            # Escape terminal controls while keeping Chinese report text readable.
            def display(value):
                encoded = json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2)
                return encoded.translate({n: '\\u%04x' % n for n in range(127, 160)})
            rendered = display(data)
            if len(args) > 1 and args[1] == 'json':
                print(rendered)
            else:
                labels = {
                    'status': {'completed': text('完成', 'Completed'), 'failed': text('失败', 'Failed'),
                               'partial': text('部分完成', 'Partial'), 'cancelled': text('已取消', 'Cancelled')},
                    'stage': dict(zip(choices['stage'],
                                  (text('前测', 'Baseline'), text('应用', 'Apply'), text('核验', 'Verify'),
                                   text('复测', 'Retest'), text('完成', 'Completed')))),
                    'configuration_state': dict(zip(choices['configuration_state'],
                                  (text('本轮未修改', 'Unchanged this run'), text('已应用，未核验', 'Applied, unverified'),
                                   text('已应用并核验', 'Applied and verified'), text('已恢复首次原值', 'Original baseline restored'),
                                   text('状态未确认', 'Unknown')))),
                    'verify_status': {'not-needed': text('未进行或无需核验', 'Not performed or not needed'),
                                      'verified': text('通过', 'Passed'), 'failed': text('失败', 'Failed')},
                    'rollback_status': {'not-needed': text('未触发', 'Not triggered'),
                                        'completed': text('已恢复', 'Restored'), 'failed': text('失败，保留备份', 'Failed; backups retained')},
                }
                from datetime import datetime
                print(text('最新报告：', 'Latest report: ') + display(str(root / name / 'summary.json')))
                print(text('报告更新：', 'Report updated: ') + datetime.fromtimestamp(info.st_mtime).astimezone().isoformat(timespec='seconds'))
                print(text('以下为历史运行记录，不代表当前实时状态。', 'Historical run record; not the current live state.'))
                for key, label in [('status', text('流程', 'Flow')), ('stage', text('阶段', 'Stage')),
                                   ('configuration_state', text('配置', 'Configuration')), ('verify_status', text('核验', 'Verification')),
                                   ('rollback_status', text('回滚', 'Rollback'))]:
                    print(label + text('：', ': ') + labels[key][data[key]])
                if comparison is not None:
                    b, a = data['before'], data['after']
                    print(text('观测下载：%.2f → %.2f Mbps', 'Observed download: %.2f -> %.2f Mbps') % (b['download_bps']/1e6, a['download_bps']/1e6))
                    print(text('观测上传：%.2f → %.2f Mbps', 'Observed upload: %.2f -> %.2f Mbps') % (b['upload_bps']/1e6, a['upload_bps']/1e6))
                    print(text('TCP 建连延迟：%.3f → %.3f ms', 'TCP-connect latency: %.3f -> %.3f ms') % (b['latency_ms'], a['latency_ms']))
                    if comparison['budget_limited']:
                        print(text('短样本受测试预算限制，不能据此判断线路峰值。', 'Short samples are budget-limited and do not establish peak bandwidth.'))
                    if not data['changed']:
                        print(text('本轮没有修改参数，测量波动不能归因于调优。', 'No parameters changed; measurement differences cannot be attributed to tuning.'))
                if data.get('error'):
                    print(text('原因：', 'Reason: ') + display(data['error'][:2048])[1:-1])
                import shlex
                command = 'netpilot --lang en report --json' if english else 'netpilot report --json'
                if root != Path('/tmp/netpilot-reports'):
                    command += ' --report-dir ' + shlex.quote(str(root))
                controls = {n: '\\u%04x' % n for n in list(range(32)) + list(range(127, 160))}
                print(text('完整数据：', 'Full data: ') + command.translate(controls))
        except (OSError, ValueError, TypeError, KeyError, RecursionError) as exc:
            print(text('无法读取最新报告：', 'Cannot read the latest report: ') + str(exc), file=sys.stderr)
            sys.exit(1)
    elif op == 'compare':
        before = measurement(args[0], 'before')
        after = measurement(args[1], 'after', before['endpoint'], before['budget_bytes'])
        print(json.dumps(compare(before, after), allow_nan=False))
    elif op == 'summary':
        root, status, stage, code, budget, profile, changed, applied, verified, verify_status, rollback_status, error = args
        root = Path(root)
        data = dict(type='netpilot-tune-report', version=1, status=status, stage=stage,
                    exit_code=int(code), budget_bytes=int(budget), profile=profile,
                    changed=changed == '1', applied=applied == '1', verified=verified == '1',
                    verify_status=verify_status, rollback_status=rollback_status, error=error or None,
                    before_report=str(root / 'before.json'), after_report=str(root / 'after.json'))
        data['configuration_state'] = summary_configuration_state(data)
        for phase in ('before', 'after'):
            try: data[phase] = load(root / (phase + '.json'))
            except (OSError, ValueError): data[phase] = None
        data['comparison'] = None
        if status == 'completed':
            before = measurement(root / 'before.json', 'before')
            after = measurement(root / 'after.json', 'after', before['endpoint'], before['budget_bytes'])
            if before['reserved_bytes'] + after['reserved_bytes'] > int(budget): raise ValueError('run budget exceeded')
            data['comparison'] = compare(before, after)
        atomic(root / 'summary.json', data)
        if data['comparison'] is not None:
            c = data['comparison']; b = data['before']; a = data['after']
            print(text('观测下载：%.2f → %.2f Mbps（%+.2f%%）', 'Observed download: %.2f -> %.2f Mbps (%+.2f%%)') % (b['download_bps']/1e6, a['download_bps']/1e6, c['download_change_pct']))
            print(text('观测上传：%.2f → %.2f Mbps（%+.2f%%）', 'Observed upload: %.2f -> %.2f Mbps (%+.2f%%)') % (b['upload_bps']/1e6, a['upload_bps']/1e6, c['upload_change_pct']))
            print(text('TCP 建连延迟估计：%.3f → %.3f ms', 'TCP-connect latency estimate: %.3f -> %.3f ms') % (b['latency_ms'], a['latency_ms']))
            if not data['changed']: print(text('本轮没有修改参数，测量变化不能归因于调优。', 'No parameters changed; measurement differences cannot be attributed to tuning.'))
            if c['budget_limited']: print(text('样本受流量预算限制，观测速率不代表线路峰值。', 'Samples are budget-limited; observed rates do not establish peak bandwidth.'))
        print(text('自动报告：', 'Automatic report: ') + str(root / 'summary.json'))
    else:
        raise ValueError('unknown report operation')
except (ValueError, TypeError, KeyError, OSError, OverflowError) as exc:
    prefix = text('无法清理报告：', 'Cannot clean reports: ') if op == 'cleanup' else text('自动调优数据或报告无效：', 'Invalid automatic tuning data or report: ')
    print(prefix + str(exc), file=sys.stderr)
    sys.exit(1)
PY
}

auto_tune() {
  local profile=balanced budget=128 seconds=30 endpoint="$AUTO_DEFAULT_ENDPOINT" report_root="$AUTO_REPORT_ROOT" option dep
  local run_dir before after values bandwidth rtt total phase_budget status=failed stage=before error=''
  local changed=0 applied=0 verified=0 verify_status=not-needed rollback_status=not-needed auto_cancel_code=0 saved_traps
  local TRANSACTION_RECOVERY=not-attempted
  local AUTO_TUNE_ACTIVE=1 AUTO_TUNE_WRITING=0 AUTO_TUNE_ENDPOINT
  while (($#)); do
    option="$1"; shift
    case "$option" in
      --profile|--budget-mib|--timeout|--endpoint|--report-dir)
        (($#)) || { warn "$(np_msg '%s 缺少值。' 'Missing value for %s.' "$option")"; return 2; }
        case "$option" in
          --profile) profile="$1" ;; --budget-mib) budget="$1" ;; --timeout) seconds="$1" ;;
          --endpoint) endpoint="$1" ;; --report-dir) report_root="$1" ;;
        esac
        shift ;;
      -h|--help) usage; return 0 ;;
      *) warn "$(np_msg '未知自动调优选项：%s；手填路径数据请使用 apply。' 'Unknown automatic tuning option: %s; use apply for manual path inputs.' "$option")"; return 2 ;;
    esac
  done
  case "$profile" in balanced|proxy|bulk) ;; *) warn "$(np_msg 'profile 必须是 balanced、proxy 或 bulk。' 'profile must be balanced, proxy or bulk.')"; return 2 ;; esac
  bench_integer "$budget" 1 1024 && bench_integer "$seconds" 5 120 || {
    warn "$(np_msg '自动调优预算须为1–1024MiB，阶段超时须为5–120秒。' 'Automatic tuning requires a 1-1024MiB budget and a 5-120 second phase timeout.')"
    return 2
  }
  for dep in python3 timeout mktemp install; do
    command -v "$dep" >/dev/null 2>&1 || { warn "$(np_msg '自动调优缺少依赖：%s。' 'Missing automatic tuning dependency: %s.' "$dep")"; return 1; }
  done
  endpoint="$(auto_report endpoint "$endpoint")" || return 2
  run_dir="$(auto_report prepare "$report_root" "$STATE_DIR")" || return 1
  before="$run_dir/before.json"; after="$run_dir/after.json"
  total=$((10#$budget * 1048576)); phase_budget=$((total / 2)); seconds=$((10#$seconds))
  AUTO_TUNE_ENDPOINT="$endpoint"
  saved_traps="$(trap -p INT TERM HUP)"
  trap 'auto_cancel_code=130; if [[ -n "${http_measure_pid:-}" ]]; then kill -TERM "$http_measure_pid" 2>/dev/null || true; fi' INT
  trap 'auto_cancel_code=143; if [[ -n "${http_measure_pid:-}" ]]; then kill -TERM "$http_measure_pid" 2>/dev/null || true; fi' TERM HUP
  _auto_tune_restore() {
    if [[ "$TRANSACTION_RECOVERY" == completed || "$rollback_status" == completed ]] || rollback_tuning; then
      rollback_status=completed; applied=0
      return 0
    fi
    rollback_status=failed
    return 1
  }
  _auto_tune_finish() {
    local result="$1"
    if ((auto_cancel_code)); then
      status=cancelled; result="$auto_cancel_code"; error="$(np_msg '自动调优已取消。' 'Automatic tuning was cancelled.')"
      if ((AUTO_TUNE_WRITING && !verified)); then
        if ! _auto_tune_restore; then
          error="$(np_msg '已取消，但恢复未完成；当前配置状态不确定，备份已保留。' 'Cancelled, but restoration is incomplete; current settings are uncertain and backups are retained.')"
        fi
      fi
    fi
    trap - INT TERM HUP
    [[ -z "$saved_traps" ]] || eval "$saved_traps"
    if ! auto_report summary "$run_dir" "$status" "$stage" "$result" "$total" "$profile" "$changed" "$applied" "$verified" "$verify_status" "$rollback_status" "$error"; then
      warn "$(np_msg '无法保存汇总报告；已有数据保留在 %s。' 'Could not save the summary; existing data is retained in %s.' "$run_dir")"
      result=1
    fi
    [[ -z "$error" ]] || warn "$error"
    return "$result"
  }
  np_msg '自动测速目标：%s；整轮合成数据预算：%s MiB（含前后双向测试，协议开销另计）。\n' 'Automatic test endpoint: %s; whole-run synthetic payload budget: %s MiB (both directions before/after; protocol overhead is additional).\n' "$endpoint" "$budget"
  np_msg '[1/4] 保存调优前测量…\n' '[1/4] Measuring the baseline...\n'
  if ! http_measure_path before "$endpoint" "$phase_budget" "$seconds" "$before" || ((auto_cancel_code)); then
    error="$(np_msg '前测失败，未修改配置。' 'Baseline measurement failed; configuration was not changed.')"
    _auto_tune_finish 1; return $?
  fi
  values="$(auto_report plan "$before" "$endpoint" "$phase_budget" "$seconds")" || {
    error="$(np_msg '前测数据无效，未修改配置。' 'Baseline data is invalid; configuration was not changed.')"
    _auto_tune_finish 1; return $?
  }
  read -r bandwidth rtt <<< "$values"
  stage=apply
  np_msg '[2/4] 根据实测数据备份并应用方案…\n' '[2/4] Backing up and applying a measured plan...\n'
  if apply_tuning --profile "$profile" --bandwidth "$bandwidth" --rtt "$rtt" --yes; then
    if ((${#SYSCTL_KEYS[@]})); then changed=1; applied=1; fi
  else
    if ((AUTO_TUNE_WRITING && !auto_cancel_code)); then
      _auto_tune_restore || true
    fi
    error="$(np_msg '参数应用未完成，请检查恢复记录。' 'Parameter application did not complete; inspect the restoration records.')"
    _auto_tune_finish 1; return $?
  fi
  if ((auto_cancel_code)); then _auto_tune_finish 130; return $?; fi
  stage=verify
  np_msg '[3/4] 核验配置…\n' '[3/4] Verifying configuration...\n'
  if ((changed)) || [[ -f "$SYSCTL_FILE" || -f "$BBR_FILE" ]]; then
    if ! verify_tuning; then
      verify_status=failed
      if ((changed)); then
        if ! _auto_tune_restore; then
          warn "$(np_msg '自动恢复未完成，备份已保留。' 'Automatic restoration is incomplete; backups are retained.')"
        fi
      fi
      error="$(np_msg '配置核验失败，未进行复测。' 'Configuration verification failed; the post-test was not started.')"
      _auto_tune_finish 1; return $?
    fi
    verified=1; verify_status=verified
  fi
  if ((auto_cancel_code)); then _auto_tune_finish 130; return $?; fi
  stage=after
  np_msg '[4/4] 同条件复测并比较…\n' '[4/4] Retesting under the same conditions and comparing...\n'
  if ! http_measure_path after "$endpoint" "$phase_budget" "$seconds" "$after" "$before" || ((auto_cancel_code)); then
    status=partial
    error="$(np_msg '复测未完成；已核验配置保留，未生成性能对比。' 'The post-test did not complete; verified settings are retained and no performance comparison was made.')"
    _auto_tune_finish 1; return $?
  fi
  if ! auto_report compare "$before" "$after" >/dev/null; then
    status=partial
    error="$(np_msg '前后测量条件或数据不一致，无法有效比较；已核验配置保留。' 'Test conditions or data differ; a valid comparison is unavailable and verified settings are retained.')"
    _auto_tune_finish 1; return $?
  fi
  status=completed; stage=completed
  _auto_tune_finish 0
}
# END AUTO TUNE

report_command() {
  local report_root="$AUTO_REPORT_ROOT" format=text
  while (($#)); do
    case "$1" in
      --json) format=json; shift ;;
      --report-dir)
        if (($# < 2)) || [[ -z "$2" ]]; then
          warn "$(np_msg '--report-dir 需要非空目录。' '--report-dir requires a nonempty directory.')"
          return 2
        fi
        report_root="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) warn "$(np_msg '未知报告选项：%s' 'Unknown report option: %s' "$1")"; return 2 ;;
    esac
  done
  command -v python3 >/dev/null 2>&1 || { warn "$(np_msg '查看报告需要 python3。' 'Viewing reports requires python3.')"; return 1; }
  auto_report view "$report_root" "$format"
}

usage() {
  if [[ "${NETPILOT_LANG:-zh}" == en ]]; then
    cat <<'EOF'
NetPilot — Linux VPS Network Diagnostics and Tuning
Usage: netpilot [--lang zh|en] [command] [options] (or bash netpilot.sh [command])
  menu                 Default: install a downloaded copy, then open the menu; L switches language
  doctor               Read-only memory/CPU/BBR/actual-qdisc/external-tuner diagnostics
  plan [--profile balanced|proxy|bulk] [--bandwidth Mbps]
       [--rtt ms | --rtt-target HOST]
                       Generate a plan without system changes; an explicit target measures latency
  tune [--profile balanced|proxy|bulk] [--budget-mib 128] [--timeout 30]
       [--endpoint URL] [--report-dir DIR]
                       Automatically measure, back up, apply, verify, retest and compare
  apply [plan options] [--yes]  Preview, confirm, apply and persist; --yes explicitly skips confirmation
  status               Current values and suggestions; no system changes
  verify               Check persistent intent against runtime parameters; nonzero on drift
  diagnose [--seconds 1..60]  Read-only discard/retransmit/listen counters or deltas
  bench --peer HOST [--port 5201] [--budget-mib 1024]
        [--direction both|send|receive] [--streams 1] [--timeout 30] [--latency]
        [--output FILE] [--yes]  Budgeted bidirectional measurement; requires iperf3/python3/timeout
  compare BEFORE.json AFTER.json  Compare reports with matching test conditions
  report [--json] [--report-dir DIR]  View latest results; --json prints the full report
  rollback             Restore the first saved values; retain backups on failure
  install              Explicitly install NetPilot and the netpilot shortcut
  update               Download and validate updates from the project repository
  uninstall [--rollback]  Remove the tool and default reports; keep tuning unless --rollback is used
  help                 Show this help
Basic commands require Linux/Bash 4+. Benchmark dependencies are installed separately.
Profiles: balanced = general (default); proxy = proxies/many connections, more conservative buffers; bulk = a few large transfers, larger buffer recommendations.
Automatic tune requires Python 3 and GNU timeout; its default 128MiB payload budget covers the complete before/after run.
Manual --rtt-target probing requires --bandwidth, ping and GNU timeout. --rtt and --rtt-target are mutually exclusive.
First menu startup from a downloaded copy requires root; then use netpilot to reopen. Read-only commands never install automatically.
Language: Chinese by default; use NETPILOT_LANG=en or --lang en. The command-line option takes precedence.
EOF
  else
    cat <<'EOF'
NetPilot — Linux VPS 网络诊断与调优
用法：netpilot [--lang zh|en] [命令] [参数]（也可 bash netpilot.sh [命令]）
  menu                 默认入口：下载副本先安装再打开菜单，L 切换中英文
  doctor               只读查看内存/CPU/BBR/实际qdisc/外部调优器
  plan [--profile balanced|proxy|bulk] [--bandwidth Mbps]
       [--rtt ms | --rtt-target HOST]
                       生成参数计划，不修改系统；指定目标时自动测延迟
  tune [--profile balanced|proxy|bulk] [--budget-mib 128] [--timeout 30]
       [--endpoint URL] [--report-dir DIR]
                       自动前测、备份调优、核验、复测和对比，无需手填数值
  apply [同plan参数] [--yes]  预览、确认后应用并持久化；--yes显式跳过确认
  status               当前值与建议，不修改系统
  verify               核对持久配置和当前参数，偏离时返回非零
  diagnose [--seconds 1..60]  只读丢弃/重传/监听队列计数或观察增量
  bench --peer HOST [--port 5201] [--budget-mib 1024]
        [--direction both|send|receive] [--streams 1] [--timeout 30] [--latency]
        [--output FILE] [--yes]  有预算的双向测速，需iperf3/python3/timeout
  compare BEFORE.json AFTER.json  比较同条件测速报告
  report [--json] [--report-dir DIR]  查看最新结果；--json 输出完整报告
  rollback             恢复首次记录的原值；失败保留备份
  install              显式安装 NetPilot 及 netpilot 快捷命令
  update               从自有仓库下载并检查更新
  uninstall [--rollback]  删除工具和默认报告，保留调优；--rollback 先恢复配置再卸载
  help                 显示帮助
基础命令需要Linux/Bash4+。测速依赖按需安装，脚本不自动安装测速工具。
配置档：balanced 通用（默认）；proxy 代理/多连接，缓冲建议更保守；bulk 少量大文件传输，缓冲建议更大。
一键调优需 Python 3 和 GNU timeout；默认 128MiB 测试数据预算覆盖整轮前后双向测量。
手动使用 --rtt-target 测延迟需同时提供 --bandwidth，并安装 ping 和 GNU timeout；--rtt 与 --rtt-target 互斥。
从下载副本首次打开菜单需要 root；保存后用 netpilot 再次打开。只读命令不会自动安装。
语言：默认中文；NETPILOT_LANG=en 或 --lang en 使用英文，命令行选项优先。
EOF
  fi
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
    np_msg '%s 上的实际 qdisc（与 default_qdisc 不同）：\n' 'Actual qdisc on %s (distinct from default_qdisc):\n' "$iface"
    tc -s qdisc show dev "$iface" 2>/dev/null || warn "$(np_msg '无法读取实际 qdisc。' 'Unable to read actual qdisc.')"
  else
    log "$(np_msg '实际 qdisc 不可用（缺少路由或 tc）。' 'Actual qdisc is unavailable (missing route or tc).')"
  fi
}

transaction_failed() {
  warn "$1"
  TRANSACTION_RECOVERY=failed
  if rollback_internal; then
    TRANSACTION_RECOVERY=completed
  else
    warn "$(np_msg '恢复未完成，原值状态已保留。' 'Recovery incomplete; saved state is retained.')"
  fi
  return 1
}

run_mutation() {
  local status=0
  need_root
  command -v flock >/dev/null 2>&1 || { warn "$(np_msg '修改配置需要 flock。' 'flock is required for changes.')"; return 1; }
  exec 9>/run/netpilot.lock || return 1
  if ! flock -n 9; then
    warn "$(np_msg '已有另一个调优操作正在运行。' 'Another tuning operation is running.')"
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
    SOURCE_SNAPSHOT="$(mktemp /tmp/netpilot.XXXXXX)"
    if ! command -v curl >/dev/null 2>&1 || ! curl --fail --silent --show-error \
      --location --proto '=https' --tlsv1.2 --output "$SOURCE_SNAPSHOT" "$UPDATE_URL"; then
      rm -f -- "$SOURCE_SNAPSHOT"
      printf '%s\n' "$(np_msg '[NetPilot] 错误：无法重新下载 GitHub 脚本。' '[NetPilot] Error: cannot re-download the GitHub script.')" >&2
      exit 1
    fi
    if [[ ! -s "$SOURCE_SNAPSHOT" ]]; then
      rm -f -- "$SOURCE_SNAPSHOT"
      printf '%s\n' "$(np_msg '[NetPilot] 错误：下载的 GitHub 脚本为空。' '[NetPilot] Error: the downloaded GitHub script is empty.')" >&2
      exit 1
    fi
    if ! bash -n "$SOURCE_SNAPSHOT"; then
      rm -f -- "$SOURCE_SNAPSHOT"
      warn "$(np_msg '下载的安装脚本语法检查失败，未安装。' 'Downloaded installation script failed syntax validation; nothing was installed.')"
      return 1
    fi
    SCRIPT_PATH="$SOURCE_SNAPSHOT"
  fi
}

install_from_source() {
  local status=0
  resolve_source_path || return 1
  run_mutation install_local_copy "$@" || status=$?
  if [[ -n "$SOURCE_SNAPSHOT" ]]; then
    rm -f -- "$SOURCE_SNAPSHOT" || status=1
  fi
  return "$status"
}

# CLI entry point: sourcing this file only defines functions and constants.
main() {
  local AUTO_TUNE_ACTIVE=0
  while (($#)); do
    case "$1" in
      --lang)
        (($# >= 2)) || { printf '%s\n' '--lang 需要 zh 或 en / --lang requires zh or en.' >&2; return 2; }
        np_set_language "$2" || return $?
        shift 2 ;;
      --lang=*) np_set_language "${1#--lang=}" || return $?; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  np_set_language "${NETPILOT_LANG:-zh}" || return $?
  [[ "$(uname -s)" == Linux ]] || { warn "$(np_msg '本工具需要 Linux。' 'This tool requires Linux.')"; return 2; }
  # Help must remain read-only, including for commands that normally mutate.
  if (($# == 2)) && [[ "$2" == --help || "$2" == -h ]]; then
    case "$1" in
      bench) bench_usage; return 0 ;;
      menu|doctor|plan|apply|status|verify|diagnose|compare|report|rollback|install|update|uninstall|tune|help)
        usage; return 0 ;;
    esac
  fi
  case "${1:-menu}" in
    help|--help|-h|doctor|status|verify|menu|rollback|update|install)
      if (($# > 1)); then
        warn "$(np_msg '%s 不接受额外参数：%s' '%s does not accept extra arguments: %s' "$1" "${*:2}")"
        return 2
      fi ;;
  esac
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
    report) report_command "${@:2}"; return ;;
    menu)
      # An installed script (including its shortcut) can open without writing.
      if [[ -f "$INSTALL_PATH" && ! -L "$INSTALL_PATH" && "$SOURCE_PATH" -ef "$INSTALL_PATH" ]]; then
        menu
      else
        need_root
        need_command mktemp
        need_command install
        install_from_source menu
      fi
      return ;;
  esac
  need_root
  need_command mktemp
  need_command install
  case "${1:-menu}" in
    tune) run_mutation auto_tune "${@:2}" ;;
    apply) run_mutation apply_tuning "${@:2}" ;;
    rollback) run_mutation rollback_tuning ;;
    install) install_from_source ;;
    update) run_mutation check_update ;;
    uninstall)
      resolve_source_path || return 1
      run_mutation uninstall_own_script "${@:2}" ;;
    *) usage; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
