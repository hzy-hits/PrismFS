#!/usr/bin/env bash
# Shared environment for running AegisFleet against the LayerFS simulator.
# Override LAYERFS_DIR to point at another checkout.
set -euo pipefail
AEGIS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYERFS_DIR="${LAYERFS_DIR:-/Users/huangzhenyu/Projects/layerfs}"
SIM="$LAYERFS_DIR/dsh/packages/host/src/sim"
if [ -z "${GLEAM_BIN:-}" ]; then
  if [ -x "$AEGIS_ROOT/../.toolchain/gleam" ]; then
    GLEAM_BIN="$AEGIS_ROOT/../.toolchain/gleam"
  else
    GLEAM_BIN="$(command -v gleam || true)"
  fi
fi
if [ -z "${GLEAM_BIN:-}" ]; then
  echo "aegis: no gleam found; install Gleam >= 1.14 or set GLEAM_BIN" >&2
  exit 1
fi

if [ ! -f "$AEGIS_ROOT/priv/bridge_worker.mjs" ]; then
  echo "aegis: $AEGIS_ROOT/priv/bridge_worker.mjs is missing" >&2
  exit 1
fi
if [ ! -f "$SIM/sdk.js" ]; then
  echo "aegis: no LayerFS simulator at $SIM (set LAYERFS_DIR)" >&2
  exit 1
fi

export AEGIS_HOME="${AEGIS_HOME:-$(mktemp -d /tmp/aegis-home-XXXXXX)}"
export AEGIS_PROJECT="${AEGIS_PROJECT:-demo}"
export AEGIS_SIM=1
export AEGIS_SDK="$SIM/sdk.js"
export AEGIS_SIM_CLIENT="$SIM/client.js"
export AEGIS_OPERATOR="$SIM/operator.js"
export AEGIS_BRIDGE="$AEGIS_ROOT/priv/bridge_worker.mjs"
export AEGIS_TRACE_DIR="${AEGIS_TRACE_DIR:-$AEGIS_HOME/traces}"
export AEGIS_FIXTURE="${AEGIS_FIXTURE:-$AEGIS_ROOT/priv/fixture}"
export AEGIS_FIXTURE_MR="${AEGIS_FIXTURE_MR:-$AEGIS_ROOT/priv/fixture_mr}"
# This session's sandbox cannot write ~/Library/Caches, so a local hex cache
# is used when one was prepared; a normal machine keeps its own HOME.
if [ -d "$AEGIS_ROOT/../.home" ] || [ -n "${AEGIS_GLEAM_HOME:-}" ]; then
  export HOME="${AEGIS_GLEAM_HOME:-$AEGIS_ROOT/../.home}"
fi
