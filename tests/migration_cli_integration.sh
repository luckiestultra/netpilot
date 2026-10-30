#!/usr/bin/env bash
# Destructive only inside a disposable Docker container; excluded from tests/run.sh.
set -Eeuo pipefail
[[ -f /.dockerenv && "$EUID" == 0 ]] || { echo 'Run only as root inside a disposable Docker container.' >&2; exit 2; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL="$ROOT/netpilot.sh"
COMPAT="$ROOT/vps-tcp-full-tune.sh"
OLD="${MIGRATION_OLD_SCRIPT:?Provide the original 231fe47 script via MIGRATION_OLD_SCRIPT.}"
OLD_HASH=f7edb90a43f4d69392a87b5e4ddfeddb166db236a4b50252ff5748fae12da5a1
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ "$(sha256sum "$OLD" | awk '{print $1}')" == "$OLD_HASH" ]] || fail 'old updater fixture is not the original audited script'
[[ -f "$CANONICAL" && -f "$COMPAT" && ! -L "$COMPAT" ]] || fail 'standalone entrypoints are missing'
cmp -s "$CANONICAL" "$COMPAT" || fail 'legacy raw payload is not the full current script'
for path in /usr/local/bin/tcp.sh /usr/local/bin/tcp /usr/local/bin/t /usr/local/bin/netpilot /var/lib/vps-tcp-full-tune; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "container is not clean: $path"
done
TMP="$(mktemp -d)"
trap 'command rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" /opt/3x-ui
printf 'unrelated panel data\n' > /opt/3x-ui/netpilot-migration-sentinel
SENTINEL_HASH="$(sha256sum /opt/3x-ui/netpilot-migration-sentinel | awk '{print $1}')"
CANONICAL_HASH="$(sha256sum "$CANONICAL" | awk '{print $1}')"
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
case "$url" in
  https://github.com/liuxr0814/vps-tcp-tune/raw/refs/heads/main/vps-tcp-full-tune.sh|https://github.com/liuxr0814/netpilot/raw/refs/heads/main/netpilot.sh) ;;
  *) printf 'Unexpected download URL: %s\n' "$url" >&2; exit 22 ;;
esac
[[ -n "$output" ]] || exit 2
printf '%s\n' "$url" >> "$MIGRATION_CURL_LOG"
cp -- "$MIGRATION_PAYLOAD" "$output"
CURL
chmod 0755 "$TMP/bin/curl"
export MIGRATION_CURL_LOG="$TMP/downloads.log"
export MIGRATION_PAYLOAD="$COMPAT"
export PATH="$TMP/bin:$PATH"

# Install the genuine old binary and apply one reversible old menu operation.
install -m 0755 "$OLD" /usr/local/bin/tcp.sh
ln -s /usr/local/bin/tcp.sh /usr/local/bin/tcp
ln -s /usr/local/bin/tcp.sh /usr/local/bin/t
printf '# original IPv6/IPv4 selection policy\n' > /etc/gai.conf
cp -a /etc/gai.conf "$TMP/original-gai"
printf '1\n0\n' | /usr/local/bin/tcp > "$TMP/old-menu.log"
[[ -f /var/lib/vps-tcp-full-tune/original-values ]] || fail 'old operation did not create real state'
cmp -s "$TMP/original-gai" /var/lib/vps-tcp-full-tune/backup/gai-file || fail 'old baseline does not match original'
BASELINE_HASH="$(sha256sum /var/lib/vps-tcp-full-tune/backup/gai-file | awk '{print $1}')"

