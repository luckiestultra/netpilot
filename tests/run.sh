#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $(uname -s) == Linux && ${BASH_VERSINFO[0]} -ge 4 ]] || { echo 'Tests require Linux and Bash 4+.' >&2; exit 2; }
bash -n "$ROOT/vps-tcp-full-tune.sh"
for test in "$ROOT"/tests/test_*.sh; do bash "$test"; done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning "$ROOT/vps-tcp-full-tune.sh"
else
  printf '%s\n' 'ShellCheck is unavailable; install it to run the lint gate.' >&2
  exit 1
fi
