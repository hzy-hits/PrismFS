import assert from "node:assert/strict";
import test from "node:test";
import { apply, createRunner, sessionBranch } from "../integration/dsh-plugin.mjs";

const env = { DSH_LAYERFS_PROJECT: "project", DSH_LAYERFS_SDK: "/sdk.js", DSH_LAYERFS_HOME: "/home/layerfs" };
const config = { binary: "/prismfs/aegisfleet" };
const execution = (id, signal = new AbortController().signal) => ({ agent: { session: { header: { id } } }, signal });
const answer = (branch) => ({ branch, commit: "immutable-1", exitCode: 0, published: false });

test("multi-turn sessions keep distinct branches and never replace the DSH provider", async () => {
  const calls = [];
  const runner = createRunner(config, async (_binary, args, env) => {
    calls.push({ args, env });
    return answer(args[1]);
  });
  for (const id of ["child-a", "child-b", "child-a", "child-b"]) {
    await runner.execute({ command: "echo hello" }, execution(id), env);
  }
  assert.equal(calls[0].args[1], calls[2].args[1]);
  assert.equal(calls[1].args[1], calls[3].args[1]);
  assert.notEqual(calls[0].args[1], calls[1].args[1]);
  assert.deepEqual(calls[0].args, ["step", sessionBranch("child-a"), "main", "echo hello"]);
  assert.equal(calls[0].env.DSH_LAYERFS_PROJECT, "project");
  assert.equal(calls[0].env.AEGIS_EXEC_TIMEOUT, "120000");
  await runner.close();
});

test("Stop and disposal wait for the owned step; cancellation does not start another call", async () => {
  const abort = new AbortController();
  let finish, started;
  const ready = new Promise((resolve) => { started = resolve; });
  let calls = 0;
  const runner = createRunner(config, async (_binary, args) => {
    calls++;
    started();
    await new Promise((resolve) => { finish = resolve; });
    return answer(args[1]);
  });
  const first = runner.execute({ command: "work" }, execution("child", abort.signal), env);
  const rejected = assert.rejects(first, /Cancelled after step settlement.*cleanup confirmed/);
  await ready;
  abort.abort();
  const second = runner.execute({ command: "never" }, execution("child", abort.signal), env);
  const secondRejected = assert.rejects(second);
  let closed = false;
  const closing = runner.close().then(() => { closed = true; });
  await new Promise(setImmediate);
  assert.equal(closed, false);
  assert.equal(calls, 1);
  finish();
  await Promise.all([rejected, secondRejected, closing]);
  assert.equal(calls, 1);
  await assert.rejects(runner.execute({ command: "never" }, execution("child"), env), /closing/);
});

test("invalid context and unsupported execution modes fail closed", async () => {
  const runner = createRunner(config, async () => { assert.fail("must not execute"); });
  await assert.rejects(runner.execute({ command: "x" }, execution("child"), {}), /Choose a LayerFS/);
  await assert.rejects(runner.execute({ command: "x", run_in_background: true }, execution("child"), env), /unsupported/);
  await assert.rejects(runner.execute({ command: "x", workdir: "/host" }, execution("child"), env), /unsupported/);
  await assert.rejects(runner.execute({ command: "x", timeout_ms: -1 }, execution("child"), env), /timeout_ms/);
  await runner.close();
});

test("plugin registers only a tool and an awaited cleanup effect", async () => {
  let tool, cleanup;
  const ctx = {
    tools: { register(value) { tool = value; } },
    shellEnv: { collect: () => env },
    effect(factory) { cleanup = factory(); },
  };
  apply(ctx, config);
  assert.equal(tool.name, "bash");
  assert.equal(tool.parameters.additionalProperties, false);
  assert.match(tool.description, /never publishes/);
  assert.equal(tool.output.render({}, { stdout: "x".repeat(20000) })[0].text.includes('"truncated":true'), true);
  await cleanup();
});

test("serializes one session while sibling sessions run concurrently", async () => {
  const active = new Set();
  let peak = 0;
  const started = [];
  const release = [];
  const startWaiters = [];
  const waitForStarts = (count) => {
    if (started.length >= count) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`only ${started.length} calls started`)), 1000);
      startWaiters.push({ count, resolve: () => { clearTimeout(timer); resolve(); } });
    });
  };
  const runner = createRunner(config, async (_binary, args, managed) => {
    active.add(args[1]);
    peak = Math.max(peak, active.size);
    started.push(args[1]);
    for (const waiter of startWaiters.splice(0)) {
      if (started.length >= waiter.count) waiter.resolve();
      else startWaiters.push(waiter);
    }
    await new Promise((resolve) => release.push(resolve));
    active.delete(args[1]);
    return answer(args[1]);
  });
  const a1 = runner.execute({ command: "a1" }, execution("same"), env);
  await waitForStarts(1);
  const a2 = runner.execute({ command: "a2" }, execution("same"), env);
  const b1 = runner.execute({ command: "b1" }, execution("sibling"), env);
  await waitForStarts(2);
  assert.equal(started[0], sessionBranch("same"));
  assert.equal(started[1], sessionBranch("sibling"));
  assert.equal(peak, 2);
  release[0]();
  await waitForStarts(3);
  release[1]();
  release[2]();
  await Promise.all([a1, a2, b1]);
  await runner.close();

  const oldProject = process.env.AEGIS_PROJECT;
  const oldSdk = process.env.AEGIS_SDK;
  const seen = [];
  try {
    process.env.AEGIS_PROJECT = "ambient-project";
    process.env.AEGIS_SDK = "ambient-sdk";
    const isolated = createRunner(config, async (_binary, args, managed) => {
      seen.push(managed);
      return answer(args[1]);
    });
    await isolated.execute({ command: "env" }, execution("isolated"), {
      ...env,
      DSH_LAYERFS_PROJECT: "managed-project",
      DSH_LAYERFS_SDK: "managed-sdk",
    });
    await isolated.close();
  } finally {
    if (oldProject === undefined) delete process.env.AEGIS_PROJECT;
    else process.env.AEGIS_PROJECT = oldProject;
    if (oldSdk === undefined) delete process.env.AEGIS_SDK;
    else process.env.AEGIS_SDK = oldSdk;
  }
  assert.equal(seen[0].AEGIS_PROJECT, undefined);
  assert.equal(seen[0].AEGIS_SDK, undefined);
  assert.equal(seen[0].DSH_LAYERFS_PROJECT, "managed-project");
  assert.equal(seen[0].DSH_LAYERFS_SDK, "managed-sdk");
});
