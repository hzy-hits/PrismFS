// Proves the janitor: a hard-killed bridge leaves a Workspace mounted; a new
// bridge reaps it. Also prints the SDK trace lines DSH's Work view consumes.
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const home = mkdtempSync(join(tmpdir(), "aegis-reap-"));
const SIM = "/Users/huangzhenyu/Projects/layerfs/dsh/packages/host/src/sim";

function start() {
  const env = {
    ...process.env,
    AEGIS_HOME: home, AEGIS_PROJECT: "reap", AEGIS_SIM: "1",
    AEGIS_SDK: `${SIM}/sdk.js`, AEGIS_OPERATOR: `${SIM}/operator.js`, AEGIS_SIM_CLIENT: `${SIM}/client.js`,
    AEGIS_TRACE_DIR: join(home, "traces"), AEGIS_BINDINGS: join(home, "bindings.json"),
  };
  const child = spawn(process.execPath, [join(ROOT, "priv/bridge_worker.mjs")], { env, stdio: ["pipe", "pipe", "inherit"] });
  let buf = Buffer.alloc(0), seq = 0; const pending = new Map();
  child.stdout.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 4) {
      const n = buf.readUInt32BE(0);
      if (buf.length < 4 + n) break;
      const msg = JSON.parse(buf.subarray(4, 4 + n).toString());
      buf = buf.subarray(4 + n);
      const p = pending.get(msg.id); pending.delete(msg.id);
      msg.ok ? p.resolve(msg.result) : p.reject(Object.assign(new Error(msg.error.message), msg.error));
    }
  });
  const call = (op, args = {}) => new Promise((resolve, reject) => {
    const id = ++seq; pending.set(id, { resolve, reject });
    const body = Buffer.from(JSON.stringify({ id, op, args }));
    const head = Buffer.alloc(4); head.writeUInt32BE(body.length, 0);
    child.stdin.write(Buffer.concat([head, body]));
  });
  return { child, call };
}

let b = start();
await b.call("init", { source: join(ROOT, "priv/fixture") });
await b.call("fork", { name: "leaky" });
const m = await b.call("mount", { branch: "leaky", trace: "worker-1" });
await b.call("bind", { agentId: "agent-1", root: "root-1", name: "racer-1" });
console.log("mounted", m.path);
console.log("snapshot before kill:", (await b.call("snapshot")).workspaces);
b.child.kill("SIGKILL");            // the kernel dies: no cleanup runs
await new Promise((r) => setTimeout(r, 300));

b = start();
console.log("snapshot after kill:", (await b.call("snapshot")).workspaces);
console.log("reap:", await b.call("reap", {}));
console.log("snapshot after reap:", (await b.call("snapshot")).workspaces);
await b.call("shutdown"); b.child.stdin.end();

const trace = readFileSync(join(home, "traces/worker-1.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
console.log("trace lines:", trace.length, "ops:", [...new Set(trace.map((l) => l.method ?? l.op))].join(", "));
console.log("trace sample:", JSON.stringify(trace.find((l) => (l.method ?? l.op) === "sandbox.mount")));
console.log("bindings:", readFileSync(join(home, "bindings.json"), "utf8").replace(/\s+/g, " "));
