import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync, rmSync, watch } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import test from "node:test";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const worker = join(root, "priv", "bridge_worker.mjs");
const fixture = join(root, "test", "fixtures", "controlled_sdk.mjs");

function start(extra = {}) {
  const control = mkdtempSync(join(tmpdir(), "prismfs-bridge-"));
  const child = spawn(process.execPath, [worker], {
    env: {
      ...process.env,
      AEGIS_HOME: control,
      AEGIS_PROJECT: "controlled",
      AEGIS_SDK: fixture,
      CONTROL_DIR: control,
      ...extra,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let buffer = Buffer.alloc(0);
  const replies = new Map();
  child.stdout.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4) {
      const size = buffer.readUInt32BE(0);
      if (buffer.length < size + 4) break;
      const reply = JSON.parse(buffer.subarray(4, size + 4).toString("utf8"));
      buffer = buffer.subarray(size + 4);
      replies.get(reply.id)?.(reply);
      replies.delete(reply.id);
    }
  });
  let nextId = 1;
  const call = (op, args = {}) => new Promise((resolve, reject) => {
    const id = nextId++;
    replies.set(id, resolve);
    const json = Buffer.from(JSON.stringify({ id, op, args }));
    const header = Buffer.alloc(4);
    header.writeUInt32BE(json.length);
    child.stdin.write(Buffer.concat([header, json]), (error) => {
      if (error) reject(error);
    });
  });
  const cleanup = () => {
    if (child.exitCode === null) child.kill("SIGKILL");
    rmSync(control, { recursive: true, force: true });
  };
  return { child, control, call, cleanup };
}

function events(control) {
  try {
    return readFileSync(join(control, "events.jsonl"), "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(JSON.parse);
  } catch {
    return [];
  }
}

function waitForEvent(control, name, count = 1, timeout = 5000) {
  if (events(control).filter((event) => event.event === name).length >= count) {
    return Promise.resolve();
  }
  return new Promise((resolve, reject) => {
    const watcher = watch(control, () => {
      if (events(control).filter((event) => event.event === name).length >= count) {
        watcher.close();
        clearTimeout(timer);
        resolve();
      }
    });
    const timer = setTimeout(() => {
      watcher.close();
      reject(new Error(`timed out waiting for ${name}`));
    }, timeout);
  });
}

function waitForExit(child) {
  if (child.exitCode !== null) return Promise.resolve(child.exitCode);
  return new Promise((resolve) => child.once("exit", resolve));
}

function within(promise, label, timeout = 5000) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), timeout);
    }),
  ]).finally(() => clearTimeout(timer));
}

test("failed unmount remains owned and shutdown retries it", async (t) => {
  const bridge = start();
  t.after(bridge.cleanup);
  writeFileSync(join(bridge.control, "unmount-failures"), "1");
  assert.equal((await bridge.call("mount", { branch: "main" })).ok, true);
  const failed = await bridge.call("unmount", {
    path: "/controlled/workspace",
    discard: true,
  });
  assert.equal(failed.ok, false);
  assert.equal((await bridge.call("shutdown")).ok, true);
  assert.equal(await within(waitForExit(bridge.child), "bridge exit"), 0);
  assert.equal(
    events(bridge.control).filter((event) => event.event === "unmount").length,
    2,
  );
});

test("bridge retains a successful mount until explicit cleanup", async (t) => {
  const bridge = start({ BLOCK_MOUNT: "1" });
  t.after(bridge.cleanup);
  const mounting = bridge.call("mount", { branch: "main" });
  await waitForEvent(bridge.control, "mount-start");
  writeFileSync(join(bridge.control, "allow-mount"), "");
  const mounted = await mounting;
  assert.equal(mounted.ok, true);
  assert.equal((await bridge.call("unmount", {
    path: mounted.result.path,
    discard: true,
  })).ok, true);
  assert.equal((await bridge.call("shutdown")).ok, true);
  assert.equal(await within(waitForExit(bridge.child), "bridge exit"), 0);
});

test("overlapping shutdowns share one cleanup pass", async (t) => {
  const bridge = start({ BLOCK_UNMOUNT: "1" });
  t.after(bridge.cleanup);
  assert.equal((await bridge.call("mount", { branch: "main" })).ok, true);

  const first = bridge.call("shutdown");
  await waitForEvent(bridge.control, "unmount");
  const second = bridge.call("shutdown");
  assert.equal((await within(bridge.call("hello"), "closing response")).ok, false);
  assert.equal(events(bridge.control).filter((event) => event.event === "unmount").length, 1);

  writeFileSync(join(bridge.control, "allow-unmount"), "");
  const replies = await within(Promise.all([first, second]), "shutdown replies");
  assert.equal(replies[0].ok, true);
  assert.equal(replies[1].ok, true);
  assert.equal(await within(waitForExit(bridge.child), "bridge exit"), 0);
  assert.equal(events(bridge.control).filter((event) => event.event === "unmount").length, 1);
  assert.equal(events(bridge.control).filter((event) => event.event === "close").length, 1);
});

test("EOF waits for an accepted mount then releases it", async (t) => {
  const bridge = start({ BLOCK_MOUNT: "1" });
  t.after(bridge.cleanup);
  void bridge.call("mount", { branch: "main" });
  await waitForEvent(bridge.control, "mount-start");
  bridge.child.stdin.end();
  assert.equal(bridge.child.exitCode, null);
  writeFileSync(join(bridge.control, "allow-mount"), "");
  assert.equal(await within(waitForExit(bridge.child), "bridge exit"), 0);
  assert.equal(events(bridge.control).some((event) => event.event === "mount-success"), true);
  assert.equal(events(bridge.control).some((event) => event.event === "unmount"), true);
});

test("shutdown reports failed cleanup and stays alive for retry", async (t) => {
  const bridge = start();
  t.after(bridge.cleanup);
  writeFileSync(join(bridge.control, "fail-unmount"), "");
  assert.equal((await bridge.call("mount", { branch: "main" })).ok, true);
  const failed = await bridge.call("shutdown");
  assert.equal(failed.ok, false);
  assert.equal(failed.error.code, "CleanupFailed");
  assert.equal(bridge.child.exitCode, null);
  rmSync(join(bridge.control, "fail-unmount"));
  assert.equal((await bridge.call("shutdown")).ok, true);
  assert.equal(await within(waitForExit(bridge.child), "bridge exit"), 0);
});
