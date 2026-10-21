#!/usr/bin/env bash
# End-to-end proof: three Branches race on a fresh simulated project, the
# verified one publishes, the other two are killed and reclaimed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$AEGIS_ROOT"
"$GLEAM_BIN" run -- demo "$AEGIS_FIXTURE"
