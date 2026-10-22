#!/usr/bin/env bash
# Fetch the pinned LayerFS simulator and install its JavaScript workspace.
set -euo pipefail

AEGIS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION="$(tr -d '[:space:]' < "$AEGIS_ROOT/layerfs.revision")"
LAYERFS_DIR="${LAYERFS_DIR:-$(cd "$AEGIS_ROOT/.." && pwd)/layerfs}"
REMOTE="${LAYERFS_REMOTE:-https://github.com/Ephemeral-AI-Lab/layerfs.git}"

if [ ! -e "$LAYERFS_DIR/.git" ]; then
  if [ -e "$LAYERFS_DIR" ]; then
    echo "aegis: $LAYERFS_DIR exists but is not a LayerFS git checkout" >&2
    exit 1
  fi
  git clone --filter=blob:none --no-checkout "$REMOTE" "$LAYERFS_DIR"
  git -C "$LAYERFS_DIR" fetch --depth=1 origin "$REVISION"
  git -C "$LAYERFS_DIR" checkout --detach "$REVISION"
fi

ACTUAL="$(git -C "$LAYERFS_DIR" rev-parse HEAD)"
if [ "$ACTUAL" != "$REVISION" ]; then
  echo "aegis: incompatible LayerFS revision at $LAYERFS_DIR" >&2
  echo "aegis: expected $REVISION, found $ACTUAL" >&2
  echo "aegis: use a separate checkout or explicitly detach it at the pinned revision" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "aegis: Node.js >=22.19 is required" >&2
  exit 1
fi
if ! node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 19)) process.exit(1)'; then
  echo "aegis: Node.js >=22.19 is required (found $(node --version))" >&2
  exit 1
fi

(
  cd "$LAYERFS_DIR/dsh"
  if [ -n "${PNPM_BIN:-}" ]; then
    "$PNPM_BIN" install --frozen-lockfile
  elif command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile
  else
    corepack pnpm install --frozen-lockfile
  fi
)

echo "aegis: LayerFS simulator ready at $LAYERFS_DIR ($REVISION)"
