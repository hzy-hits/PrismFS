#!/usr/bin/env bash
# The type gate, proven: a module that passes an UnverifiedCommit to publish
# must not compile. The build's own error is the test.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$AEGIS_ROOT"
PROOF="src/opaque_proof_tmp.gleam"
cleanup() { rm -f "$PROOF"; }
trap cleanup EXIT
cat > "$PROOF" <<'GLEAM'
// Temporary compile-fail probe: must NOT build.
import aegis/bridge
import aegis/domain/layer

pub fn ship_untested(bridge: bridge.Bridge, candidate: layer.UnverifiedCommit) {
  let _ = layer.publish(bridge, candidate, 1_000)
  Nil
}
GLEAM

set +e
OUTPUT=$("$GLEAM_BIN" build 2>&1)
STATUS=$?
set -e
rm -f "$PROOF"

if [ "$STATUS" -eq 0 ]; then
  echo "FAIL: publish accepted an UnverifiedCommit; the gate is open" >&2
  exit 1
fi
echo "$OUTPUT" | sed -n '1,14p'
if ! echo "$OUTPUT" | grep -q "VerifiedCommit"; then
  echo "FAIL: the build failed, but not on the VerifiedCommit type" >&2
  exit 1
fi
echo
echo "PASS: the compiler refused to publish unverified code."
