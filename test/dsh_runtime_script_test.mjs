import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repo = dirname(dirname(fileURLToPath(import.meta.url)));

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "prismfs-script-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, "bin");
  const dsh = join(root, "dsh");
  const tests = join(dsh, "packages/subagent/subagent-spawn-in-process/tests");
  mkdirSync(bin);
  mkdirSync(tests, { recursive: true });
  // Only runtime shell utilities are visible; Gleam cannot be found on PATH.
  for (const command of ["dirname", "mktemp", "rm", "cp", "tr"]) {
    const source = existsSync(`/bin/${command}`) ? `/bin/${command}` : `/usr/bin/${command}`;
    symlinkSync(source, join(bin, command));
  }
  const sdk = join(root, "sdk.js");
  writeFileSync(sdk, "");
  const binary = join(root, "prebuilt");
  writeFileSync(binary, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  writeFileSync(join(bin, "git"), `#!/bin/sh
if [ "$2" = "$DSH_DIR" ]; then
  echo 687f282e8625c6b8d11ff58211a90524be2e4317
elif [ -n "$TEST_LAYERFS_REVISION" ]; then
  echo "$TEST_LAYERFS_REVISION"
else
  echo 'unexpected LayerFS checkout access' >&2
  exit 1
fi
`, { mode: 0o755 });
  writeFileSync(join(bin, "pnpm"), `#!${process.execPath}
const fs = require('node:fs');
fs.writeFileSync(process.env.TEST_CAPTURE, JSON.stringify({ env: process.env, args: process.argv.slice(2) }));
process.exit(Number(process.env.TEST_EXIT || 0));
`, { mode: 0o755 });
  const capture = join(root, "capture.json");
  const env = { PATH: bin, DSH_DIR: dsh, PRISMFS_BINARY: binary, TEST_CAPTURE: capture };
  function run(overrides) {
    const result = spawnSync("/bin/bash", [join(repo, "scripts/test-dsh-runtime.sh")], {
      env: { ...env, ...overrides }, encoding: "utf8",
    });
    return { ...result, captured: existsSync(capture) ? JSON.parse(readFileSync(capture, "utf8")) : null };
  }
  return { root, sdk, binary, run };
}

test("explicit runtime inputs need neither Gleam nor a LayerFS checkout", (t) => {
  const f = fixture(t);
  const home = join(f.root, "owned-home");
  mkdirSync(home);
  const result = f.run({
    DSH_LAYERFS_SDK: f.sdk, DSH_LAYERFS_HOME: home, DSH_LAYERFS_PROJECT: "explicit-project",
    AEGIS_SDK: "/invalid-sdk", AEGIS_HOME: "/invalid-home", LAYERFS_DIR: "/missing-checkout",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.captured.env.PRISMFS_BINARY, f.binary);
  assert.equal(result.captured.env.DSH_LAYERFS_SDK, f.sdk);
  assert.equal(result.captured.env.DSH_LAYERFS_HOME, home);
  assert.equal(result.captured.env.DSH_LAYERFS_PROJECT, "explicit-project");
  assert.ok(existsSync(home));
  assert.ok(!existsSync(result.captured.args.at(-1)));
});

test("missing defaults use the pinned simulator and clean temporary resources on failure", (t) => {
  const f = fixture(t);
  const layerfs = join(f.root, "layerfs");
  const sdk = join(layerfs, "dsh/packages/host/src/sim/sdk.js");
  mkdirSync(dirname(sdk), { recursive: true });
  writeFileSync(sdk, "");
  const result = f.run({
    LAYERFS_DIR: layerfs, TEST_LAYERFS_REVISION: readFileSync(join(repo, "layerfs.revision"), "utf8").trim(),
    TEST_EXIT: "7",
  });
  assert.equal(result.status, 7, result.stderr);
  assert.equal(result.captured.env.DSH_LAYERFS_SDK, sdk);
  assert.match(result.captured.env.DSH_LAYERFS_PROJECT, /^dsh-runtime-\d+$/);
  assert.ok(!existsSync(result.captured.env.DSH_LAYERFS_HOME));
  assert.ok(!existsSync(result.captured.args.at(-1)));
});

test("default SDK still rejects an incompatible LayerFS checkout", (t) => {
  const f = fixture(t);
  const result = f.run({ LAYERFS_DIR: join(f.root, "layerfs"), TEST_LAYERFS_REVISION: "wrong-revision" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /LayerFS revision mismatch/);
  assert.equal(result.captured, null);
});
