// Shared helper for the verification scripts: a framed JSON client of the same
// bridge the BEAM starts, pointed at the LayerFS simulator.
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
export const LAYERFS = process.env.LAYERFS_DIR || "/Users/huangzhenyu/Projects/layerfs";
export const SIM = join(LAYERFS, "dsh/packages/host/src/sim");

export function bridgeEnv(home, project, extra = {}) {
  return {
    ...process.env,
    AEGIS_HOME: home,
    AEGIS_PROJECT: project,
    AEGIS_SIM: "1",
    AEGIS_SDK: join(SIM, "sdk.js"),
    AEGIS_OPERATOR: join(SIM, "operator.js"),
    AEGIS_SIM_CLIENT: join(SIM, "client.js"),
    AEGIS_TRACE_DIR: join(home, "traces"),
    AEGIS_BINDINGS: join(home, "bindings.json"),
    ...extra,
  };
}

export function startBridge(home, project, extra = {}) {
  const child = spawn(process.execPath, [join(ROOT, "priv/bridge_worker.mjs")], {
    env: bridgeEnv(home, project, extra),
    stdio: ["pipe", "pipe", "inherit"],
  });
  let buffer = Buffer.alloc(0);
  let seq = 0;
  const pending = new Map();
  child.stdout.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4) {
      const length = buffer.readUInt32BE(0);
      if (buffer.length < 4 + length) break;
      const message = JSON.parse(buffer.subarray(4, 4 + length).toString());
      buffer = buffer.subarray(4 + length);
      const waiter = pending.get(message.id);
      pending.delete(message.id);
      if (message.ok) waiter.resolve(message.result);
      else waiter.reject(Object.assign(new Error(message.error.message), message.error));
    }
  });
  const call = (op, args = {}) =>
    new Promise((resolve, reject) => {
      const id = ++seq;
      pending.set(id, { resolve, reject });
      const body = Buffer.from(JSON.stringify({ id, op, args }));
      const head = Buffer.alloc(4);
      head.writeUInt32BE(body.length, 0);
      child.stdin.write(Buffer.concat([head, body]));
    });
  const stop = async () => {
    await call("shutdown").catch(() => {});
    child.stdin.end();
    await new Promise((resolve) => child.on("exit", resolve));
  };
  return { child, call, stop, home };
}