# The old updater requests its hardcoded legacy URL and installs a single file.
printf '0\n' | /usr/local/bin/tcp update > "$TMP/old-update.log"
grep -Fxq 'https://github.com/liuxr0814/vps-tcp-tune/raw/refs/heads/main/vps-tcp-full-tune.sh' "$MIGRATION_CURL_LOG" || fail 'did not exercise genuine legacy updater URL'
cmp -s "$CANONICAL" /usr/local/bin/tcp.sh || fail 'old updater did not install full NetPilot payload'
/usr/local/bin/tcp help > "$TMP/new-help"
grep -q 'NetPilot' "$TMP/new-help" || fail 'old updater did not reach new branded CLI'
[[ "$(sha256sum /var/lib/vps-tcp-full-tune/backup/gai-file | awk '{print $1}')" == "$BASELINE_HASH" ]] || fail 'updating changed legacy baseline'
/usr/local/bin/tcp install > "$TMP/add-alias.log"
[[ -L /usr/local/bin/netpilot && "$(readlink /usr/local/bin/netpilot)" == /usr/local/bin/tcp.sh ]] || fail 'installed-path install did not add NetPilot alias'
command rm -f /usr/local/bin/netpilot
printf '0\n' | /usr/local/bin/tcp update > "$TMP/new-update.log"
grep -Fxq 'https://github.com/liuxr0814/netpilot/raw/refs/heads/main/netpilot.sh' "$MIGRATION_CURL_LOG" || fail 'new updater did not request canonical URL'
[[ -L /usr/local/bin/netpilot && "$(readlink /usr/local/bin/netpilot)" == /usr/local/bin/tcp.sh ]] || fail 'new updater did not restore missing NetPilot alias'
/usr/local/bin/netpilot doctor > "$TMP/doctor.log"
[[ "$(sha256sum /var/lib/vps-tcp-full-tune/backup/gai-file | awk '{print $1}')" == "$BASELINE_HASH" ]] || fail 'read-only command changed legacy baseline'
/usr/local/bin/netpilot rollback > "$TMP/rollback.log"
cmp -s "$TMP/original-gai" /etc/gai.conf || fail 'NetPilot did not restore pre-rename baseline'
[[ ! -e /var/lib/vps-tcp-full-tune ]] || fail 'successful rollback did not clean owned state'
printf 'y\n' | /usr/local/bin/netpilot uninstall > "$TMP/uninstall.log"
for path in /usr/local/bin/tcp.sh /usr/local/bin/tcp /usr/local/bin/t /usr/local/bin/netpilot; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "owned installation remains: $path"
done
printf 'PASS: genuine old CLI update installs new standalone payload; baseline, new alias, rollback and uninstall work\n'

# A downloaded NetPilot must identify and remove an older installed version
# without executing its top-level code.
install -m 0755 "$OLD" /usr/local/bin/tcp.sh
printf '\ntouch "%s"\n' "$TMP/target-executed" >> /usr/local/bin/tcp.sh
ln -s /usr/local/bin/tcp.sh /usr/local/bin/tcp
ln -s /usr/local/bin/tcp.sh /usr/local/bin/netpilot
printf 'y\n' | bash "$CANONICAL" uninstall > "$TMP/old-uninstall.log"
[[ ! -e "$TMP/target-executed" && ! -e /usr/local/bin/tcp.sh && ! -L /usr/local/bin/netpilot && ! -L /usr/local/bin/tcp ]] || fail 'old installed identity was refused or executed'
printf 'PASS: downloaded NetPilot uninstalls old owned revision using static recognition only\n'

# Fresh installs/uninstalls preserve both regular and dangling symlink collisions.
for kind in regular symlink; do
  if [[ "$kind" == regular ]]; then printf 'unrelated NetPilot command\n' > /usr/local/bin/netpilot
  else ln -s /opt/nonexistent-netpilot-command /usr/local/bin/netpilot; fi
  printf '0\n' | bash "$CANONICAL" install > "$TMP/install-$kind.log"
  [[ -f /usr/local/bin/tcp.sh && -L /usr/local/bin/tcp ]] || fail 'collision blocked compatible installation'
  printf 'y\n' | /usr/local/bin/tcp uninstall > "$TMP/uninstall-$kind.log"
  if [[ "$kind" == regular ]]; then
    [[ "$(cat /usr/local/bin/netpilot)" == 'unrelated NetPilot command' ]] || fail 'regular alias collision was changed'
  else [[ -L /usr/local/bin/netpilot && "$(readlink /usr/local/bin/netpilot)" == /opt/nonexistent-netpilot-command ]] || fail 'unrelated alias symlink was changed'; fi
  command rm -f /usr/local/bin/netpilot
  printf 'PASS: new CLI preserves %s NetPilot command collision through install/uninstall\n' "$kind"
done

# New updater rejects a bad payload and never replaces the installed script.
printf '0\n' | bash "$CANONICAL" install > "$TMP/install-update.log"
printf 'if then invalid\n' > "$TMP/invalid-payload"
export MIGRATION_PAYLOAD="$TMP/invalid-payload"
if /usr/local/bin/tcp update > "$TMP/update-invalid.log" 2>&1; then fail 'new updater accepted invalid script'; fi
[[ "$(sha256sum /usr/local/bin/tcp.sh | awk '{print $1}')" == "$CANONICAL_HASH" ]] || fail 'failed update changed installation'
[[ -L /usr/local/bin/netpilot && -L /usr/local/bin/tcp ]] || fail 'failed update removed aliases'
printf 'y\n' | /usr/local/bin/tcp uninstall > "$TMP/uninstall-final.log"
[[ "$(sha256sum "$CANONICAL" | awk '{print $1}')" == "$CANONICAL_HASH" && "$(sha256sum "$COMPAT" | awk '{print $1}')" == "$CANONICAL_HASH" ]] || fail 'migration changed source copies'
[[ "$(sha256sum /opt/3x-ui/netpilot-migration-sentinel | awk '{print $1}')" == "$SENTINEL_HASH" ]] || fail 'migration changed unrelated service data'
printf 'PASS: canonical updater rejects invalid payload, preserves current installation and aliases; unrelated data unchanged\n'
