#!/usr/bin/env bash
# Writes real system paths only inside a disposable Docker container.
set -Eeuo pipefail
[[ -f /.dockerenv && "$EUID" == 0 ]] || { echo 'Run only as root inside a disposable Docker container.' >&2; exit 2; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/netpilot.sh"
IGNORED_PATHS="${FRESH_IGNORED_PATHS_FILE:?Provide external namespace sentinel paths via FRESH_IGNORED_PATHS_FILE.}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v setpriv >/dev/null || fail 'setpriv is required for real permission failure validation'
[[ -f "$SCRIPT" && ! -L "$SCRIPT" && -f "$IGNORED_PATHS" ]] || fail 'script or external sentinel fixture is missing'
for path in /usr/local/bin/netpilot.sh /usr/local/bin/netpilot /var/lib/netpilot /run/netpilot.lock /etc/sysctl.d/10-netpilot-bbr.conf /etc/sysctl.d/99-netpilot.conf /etc/modules-load.d/netpilot.conf /etc/security/limits.d/99-netpilot.conf; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "container is not clean: $path"
done
TMP="$(mktemp -d)"
trap 'command rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin"
SOURCE_HASH="$(sha256sum "$SCRIPT" | awk '{print $1}')"
# Namespace names are external test data, not part of the NetPilot product.
: > "$TMP/ignored-before"
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    /var/lib/*/sentinel|/usr/local/bin/*|/etc/sysctl.d/*.conf|/etc/modules-load.d/*.conf|/etc/security/limits.d/*.conf|/run/*.lock) ;;
    *) fail "sentinel fixture path is outside expected test scope: $path" ;;
  esac
  case "$path" in *netpilot*) fail 'external sentinels must not occupy the NetPilot namespace' ;; esac
  [[ ! -e "$path" && ! -L "$path" ]] || fail "external fixture path is not clean: $path"
  mkdir -p -- "$(dirname "$path")"
  printf 'independent external namespace sentinel\n' > "$path"
  sha256sum "$path" >> "$TMP/ignored-before"
done < "$IGNORED_PATHS"
[[ -s "$TMP/ignored-before" ]] || fail 'external sentinel fixture is empty'

bash "$SCRIPT" help > "$TMP/help"
bash "$SCRIPT" doctor > "$TMP/doctor"
bash "$SCRIPT" plan --profile proxy --bandwidth 100 --rtt 50 > "$TMP/plan"
for path in /usr/local/bin/netpilot.sh /usr/local/bin/netpilot /var/lib/netpilot /run/netpilot.lock /etc/sysctl.d/10-netpilot-bbr.conf /etc/sysctl.d/99-netpilot.conf /etc/modules-load.d/netpilot.conf /etc/security/limits.d/99-netpilot.conf; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "read-only command wrote NetPilot system path: $path"
done
sha256sum --check --status "$TMP/ignored-before" || fail 'read-only command changed external namespace'
printf 'PASS: help, doctor and plan perform zero NetPilot installation/state/config writes\n'

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
[[ "$url" == 'https://github.com/liuxr0814/netpilot/raw/refs/heads/main/netpilot.sh' && -n "$output" ]] || exit 22
printf '%s\n' "$url" >> "$NETPILOT_CURL_LOG"
cp -- "$NETPILOT_TEST_PAYLOAD" "$output"
CURL
chmod 0755 "$TMP/bin/curl"
export NETPILOT_CURL_LOG="$TMP/downloads.log"
export NETPILOT_TEST_PAYLOAD="$SCRIPT"
export PATH="$TMP/bin:$PATH"

printf '0\n' | bash "$SCRIPT" install > "$TMP/install.log"
[[ -f /usr/local/bin/netpilot.sh && -L /usr/local/bin/netpilot && "$(readlink /usr/local/bin/netpilot)" == /usr/local/bin/netpilot.sh ]] || fail 'fresh installation did not publish its single command'
cmp -s "$SCRIPT" /usr/local/bin/netpilot.sh || fail 'fresh installed payload differs from source'
command rm -f /usr/local/bin/netpilot
printf '0\n' | /usr/local/bin/netpilot.sh update > "$TMP/update.log"
grep -Fxq 'https://github.com/liuxr0814/netpilot/raw/refs/heads/main/netpilot.sh' "$NETPILOT_CURL_LOG" || fail 'updater did not request canonical URL'
[[ -L /usr/local/bin/netpilot && "$(readlink /usr/local/bin/netpilot)" == /usr/local/bin/netpilot.sh ]] || fail 'updater did not restore missing command'
printf 'if then invalid\n' > "$TMP/invalid-payload"
export NETPILOT_TEST_PAYLOAD="$TMP/invalid-payload"
if /usr/local/bin/netpilot update > "$TMP/update-invalid.log" 2>&1; then fail 'updater accepted invalid syntax'; fi
[[ "$(sha256sum /usr/local/bin/netpilot.sh | awk '{print $1}')" == "$SOURCE_HASH" && -L /usr/local/bin/netpilot ]] || fail 'failed update changed current installation'
export NETPILOT_TEST_PAYLOAD="$SCRIPT"
printf 'PASS: fresh install and canonical update preserve single command; invalid update retains current script\n'

printf '# original address selection policy\n' > /etc/gai.conf
cp -a /etc/gai.conf "$TMP/original-gai"
printf '1\n0\n' | /usr/local/bin/netpilot > "$TMP/menu.log"
[[ -f /var/lib/netpilot/original-values && -f /var/lib/netpilot/backup/gai-file ]] || fail 'explicit operation did not record NetPilot baseline'
cmp -s "$TMP/original-gai" /var/lib/netpilot/backup/gai-file || fail 'new baseline differs from original config'
/usr/local/bin/netpilot rollback > "$TMP/rollback.log"
cmp -s "$TMP/original-gai" /etc/gai.conf || fail 'rollback did not restore original content'
[[ ! -e /var/lib/netpilot ]] || fail 'successful rollback left owned state'
sha256sum --check --status "$TMP/ignored-before" || fail 'install/apply/rollback changed external namespace'
printf 'PASS: real IPv4 operation records only NetPilot state; rollback restores its exact baseline\n'

# A real kernel permission denial must propagate through the entire CLI.
BIN_MODE="$(stat -c '%a' /usr/local/bin)"
chmod 0555 /usr/local/bin
if printf 'y\n' | setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all /usr/local/bin/netpilot uninstall > "$TMP/uninstall-permission.log" 2>&1; then fail 'uninstall ignored real alias deletion failure'; fi
chmod "$BIN_MODE" /usr/local/bin
[[ -L /usr/local/bin/netpilot && -f /usr/local/bin/netpilot.sh ]] || fail 'failed alias removal deleted installation'
if grep -q '已移除' "$TMP/uninstall-permission.log"; then fail 'failed alias deletion printed completion'; fi
printf 'y\n' | /usr/local/bin/netpilot uninstall > "$TMP/uninstall.log"
[[ ! -e /usr/local/bin/netpilot.sh && ! -L /usr/local/bin/netpilot ]] || fail 'successful uninstall left owned installation'
printf 'PASS: actual GNU rm permission denial is nonzero without false completion; corrected permission allows uninstall\n'

for kind in regular symlink; do
  if [[ "$kind" == regular ]]; then printf 'independent command\n' > /usr/local/bin/netpilot
  else ln -s /opt/nonexistent-command /usr/local/bin/netpilot; fi
  printf '0\n' | bash "$SCRIPT" install > "$TMP/install-$kind.log"
  [[ -f /usr/local/bin/netpilot.sh ]] || fail 'command collision prevented independent payload install'
  printf 'y\n' | bash "$SCRIPT" uninstall > "$TMP/uninstall-$kind.log"
  if [[ "$kind" == regular ]]; then
    [[ "$(cat /usr/local/bin/netpilot)" == 'independent command' ]] || fail 'unrelated regular command was changed'
  else [[ -L /usr/local/bin/netpilot && "$(readlink /usr/local/bin/netpilot)" == /opt/nonexistent-command ]] || fail 'unrelated symlink command was changed'; fi
  command rm -f /usr/local/bin/netpilot
  printf 'PASS: %s command collision survives fresh install/uninstall unchanged\n' "$kind"
done
sha256sum --check --status "$TMP/ignored-before" || fail 'new CLI modified files in other namespaces'
[[ "$(sha256sum "$SCRIPT" | awk '{print $1}')" == "$SOURCE_HASH" ]] || fail 'CLI modified source payload'
printf 'PASS: complete NetPilot lifecycle leaves external namespaces and source bytes unchanged\n'
