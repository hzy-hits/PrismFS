// Drives priv/bridge_worker.mjs over the same 4-byte framed JSON the BEAM uses.
import { spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const home = mkdtempSync(join(tmpdir(), "aegis-probe-"));
const env = {
  ...process.env,
  AEGIS_HOME: home,
  AEGIS_PROJECT: "probe",
  AEGIS_SDK: "/Users/huangzhenyu/Projects/layerfs/dsh/packages/host/src/sim/sdk.js",
  AEGIS_OPERATOR: "/Users/huangzhenyu/Projects/layerfs/dsh/packages/host/src/sim/operator.js",
  AEGIS_SIM_CLIENT: "/Users/huangzhenyu/Projects/layerfs/dsh/packages/host/src/sim/client.js",
  AEGIS_TRACE_DIR: join(home, "traces"),
  AEGIS_SIM: "1",
  AEGIS_TRACE_START: "1",
};
const child = spawn(process.execPath, [join(ROOT, "priv/bridge_worker.mjs")], { env, stdio: ["pipe", "pipe", "pipe"] });
child.stderr.on("data", (d) => process.stderr.write(`[bridge] ${d}`));
let buf = Buffer.alloc(0), seq = 0;
const pending = new Map();
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

try {
  console.log("hello:", await call("hello"));
  console.log("init:", await call("init", { source: join(ROOT, "priv/fixture") }));
  console.log("fork:", await call("fork", { name: "race-a" }));
  const m = await call("mount", { branch: "race-a", trace: "racer-1" });
  console.log("mount:", m);
  const e = await call("exec", { path: m.path, command: "printf '42\\n' > src/value.txt && node check.js", trace: "racer-1" });
  console.log("exec:", { exitCode: e.exitCode, stdout: e.stdout.trim() });
  const c = await call("commit", { path: m.path, message: "fix: value 42", trace: "racer-1" });
  console.log("commit:", c);
  console.log("unmount:", await call("unmount", { path: m.path }));
  console.log("publish:", await call("publish", { branch: "race-a" }));
  console.log("read:", (await call("read", { branch: "main", path: "/src/value.txt" })).text.trim());
  console.log("snapshot:", await call("snapshot"));
} finally {
  await call("shutdown").catch(() => {});
  child.stdin.end();
}
