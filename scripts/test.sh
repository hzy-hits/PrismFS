#!/usr/bin/env bash
# Runs the kernel tests against the real LayerFS simulator in a fresh home.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$AEGIS_ROOT"
echo "aegis test: home=$AEGIS_HOME"
"$GLEAM_BIN" test
