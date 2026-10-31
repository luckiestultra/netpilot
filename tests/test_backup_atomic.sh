#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh"
# Extracted application functions share the language formatter.
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
for fn in backup_file backup_file_once restore_file owned_config_target; do
  # shellcheck disable=SC1090
  source <(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT")
done
warn() { printf '%s\n' "$*" >&2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
BACKUP_DIR="$TMP/backup"
mkdir -m 0700 -- "$BACKUP_DIR"

# A real failed GNU cp must not publish a partial backup, even in conditional context.
head -c 16384 /dev/zero | tr '\0' A > "$TMP/config"
chmod 0640 -- "$TMP/config"
touch -t 202001020304 -- "$TMP/config"
cp -a -- "$TMP/config" "$TMP/original"
if (
  trap '' XFSZ
  ulimit -f 1
  backup_file_once "$TMP/config" config
); then fail 'file-size-limited copy unexpectedly succeeded'; fi
[[ ! -e "$BACKUP_DIR/config" && ! -L "$BACKUP_DIR/config" ]] || fail 'failed copy published a partial backup'
[[ -z "$(find "$BACKUP_DIR" -mindepth 1 -print -quit)" ]] || fail 'failed copy left temporary state'
backup_file_once "$TMP/config" config
printf 'changed\n' > "$TMP/config"
backup_file_once "$TMP/config" config
restore_file "$TMP/config" config
cmp -s -- "$TMP/original" "$TMP/config" || fail 'retry/restore lost original content'
[[ "$(stat -c '%a:%u:%g:%Y' "$TMP/original")" == "$(stat -c '%a:%u:%g:%Y' "$TMP/config")" ]] || fail 'retry/restore lost original metadata'

# Missing originals retain that fact on repeat; rollback removes the new file.
backup_file_once "$TMP/absent" absent
[[ -f "$BACKUP_DIR/absent.missing" ]] || fail 'missing original was not recorded'
printf 'created later\n' > "$TMP/absent"
backup_file_once "$TMP/absent" absent
restore_file "$TMP/absent" absent
[[ ! -e "$TMP/absent" ]] || fail 'missing original was not restored as absent'

# Both regular and dangling symlinks are backed up as links, not dereferenced.
for target in original nonexistent; do
  ln -s -- "$target" "$TMP/link-$target"
  backup_file_once "$TMP/link-$target" "link-$target"
  [[ -L "$BACKUP_DIR/link-$target" ]] || fail 'symlink backup was dereferenced'
  [[ "$(readlink "$BACKUP_DIR/link-$target")" == "$target" ]] || fail 'symlink target changed'
  rm -- "$TMP/link-$target"
  printf 'replacement\n' > "$TMP/link-$target"
  backup_file_once "$TMP/link-$target" "link-$target"
  restore_file "$TMP/link-$target" "link-$target"
  [[ -L "$TMP/link-$target" && "$(readlink "$TMP/link-$target")" == "$target" ]] || fail 'symlink retry/restore lost the original link'
done

# Publication failure is reported and cannot leave valid-looking metadata.
mv() { return 1; }
if backup_file_once "$TMP/original" unpublished; then fail 'failed publish returned success'; fi
if backup_file_once "$TMP/no-original" unpublished-missing; then fail 'failed missing-marker publish returned success'; fi
unset -f mv
[[ ! -e "$BACKUP_DIR/unpublished" && ! -e "$BACKUP_DIR/unpublished-missing.missing" ]] || fail 'failed publish left final metadata'
[[ -z "$(find "$BACKUP_DIR" -name '*.tmp.*' -print -quit)" ]] || fail 'failed publish left temporary state'
printf '%s\n' 'PASS: atomic backup failure/retry, metadata, missing originals, symlinks and publication errors'
