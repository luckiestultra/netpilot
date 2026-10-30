#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Old updaters install a single raw file, so this must remain a full script.
bash -n "$ROOT/netpilot.sh"
cp -- "$ROOT/netpilot.sh" "$ROOT/vps-tcp-full-tune.sh"
