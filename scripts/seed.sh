#!/usr/bin/env bash
# Creates a throwaway LayerFS project for UAT and prints the exports to use.
#   eval "$(./scripts/seed.sh priv/fixture_portfolio uat-pf)"
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

FIXTURE="${1:?usage: seed.sh <fixture-folder> [project-name]}"
PROJECT="${2:-uat-${RANDOM}}"
case "$FIXTURE" in
  /*) SOURCE="$FIXTURE" ;;
  *) SOURCE="$AEGIS_ROOT/$FIXTURE" ;;
esac
if [ ! -d "$SOURCE" ]; then
  echo "aegis: fixture $SOURCE does not exist" >&2
  exit 1
fi

HOME_DIR="$(mktemp -d /tmp/aegis-uat-XXXXXX)"
export AEGIS_HOME="$HOME_DIR"
export AEGIS_PROJECT="$PROJECT"
export AEGIS_TRACE_DIR="$HOME_DIR/traces"
export AEGIS_SEED_SOURCE="$SOURCE"

cd "$AEGIS_ROOT"
node --input-type=module -e '
import { startBridge } from "./verify/lib.mjs";
const b = startBridge(process.env.AEGIS_HOME, process.env.AEGIS_PROJECT);
try {
  await b.call("init", { source: process.env.AEGIS_SEED_SOURCE });
} finally {
  await b.stop();
}
' >/dev/null 2>&1

cat <<EOF
export AEGIS_HOME="$AEGIS_HOME"
export AEGIS_PROJECT="$AEGIS_PROJECT"
export AEGIS_TRACE_DIR="$AEGIS_TRACE_DIR"
export AEGIS_SIM="$AEGIS_SIM"
export AEGIS_SDK="$AEGIS_SDK"
export AEGIS_SIM_CLIENT="$AEGIS_SIM_CLIENT"
export AEGIS_OPERATOR="$AEGIS_OPERATOR"
export AEGIS_BRIDGE="$AEGIS_BRIDGE"
EOF
