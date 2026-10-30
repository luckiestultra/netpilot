#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
for name in install_script_atomic install_shortcuts install_local_copy check_update; do
  sed -n "/^${name}() {/,/^}/p" "$SCRIPT" >> "$TEST_DIR/functions.sh"
done
source "$TEST_DIR/functions.sh"
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
die() { warn "$*"; exit 1; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

test_update_write_failure_keeps_old_version() (
  INSTALL_PATH="$TEST_DIR/failed-update"; printf '#!/bin/bash\nprintf old\n' > "$INSTALL_PATH"
  UPDATE_URL=https://example.invalid/script
  curl() {
    while (($#)); do
      if [[ "$1" == --output ]]; then printf '#!/bin/bash\nprintf new\n' > "$2"; return; fi
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

test_install_write_failure_never_executes() (
  INSTALL_PATH="$TEST_DIR/failed-install"; SCRIPT_PATH="$TEST_DIR/install-source"
  SOURCE_SNAPSHOT=''; NETPILOT_SHORTCUT_PATH="$TEST_DIR/netpilot"; SHORTCUT_PATH="$TEST_DIR/shortcut"; LEGACY_SHORTCUT_PATH="$TEST_DIR/legacy"
  printf '#!/bin/bash\nprintf new\n' > "$SCRIPT_PATH"
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
for test in test_update_write_failure_keeps_old_version test_install_write_failure_never_executes test_invalid_script_keeps_old_version test_symlink_target_is_not_followed test_atomic_install_works; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
