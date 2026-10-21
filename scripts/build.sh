#!/usr/bin/env bash
# Builds the standalone `aegisfleet` escript (the `fleet` binary).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$AEGIS_ROOT"
"$GLEAM_BIN" export escript
