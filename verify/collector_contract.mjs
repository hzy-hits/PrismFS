// Proves the second half of the "zero UI change" claim: trace lines written by
// the fleet bridge are read by DSH's own Collector, attributed to a named
// agent, and exposed in the shape the Work view draws.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { ROOT, startBridge } from "./lib.mjs";

const HOST = "/Users/huangzhenyu/Projects/layerfs/dsh/packages/host/src";
const home = mkdtempSync(join(tmpdir(), "aegis-collector-"));
const project = "contract";
const traceDir = join(home, "traces");
const stateDir = join(home, "state");
mkdirSync(stateDir, { recursive: true });

const bridge = startBridge(home, project);
try {
  await bridge.call("init", { source: join(ROOT, "priv/fixture") });
  await bridge.call("fork", { name: "racer-branch", trace: "fleet" });
  const mounted = await bridge.call("mount", { branch: "racer-branch", trace: "racer-1" });
  const exec = await bridge.call("exec", {
    path: mounted.path,
    command: "printf '42\\n' > src/value.txt",
    trace: "racer-1",
  });
  assert.equal(exec.exitCode, 0);
  const commit = await bridge.call("commit", {
    path: mounted.path,
    message: "racer-1: fix the value",
    trace: "racer-1",
  });
  assert.equal(commit.kind, "Committed");
  await bridge.call("unmount", { path: mounted.path });
} finally {
  await bridge.stop();
}

const { Collector } = await import(fileURLToPath(new URL("collector.js", `file://${HOST}/`)));
const { BindingStore } = await import(fileURLToPath(new URL("binding.js", `file://${HOST}/`)));

const bindings = new BindingStore(stateDir);
bindings.setAgent("racer-1", "root-1", "racer-1");
bindings.setAgent("fleet", "root-1", "fleet");
const collector = new Collector(
  { sessions: new Map(), logger: { warn: (m) => console.error(m) } },
  { traceDir, stateDir, pollMs: 50 },
  bindings,
);
collector.track({ id: "racer-1", root: "root-1", name: "racer-1" }, { name: project });
collector.track({ id: "fleet", root: "root-1", name: "fleet" }, { name: project });
collector.poll();
const snapshot = collector.snapshot("root-1");

const methods = snapshot.lines.map((line) => line.method);
for (const expected of ["branch.fork", "sandbox.mount", "sandbox.exec", "sandbox.commit", "sandbox.unmount"]) {
  assert.ok(methods.includes(expected), `collector saw no ${expected}: ${methods.join(", ")}`);
}
assert.ok(snapshot.lines.every((line) => ["racer-1", "fleet"].includes(line.agent)));
assert.ok(snapshot.lines.some((line) => line.agent === "racer-1" && line.method === "sandbox.exec"));
const execLine = snapshot.lines.find((line) => line.method === "sandbox.exec");
assert.equal(execLine.ok, true);
assert.equal(execLine.exitCode, 0);
assert.ok(execLine.ms > 0);
const commitLine = snapshot.lines.find((line) => line.method === "sandbox.commit");
assert.equal(commitLine.kind, "Committed");
assert.ok(commitLine.commit, "the commit id the History view links is missing");
assert.equal(snapshot.agents["racer-1"], "racer-1");
assert.equal(snapshot.agents["fleet"], "fleet");

console.log(`collector accepted ${snapshot.lines.length} fleet trace lines under root session root-1`);
console.log(`ops: ${[...new Set(methods)].join(", ")}`);
console.log(`commit ${commitLine.commit.slice(0, 12)} · exit ${execLine.exitCode} · ${execLine.ms.toFixed(1)}ms`);
