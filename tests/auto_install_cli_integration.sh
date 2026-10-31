#!/usr/bin/env bash
# Real installation paths are exercised only inside a disposable container.
# This is intentionally excluded from the default test_*.sh suite.
set -Eeuo pipefail
[[ -f /.dockerenv && "$EUID" == 0 ]] || { printf 'Run only as root in a disposable Docker container.\n' >&2; exit 2; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/netpilot.sh"
INSTALL=/usr/local/bin/netpilot.sh
SHORTCUT=/usr/local/bin/netpilot
TMP="$(mktemp -d)"
trap 'command rm -rf -- "$TMP"' EXIT
chmod 0755 "$TMP"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for dep in setpriv sha256sum sysctl; do command -v "$dep" >/dev/null || fail "missing dependency: $dep"; done
for path in "$INSTALL" "$SHORTCUT" /var/lib/netpilot /run/netpilot.lock /etc/sysctl.d/10-netpilot-bbr.conf /etc/sysctl.d/99-netpilot.conf /etc/modules-load.d/netpilot.conf; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "container is not clean: $path"
done
SOURCE_HASH="$(sha256sum "$SCRIPT" | awk '{print $1}')"
if [[ -e /etc/gai.conf ]]; then sha256sum /etc/gai.conf > "$TMP/gai.before"; else : > "$TMP/gai.missing"; fi
for key in net.ipv4.tcp_congestion_control net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
  printf '%s=%s\n' "$key" "$(sysctl -n "$key")" >> "$TMP/sysctl.before"
done
assert_no_tuning() {
  local key value
  for path in /var/lib/netpilot /etc/sysctl.d/10-netpilot-bbr.conf /etc/sysctl.d/99-netpilot.conf /etc/modules-load.d/netpilot.conf; do
    [[ ! -e "$path" && ! -L "$path" ]] || fail "menu launch wrote tuning state: $path"
  done
  if [[ -e "$TMP/gai.missing" ]]; then [[ ! -e /etc/gai.conf ]] || fail 'menu launch created gai.conf'
  else sha256sum --check --status "$TMP/gai.before" || fail 'menu launch changed gai.conf'; fi
  while IFS='=' read -r key value; do
    [[ "$(sysctl -n "$key")" == "$value" ]] || fail "menu launch changed kernel parameter: $key"
  done < "$TMP/sysctl.before"
}
assert_installed() {
  [[ -f "$INSTALL" && ! -L "$INSTALL" ]] || fail 'default startup did not install its script'
  [[ -L "$SHORTCUT" && "$(readlink "$SHORTCUT")" == "$INSTALL" ]] || fail 'default startup did not create its shortcut'
  cmp -s "$SCRIPT" "$INSTALL" || fail 'installed script differs from the launch payload'
  assert_no_tuning
}
clear_installation() {
  command rm -f -- "$SHORTCUT" "$INSTALL"
}

# Loading definitions and invoking an explicit read-only command must never
# acquire the installation lock, install, or create saved state.
bash -c 'source "$1"' _ "$SCRIPT"
for command in help doctor plan status diagnose; do
  bash "$SCRIPT" "$command" > "$TMP/readonly-$command.log" 2>&1
done
bash "$SCRIPT" bench --help > "$TMP/readonly-bench.log"
if bash "$SCRIPT" verify > "$TMP/readonly-verify.log" 2>&1; then fail 'verify accepted absent configuration'; fi
if bash "$SCRIPT" compare "$TMP/absent-before.json" "$TMP/absent-after.json" > "$TMP/readonly-compare.log" 2>&1; then fail 'compare accepted absent reports'; fi
for path in "$INSTALL" "$SHORTCUT" /run/netpilot.lock; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "read-only invocation installed or locked: $path"
done
assert_no_tuning
printf 'PASS: definitions and explicit read-only commands never install, lock, or tune\n'

# A real non-root first launch cannot publish privileged installation files.
if printf '0\n' | setpriv --reuid=65534 --regid=65534 --clear-groups bash "$SCRIPT" > "$TMP/nonroot-first.log" 2>&1; then
  fail 'non-root first startup incorrectly reported successful installation'
fi
[[ ! -e "$INSTALL" && ! -e "$SHORTCUT" && ! -L "$SHORTCUT" ]] || fail 'non-root first launch partially installed'

printf '0\n' | env -u NETPILOT_LANG bash "$SCRIPT" > "$TMP/default.log"
assert_installed
grep -q '网络诊断与调优' "$TMP/default.log" || fail 'default installation did not open the Chinese menu'
printf 'PASS: one default launch saves the script, creates the shortcut, and opens Chinese menu\n'
clear_installation

printf '0\n' | bash "$SCRIPT" menu > "$TMP/explicit-menu.log"
assert_installed
printf 'PASS: explicit menu entry has the same combined install-and-open behavior\n'
clear_installation

mkdir "$TMP/bin"
cat > "$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
output=''; url=''
while (($#)); do
  case "$1" in
    --output|-o) output="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ "$url" == 'https://github.com/luckiestultra/netpilot/raw/refs/heads/main/netpilot.sh' && -n "$output" ]] || exit 22
printf '%s\n' "$url" >> "$NETPILOT_CURL_LOG"
cp -- "$NETPILOT_TEST_PAYLOAD" "$output"
CURL
chmod 0755 "$TMP/bin/curl"
export NETPILOT_CURL_LOG="$TMP/downloads.log" NETPILOT_TEST_PAYLOAD="$SCRIPT"
export PATH="$TMP/bin:$PATH"
printf '0\n' | bash <(cat "$SCRIPT") --lang en > "$TMP/stream.log"
assert_installed
grep -q 'Network Diagnostics' "$TMP/stream.log" || fail 'stream install lost English selection across exec'
[[ -s "$NETPILOT_CURL_LOG" ]] || fail 'stream installation did not obtain a reusable source snapshot'
downloads_before="$(wc -l < "$NETPILOT_CURL_LOG")"
printf '0\n' | "$SHORTCUT" --lang en > "$TMP/reopen.log"
[[ "$(wc -l < "$NETPILOT_CURL_LOG")" == "$downloads_before" ]] || fail 'installed shortcut downloaded again'
grep -q 'Network Diagnostics' "$TMP/reopen.log" || fail 'installed shortcut did not reopen menu'
printf '0\n' | setpriv --reuid=65534 --regid=65534 --clear-groups "$SHORTCUT" --lang en > "$TMP/nonroot-installed.log"
grep -q 'Network Diagnostics' "$TMP/nonroot-installed.log" || fail 'non-root installed command cannot open read-only menu'
assert_no_tuning
printf 'PASS: streamed startup preserves English; saved shortcut reopens without downloads or root\n'

# A legitimate older owned payload is upgraded by a fresh downloaded version.
printf '\n# Previously installed NetPilot revision.\n' >> "$INSTALL"
printf '0\n' | bash "$SCRIPT" > "$TMP/owned-update.log"
assert_installed
printf 'PASS: a fresh launch replaces an older owned NetPilot payload\n'
clear_installation

# Foreign script contents and symbolic-link targets must not be overwritten,
# including when the source itself came from process substitution.
printf '#!/bin/bash\nprintf independent\n' > "$INSTALL"
foreign_hash="$(sha256sum "$INSTALL" | awk '{print $1}')"
if printf '0\n' | bash <(cat "$SCRIPT") > "$TMP/foreign.log" 2>&1; then fail 'foreign install target was accepted'; fi
[[ "$(sha256sum "$INSTALL" | awk '{print $1}')" == "$foreign_hash" ]] || fail 'foreign installed file was replaced'
[[ ! -e "$SHORTCUT" && ! -L "$SHORTCUT" ]] || fail 'foreign script target published a shortcut'
if bash "$SCRIPT" update > "$TMP/foreign-update.log" 2>&1; then fail 'update accepted a foreign installation'; fi
[[ "$(sha256sum "$INSTALL" | awk '{print $1}')" == "$foreign_hash" ]] || fail 'update replaced foreign installed file'
[[ -z "$(find /tmp -maxdepth 1 -name 'netpilot.*' -print -quit)" ]] || fail 'failed streamed installation left its source snapshot'
command rm -f -- "$INSTALL"
printf 'foreign target\n' > "$TMP/symlink-target"
ln -s "$TMP/symlink-target" "$INSTALL"
if printf '0\n' | bash "$SCRIPT" > "$TMP/symlink.log" 2>&1; then fail 'symlink install target was accepted'; fi
[[ -L "$INSTALL" && "$(cat "$TMP/symlink-target")" == 'foreign target' ]] || fail 'symlink installation target was modified'
command rm -f -- "$INSTALL"
printf 'PASS: foreign installed files and symlink targets are preserved\n'

# A streamed first launch rejected by another operation's lock must discard its
# download snapshot, propagate failure and never enter the menu.
if flock -n /run/netpilot.lock bash -c 'printf "0\n" | bash <(cat "$1")' _ "$SCRIPT" > "$TMP/locked.log" 2>&1; then
  fail 'startup ignored the held installation lock'
fi
[[ ! -e "$INSTALL" && ! -e "$SHORTCUT" && ! -L "$SHORTCUT" ]] || fail 'locked startup published an installation'
[[ -z "$(find /tmp -maxdepth 1 -name 'netpilot.*' -print -quit)" ]] || fail 'locked startup left its source snapshot'
! grep -q '网络诊断与调优' "$TMP/locked.log" || fail 'locked startup opened the menu'
printf 'PASS: a held lock prevents startup and streamed source snapshots are cleaned\n'

for kind in regular symlink; do
  if [[ "$kind" == regular ]]; then printf 'independent shortcut\n' > "$SHORTCUT"
  else ln -s "$TMP/absent-command" "$SHORTCUT"; fi
  printf '0\n' | bash "$SCRIPT" > "$TMP/shortcut-$kind.log" 2>&1
  [[ -f "$INSTALL" && ! -L "$INSTALL" ]] || fail 'shortcut collision prevented independent payload installation'
  cmp -s "$SCRIPT" "$INSTALL" || fail 'shortcut collision installed an unexpected payload'
  if [[ "$kind" == regular ]]; then [[ "$(cat "$SHORTCUT")" == 'independent shortcut' ]] || fail 'foreign regular shortcut was overwritten'
  else [[ -L "$SHORTCUT" && "$(readlink "$SHORTCUT")" == "$TMP/absent-command" ]] || fail 'foreign symlink shortcut was overwritten'; fi
  grep -Eq '已被其他文件占用|occupied by another file' "$TMP/shortcut-$kind.log" || fail 'shortcut collision was not reported'
  assert_no_tuning
  clear_installation
done
printf 'PASS: occupied shortcut paths remain unchanged and are reported\n'

[[ "$(sha256sum "$SCRIPT" | awk '{print $1}')" == "$SOURCE_HASH" ]] || fail 'startup modified its source payload'
assert_no_tuning
printf 'PASS: combined startup lifecycle preserves source and never applies tuning implicitly\n'
