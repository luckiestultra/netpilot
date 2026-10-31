#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="${SCRIPT_OVERRIDE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/netpilot.sh}"
TMP="$(mktemp -d)"
trap 'command rm -rf -- "$TMP"' EXIT
# shellcheck source=/dev/null
source <(sed -n '/^# BEGIN I18N$/,/^# END I18N$/p' "$SCRIPT")
for name in installed_script_owned install_script_atomic install_shortcuts install_local_copy check_update; do
  sed -n "/^${name}() {/,/^}/p" "$SCRIPT" >> "$TMP/functions.sh"
done
# shellcheck source=/dev/null
source "$TMP/functions.sh"
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
die() { warn "$*"; exit 1; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Only the download is replaced. Atomic publication, ownership, shortcuts and
# execution run unchanged against private temporary files, never system paths.
# shellcheck disable=SC2034
setup() {
  CASE_DIR="$TMP/$1"; mkdir -p "$CASE_DIR/bin"
  INSTALL_PATH="$CASE_DIR/bin/netpilot.sh"; SHORTCUT_PATH="$CASE_DIR/bin/netpilot"
  SCRIPT_PATH="$CASE_DIR/source.sh"; SOURCE_SNAPSHOT=''
  UPDATE_URL='https://github.com/luckiestultra/netpilot/raw/refs/heads/main/netpilot.sh'
  printf '#!/usr/bin/env bash\nreadonly UPDATE_URL="%s"\nuninstall_own_script() {\n  :\n}\n# original revision\n' "$UPDATE_URL" > "$INSTALL_PATH"
  cp "$INSTALL_PATH" "$CASE_DIR/original"
  ln -s "$INSTALL_PATH" "$SHORTCUT_PATH"
  curl() {
    while (($#)); do
      if [[ "$1" == --output ]]; then command cp "$SCRIPT_PATH" "$2"; return; fi
      shift
    done
    return 1
  }
}

assert_unchanged() {
  cmp -s "$CASE_DIR/original" "$INSTALL_PATH" || fail 'unrecognized payload replaced the working installation'
  [[ -L "$SHORTCUT_PATH" && "$(readlink "$SHORTCUT_PATH")" == "$INSTALL_PATH" ]] || fail 'unrecognized payload changed the shortcut'
  [[ ! -e "$CASE_DIR/payload-executed" ]] || fail 'unrecognized payload was executed'
}

test_plaintext_200_response_preserves_current_version() (
  setup plaintext
  # A successful HTTP response containing text can still be valid shell syntax.
  printf '# upstream temporarily unavailable\n' > "$SCRIPT_PATH"
  if (check_update) > "$CASE_DIR/output" 2>&1; then fail 'plain text was accepted as a NetPilot update'; fi
  assert_unchanged
)

test_other_project_script_is_not_installed_or_executed() (
  setup wrong-project
  printf '#!/usr/bin/env bash\nreadonly UPDATE_URL="https://example.invalid/another-project"\nuninstall_own_script() {\n  :\n}\nprintf executed > %q\n' "$CASE_DIR/payload-executed" > "$SCRIPT_PATH"
  if (check_update) > "$CASE_DIR/output" 2>&1; then fail 'another project was accepted as a NetPilot update'; fi
  assert_unchanged
)

test_unrecognized_local_source_preserves_current_version() (
  setup local-source
  printf '#!/usr/bin/env bash\nprintf executed > %q\n' "$CASE_DIR/payload-executed" > "$SCRIPT_PATH"
  if (install_local_copy) > "$CASE_DIR/output" 2>&1; then fail 'unrecognized local source was installed'; fi
  assert_unchanged
)

test_recognized_update_remains_installable() (
  setup recognized
  printf '#!/usr/bin/env bash\nreadonly UPDATE_URL="%s"\nuninstall_own_script() {\n  :\n}\nprintf executed > %q\n' "$UPDATE_URL" "$CASE_DIR/payload-executed" > "$SCRIPT_PATH"
  (check_update) > "$CASE_DIR/output" 2>&1 || fail 'recognized NetPilot update was rejected'
  cmp -s "$SCRIPT_PATH" "$INSTALL_PATH" || fail 'recognized update was not published completely'
  [[ -f "$CASE_DIR/payload-executed" && -L "$SHORTCUT_PATH" ]] || fail 'recognized update did not reload with its shortcut'
)

failures=0
for test in test_plaintext_200_response_preserves_current_version test_other_project_script_is_not_installed_or_executed test_unrecognized_local_source_preserves_current_version test_recognized_update_remains_installable; do
  if "$test"; then printf 'PASS: %s\n' "$test"; else failures=$((failures + 1)); fi
done
[[ "$failures" == 0 ]]
