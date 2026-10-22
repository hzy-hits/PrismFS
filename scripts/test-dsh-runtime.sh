#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dsh_dir="${DSH_DIR:?set DSH_DIR to the pinned deepseek-harness checkout}"
expected_revision="687f282e8625c6b8d11ff58211a90524be2e4317"
actual_revision="$(git -C "$dsh_dir" rev-parse HEAD)"
[[ "$actual_revision" == "$expected_revision" ]] || {
  echo "DSH revision mismatch: expected $expected_revision, got $actual_revision" >&2
  exit 1
}

created_aegis_home=""
if [[ -z "${AEGIS_HOME:-}" ]]; then
  AEGIS_HOME="$(mktemp -d /tmp/prismfs-dsh-runtime-XXXXXX)"
  created_aegis_home="$AEGIS_HOME"
  export AEGIS_HOME
fi
runtime_test="$dsh_dir/packages/subagent/subagent-spawn-in-process/tests/prismfs-runtime-$$.spec.ts"
cleanup() {
  rm -f "$runtime_test"
  if [[ -n "$created_aegis_home" ]]; then
    rm -rf "$created_aegis_home"
  fi
}
trap cleanup EXIT
source "$repo_root/scripts/env.sh"
binary="${PRISMFS_BINARY:-$repo_root/aegisfleet}"
[[ -x "$binary" ]] || { echo "missing PrismFS binary: $binary" >&2; exit 1; }
cp "$repo_root/test/dsh_runtime_test.ts" "$runtime_test"
export PRISMFS_ROOT="$repo_root"
export PRISMFS_BINARY="$binary"
export DSH_LAYERFS_HOME="${DSH_LAYERFS_HOME:-$AEGIS_HOME}"
export DSH_LAYERFS_PROJECT="${DSH_LAYERFS_PROJECT:-dsh-runtime-$$}"
export DSH_LAYERFS_SDK="${DSH_LAYERFS_SDK:-$AEGIS_SDK}"
export DSH_DIR="$dsh_dir"

cd "$dsh_dir"
pnpm exec vitest run --config vitest.config.ts "$runtime_test"
