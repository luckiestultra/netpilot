#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
# Extracted application functions share the language formatter.
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
for name in install_script_atomic install_shortcuts install_local_copy installed_script_owned check_update; do
  sed -n "/^${name}() {/,/^}/p" "$SCRIPT" >> "$TEST_DIR/functions.sh"
done
source "$TEST_DIR/functions.sh"
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
die() { warn "$*"; exit 1; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

test_update_write_failure_keeps_old_version() (
  INSTALL_PATH="$TEST_DIR/failed-update"
  UPDATE_URL=https://example.invalid/script
  printf '#!/bin/bash\nreadonly UPDATE_URL="%s"\nuninstall_own_script() {\n  :\n}\nprintf old\n' "$UPDATE_URL" > "$INSTALL_PATH"
  curl() {
    while (($#)); do
      if [[ "$1" == --output ]]; then printf '#!/bin/bash\nreadonly UPDATE_URL="%s"\nuninstall_own_script() {\n  :\n}\nprintf new\n' "$UPDATE_URL" > "$2"; return; fi
      shift
    done
    return 1
  }
  install() { return 1; }
  exec() { printf 'exec\n' >> "$TEST_DIR/failed-exec"; }
  if check_update; then fail 'update with failed write returned success'; fi
  grep -q 'printf old' "$INSTALL_PATH" || fail 'failed update damaged current script'
  [[ ! -e "$TEST_DIR/failed-exec" ]] || fail 'failed update executed a script'
)

test_unrecognized_download_keeps_old_version() (
  INSTALL_PATH="$TEST_DIR/unrecognized-update"; SHORTCUT_PATH="$TEST_DIR/unrecognized-shortcut"
  UPDATE_URL='https://github.com/luckiestultra/netpilot/raw/refs/heads/main/netpilot.sh'
  printf '#!/bin/bash\nreadonly UPDATE_URL="%s"\nuninstall_own_script() {\n  :\n}\nprintf old\n' "$UPDATE_URL" > "$INSTALL_PATH"
  cp "$INSTALL_PATH" "$TEST_DIR/unrecognized-before"
  printf '#!/bin/bash\nprintf foreign\n' > "$TEST_DIR/unrecognized-payload"
  bash -n "$TEST_DIR/unrecognized-payload" || fail 'foreign download fixture has invalid syntax'
  curl() {
    while (($#)); do
      if [[ "$1" == --output ]]; then
        cp "$TEST_DIR/unrecognized-payload" "$2" || return 1
        : > "$TEST_DIR/unrecognized-downloaded"
        return 0
      fi
      shift
    done
    return 1
  }
  exec() { printf 'exec\n' >> "$TEST_DIR/unrecognized-exec"; }
  if check_update; then fail 'unrecognized downloaded script was accepted'; fi
  [[ -e "$TEST_DIR/unrecognized-downloaded" ]] || fail 'update did not successfully download the foreign payload'
  cmp -s "$TEST_DIR/unrecognized-before" "$INSTALL_PATH" || fail 'unrecognized download replaced the current script'
  [[ ! -e "$TEST_DIR/unrecognized-exec" ]] || fail 'unrecognized download reached execution'
)

test_install_write_failure_never_executes() (
  INSTALL_PATH="$TEST_DIR/failed-install"; SCRIPT_PATH="$TEST_DIR/install-source"
  SOURCE_SNAPSHOT=''; SHORTCUT_PATH="$TEST_DIR/shortcut"
  UPDATE_URL='https://github.com/luckiestultra/netpilot/raw/refs/heads/main/netpilot.sh'
  printf '#!/bin/bash\nreadonly UPDATE_URL="%s"\nuninstall_own_script() {\n  :\n}\nprintf new\n' "$UPDATE_URL" > "$SCRIPT_PATH"
  install() { return 1; }
  exec() { printf 'exec\n' >> "$TEST_DIR/install-exec"; }
  if install_local_copy; then fail 'installation write failure returned success'; fi
  [[ ! -e "$INSTALL_PATH" && ! -e "$SHORTCUT_PATH" && ! -e "$TEST_DIR/install-exec" ]] || fail 'failed install continued to shortcuts/execution'
)

test_invalid_script_keeps_old_version() (
  INSTALL_PATH="$TEST_DIR/invalid-target"; printf '#!/bin/bash\nprintf old\n' > "$INSTALL_PATH"
  printf 'if then broken\n' > "$TEST_DIR/invalid-source"
  if install_script_atomic "$TEST_DIR/invalid-source" "$INSTALL_PATH"; then fail 'invalid shell script was installed'; fi
  grep -q 'printf old' "$INSTALL_PATH" || fail 'syntax failure damaged current script'
)

test_symlink_target_is_not_followed() (
  printf '#!/bin/bash\nprintf keep\n' > "$TEST_DIR/symlink-victim"
  ln -s "$TEST_DIR/symlink-victim" "$TEST_DIR/symlink-target"
  printf '#!/bin/bash\nprintf new\n' > "$TEST_DIR/symlink-source"
  if install_script_atomic "$TEST_DIR/symlink-source" "$TEST_DIR/symlink-target"; then fail 'symbolic-link destination was accepted'; fi
  grep -q 'printf keep' "$TEST_DIR/symlink-victim" || fail 'installer followed symlink'
)

test_atomic_install_works() (
  printf '#!/bin/bash\nprintf old\n' > "$TEST_DIR/good-target"
  printf '#!/bin/bash\nprintf new\n' > "$TEST_DIR/good-source"
  install_script_atomic "$TEST_DIR/good-source" "$TEST_DIR/good-target"
  cmp -s "$TEST_DIR/good-source" "$TEST_DIR/good-target" || fail 'successful install did not publish complete script'
  [[ -x "$TEST_DIR/good-target" ]] || fail 'installed script is not executable'
)

failures=0
for test in test_update_write_failure_keeps_old_version test_unrecognized_download_keeps_old_version test_install_write_failure_never_executes test_invalid_script_keeps_old_version test_symlink_target_is_not_followed test_atomic_install_works; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
