#!/usr/bin/env bash
# Shared environment for running AegisFleet against the LayerFS simulator.
# Override LAYERFS_DIR to point at another checkout.
set -euo pipefail
AEGIS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_LAYERFS="$(cd "$AEGIS_ROOT/.." && pwd)/layerfs"
LAYERFS_DIR="${LAYERFS_DIR:-$DEFAULT_LAYERFS}"
EXPECTED_LAYERFS="$(tr -d '[:space:]' < "$AEGIS_ROOT/layerfs.revision")"
SIM="$LAYERFS_DIR/dsh/packages/host/src/sim"
if [ -z "${GLEAM_BIN:-}" ]; then
  GLEAM_BIN="$(command -v gleam || true)"
fi
if [ -z "${GLEAM_BIN:-}" ]; then
  echo "aegis: no gleam found; install Gleam >= 1.14 or set GLEAM_BIN" >&2
  exit 1
fi

if [ ! -f "$AEGIS_ROOT/priv/bridge_worker.mjs" ]; then
  echo "aegis: $AEGIS_ROOT/priv/bridge_worker.mjs is missing" >&2
  exit 1
fi
if [ ! -d "$LAYERFS_DIR/.git" ]; then
  echo "aegis: no LayerFS checkout at $LAYERFS_DIR; run scripts/bootstrap-layerfs.sh" >&2
  exit 1
fi
ACTUAL_LAYERFS="$(git -C "$LAYERFS_DIR" rev-parse HEAD 2>/dev/null || true)"
if [ "$ACTUAL_LAYERFS" != "$EXPECTED_LAYERFS" ]; then
  echo "aegis: incompatible LayerFS revision at $LAYERFS_DIR" >&2
  echo "aegis: expected $EXPECTED_LAYERFS, found ${ACTUAL_LAYERFS:-unknown}" >&2
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
if [ -n "${AEGIS_GLEAM_HOME:-}" ]; then
  export HOME="$AEGIS_GLEAM_HOME"
fi
