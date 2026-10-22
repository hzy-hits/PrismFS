#!/usr/bin/env node
// AegisFleet ⇄ LayerFS long-lived bridge.
//
// The BEAM kernel starts this process once and speaks length-prefixed JSON
// frames ({packet, 4} on the Erlang side): a 4-byte big-endian length
// followed by one UTF-8 JSON object per frame. stdout carries frames only;
// every diagnostic goes to stderr so it can never corrupt the stream.
//
// One request:   {"id": 7, "op": "mount", "args": {"branch": "feat"}, "trace": "racer-1"}
// One answer:    {"id": 7, "ok": true,  "result": {"path": "/workspaces/3"}}
//                {"id": 7, "ok": false, "error": {"code": "Busy", "message": "…"}}
//
// The SDK writes DSH-compatible `layerfs_trace:1` lines itself (one file per
// `trace` name), so the DSH Work view can replay every fleet worker without
// any change to the Host plugin.
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";

const env = process.env;
const HOME = env.AEGIS_HOME || env.LAYERFS_HOME || "";
const PROJECT = env.AEGIS_PROJECT || "";
const TRACE_DIR = env.AEGIS_TRACE_DIR || (HOME ? join(HOME, "traces") : "");
const SANDBOX = env.AEGIS_SANDBOX || "";
const SDK = env.AEGIS_SDK || "";

const fail = (code, message) => Object.assign(new Error(message), { code });
const log = (...parts) => process.stderr.write(`[bridge] ${parts.join(" ")}\n`);

if (!HOME) { log("AEGIS_HOME is required"); process.exit(2); }
if (!PROJECT) { log("AEGIS_PROJECT is required"); process.exit(2); }
if (!SDK) { log("AEGIS_SDK is required"); process.exit(2); }

// The SDK reads LAYERFS_HOME (or DSH_LAYERFS_HOME) when a client is built.
env.LAYERFS_HOME = HOME;
// A simulated project answers Store calls itself; the SDK only checks that a
// Store path was named (dsh deployed simulated projects with STORE_PATH=sim).
if (env.AEGIS_SIM === "1") {
  env.LAYERFS_STORE_PATH ||= "sim";
  // The simulator answers these itself, but the SDK checks they are named.
  env.LAYERFS_DOCKER ||= "sim";
  env.LAYERFS_IMAGE ||= "sim";
  env.LAYERFS_DAEMON ||= "sim";
  env.LAYERFS_VOLUME ||= "sim";
}
if (TRACE_DIR) mkdirSync(TRACE_DIR, { recursive: true });

/** Import the configured SDK entry: a file path (sim/sdk.js) or a specifier. */
async function loadSdk() {
  const entry = isAbsolute(SDK) ? pathToFileURL(SDK).href : SDK;
  const sdk = await import(entry);
  let Operator = null;
  if (env.AEGIS_OPERATOR) {
    const opEntry = isAbsolute(env.AEGIS_OPERATOR) ? pathToFileURL(env.AEGIS_OPERATOR).href : env.AEGIS_OPERATOR;
    Operator = (await import(opEntry)).LayerFSOperator ?? null;
  }
  return { LayerFS: sdk.LayerFS, Operator };
}

let LayerFS = null;
let Operator = null;
let lf = null;
let sdkCompatibilityError = null;
try {
  ({ LayerFS, Operator } = await loadSdk());
  if (typeof LayerFS !== "function") {
    throw fail("IncompatibleSDK", "configured SDK does not export LayerFS");
  }
  lf = new LayerFS(PROJECT);
  const required = [
    ["service", lf],
    ["project.init", lf.project],
    ["project.list_branches", lf.project],
    ["branch.fork", lf.branch],
    ["branch.publish", lf.branch],
    ["sandbox.mount", lf.sandbox],
    ["sandbox.exec", lf.sandbox],
    ["sandbox.commit", lf.sandbox],
    ["sandbox.unmount", lf.sandbox],
  ];
  const missing = required
    .filter(([name, owner]) => typeof owner?.[name.split(".").at(-1)] !== "function")
    .map(([name]) => name);
  if (missing.length) {
    throw fail(
      "IncompatibleSDK",
      `LayerFS revision lacks the legacy SDK methods PrismFS requires: ${missing.join(", ")}`,
    );
  }
} catch (error) {
  sdkCompatibilityError = fail(
    "IncompatibleSDK",
    error?.message ?? String(error),
  );
  log(`${sdkCompatibilityError.code}: ${sdkCompatibilityError.message}`);
}

/** The simulator's own read model, when this bridge drives a simulated project. */
let simOperator = null;
const simClientSpec = env.AEGIS_SIM_CLIENT || (env.AEGIS_SIM === "1" && SDK.includes("/sim/sdk.js")
  ? new URL("./client.js", isAbsolute(SDK) ? pathToFileURL(SDK).href : SDK).href
  : "");
if (simClientSpec && !sdkCompatibilityError) {
  const entry = isAbsolute(simClientSpec) ? pathToFileURL(simClientSpec).href : simClientSpec;
  const { simClient } = await import(entry);
  simOperator = simClient(HOME, PROJECT).operator;
}

const DSH_TRACE = env.DSH_LAYERFS_TRACE || "";
const traceOffsets = new Map();

/** One SDK client per trace name: the SDK writes that file's trace lines. */
const clients = new Map();
function clientFor(trace) {
  if (!trace || !TRACE_DIR) return lf;
  let client = clients.get(trace);
  if (!client) {
    const file = join(TRACE_DIR, `${trace}.jsonl`);
    traceOffsets.set(trace, existsSync(file) ? readFileSync(file, "utf8").length : 0);
    client = new LayerFS(PROJECT, { trace: file });
    clients.set(trace, client);
  }
  return client;
}

function mirrorDshTrace(trace) {
  if (!DSH_TRACE || !trace || !TRACE_DIR) return;
  const file = join(TRACE_DIR, `${trace}.jsonl`);
  if (file === DSH_TRACE || !existsSync(file)) return;
  try {
    const raw = readFileSync(file, "utf8");
    const prev = traceOffsets.get(trace) ?? 0;
    if (raw.length <= prev) return;
    const chunk = raw.slice(prev);
    traceOffsets.set(trace, raw.length);
    for (const line of chunk.split("\n")) {
      if (!line.trim()) continue;
      const parsed = JSON.parse(line);
      appendFileSync(DSH_TRACE, `${JSON.stringify({ ...parsed, agent: trace })}\n`);
    }
  } catch { /* never fail an op on trace mirror */ }
}

/** Sandboxes this process mounted in, so a lost kernel still cleans up. */
const mounts = new Map();
const confirmedReleased = new Set();
let sandbox = SANDBOX || null;
let sandboxPromise = null;

async function sandboxId() {
  if (sandbox) return sandbox;
  if (!sandboxPromise) {
    sandboxPromise = Promise.resolve()
      .then(() => lf.service())
      .then((found) => {
        sandbox = found;
        return found;
      })
      .catch((error) => {
        sandboxPromise = null;
        throw error;
      });
  }
  sandbox = await sandboxPromise;
  return sandbox;
}

async function all(first, next) {
  const items = [];
  for (let page = await first(0); ; page = await next(page.nextPagePos)) {
    items.push(...page.items);
    if (!page.hasMore) return items;
  }
}

/** Test-only fault injection: the next `times` calls of `op` fail as `code`. */
const faults = new Map();
const fireFault = (op) => {
  const fault = faults.get(op);
  if (fault && fault.remaining > 0) {
    fault.remaining--;
    throw fail(fault.code, fault.message || `injected ${fault.code} on ${op}`);
  }
};

/** One inspect snapshot from whichever read model this backend has. */
async function readModel() {
  if (simOperator) return simOperator.inspect.snapshot();
  if (!Operator) throw fail("Unsupported", "snapshot needs AEGIS_OPERATOR (or AEGIS_SIM_CLIENT)");
  return new Operator(lf).inspect.snapshot();
}

/** Sim snapshots group Workspaces per Sandbox; the live one lists them flat. */
const workspacesOf = (snap) =>
  snap.workspaces ?? (snap.sandboxes ?? []).flatMap((sb) => (sb.workspaces ?? []).map((w) => ({ ...w, path: w.path ?? w.directory })));

const ops = {
  async hello() {
    if (sdkCompatibilityError) throw sdkCompatibilityError;
    return { project: PROJECT, home: HOME, sandbox: sandbox, pid: process.pid, traceDir: TRACE_DIR };
  },

  async init({ source }) {
    if (!source) throw fail("InvalidInput", "init needs a source folder");
    return lf.project.init(source);
  },

  async branches() {
    const items = await all((p) => lf.project.list_branches(100, p), (p) => lf.project.list_branches(100, p));
    return { branches: items.map((b) => ({ name: b.name, base: b.base, head: b.head })) };
  },

  async fork({ name, from, trace }) {
    fireFault("fork");
    return clientFor(trace).branch.fork(name, from);
  },

  async fork_snapshot({ snapshot, trace }) {
    if (typeof snapshot !== "string" || !snapshot.trim()) {
      throw fail("NoChanges", "verification requires an immutable commit");
    }
    const forked = await clientFor(trace).branch.fork(`verify-${randomUUID()}`, snapshot);
    if (forked.head !== snapshot) {
      throw fail("InvalidSnapshot", "verification reference must identify a saved commit, not a branch");
    }
    return forked;
  },

  async mount({ branch, trace }) {
    fireFault("mount");
    if (!branch) throw fail("InvalidInput", "mount needs a branch");
    const sb = await sandboxId();
    const path = await clientFor(trace).sandbox.mount(sb, branch);
    confirmedReleased.delete(path);
    mounts.set(path, { branch, trace: trace ?? null, sandbox: sb, at: Date.now() });
    return { path, branch, sandbox: sb };
  },

  async exec({ path, command, trace }) {
    if (!path || typeof command !== "string") throw fail("InvalidInput", "exec needs path and command");
    const sb = await sandboxId();
    const r = await clientFor(trace).sandbox.exec(sb, path, command);
    return { exitCode: r.exitCode, stdout: r.stdout ?? "", stderr: r.stderr ?? "", truncated: !!r.truncated };
  },

  async commit({ path, message, trace }) {
    fireFault("commit");
    if (!path) throw fail("InvalidInput", "commit needs path");
    const sb = await sandboxId();
    const r = await clientFor(trace).sandbox.commit(sb, path, message);
    return { kind: r.kind, head: r.head ?? null, commitId: r.commit?.id ?? r.head ?? null };
  },

  async unmount({ path, discard }) {
    fireFault("unmount");
    if (!path) throw fail("InvalidInput", "unmount needs path");
    const owned = mounts.get(path);
    if (!owned && confirmedReleased.has(path)) return;
    const sb = owned?.sandbox ?? await sandboxId();
    const result = await clientFor(owned?.trace).sandbox.unmount(sb, path, !!discard);
    if (owned) mounts.delete(path);
    confirmedReleased.add(path);
    return result;
  },

  async status({ path }) {
    const sb = await sandboxId();
    return lf.sandbox.status(sb, path);
  },

  async diff({ branch, with: other }) {
    const page = await clientFor(null).branch.diff_branches(branch, other, 1000);
    return {
      items: (page.items ?? []).map((item) => ({ path: item.path, kind: item.kind })),
      hasMore: !!page.hasMore,
    };
  },

  async merge({ branch, with: other, name, message, trace }) {
    fireFault("merge");
    return clientFor(trace).branch.merge(branch, other, name, message);
  },

  async publish({ branch, commit, trace }) {
    if (typeof commit !== "string" || !commit.trim()) {
      throw fail("NoChanges", "publish requires an explicit verified commit");
    }
    fireFault("publish");
    return clientFor(trace).branch.publish(branch, commit);
  },

  async read({ branch, path }) {
    return lf.fs.read(branch, path);
  },

  async write({ branch, path, content, message }) {
    return lf.fs.write(branch, path, content, message);
  },

  async list({ branch, path }) {
    return lf.fs.list(branch, path || "/");
  },

  /** The daemon's read model: every mounted Workspace in this Sandbox. */
  async snapshot() {
    const snap = await readModel();
    return {
      project: snap.project,
      branches: snap.branches?.map((b) => ({ name: b.name, head: b.head })) ?? [],
      commits: snap.commits?.length ?? 0,
      workspaces: workspacesOf(snap).map((w) => ({
        path: w.directory ?? w.path, branch: w.branch, dirty: w.dirty?.inodes ?? 0, pendingMerge: !!w.pendingMerge,
      })),
    };
  },

  /**
   * The janitor the preset prompt used to make the model hand-write: unmount
   * every Workspace that is Idle with nothing uncommitted. Skips paths the
   * caller names in `keep`.
   */
  async reap({ keep = [] } = {}) {
    const snap = await readModel();
    const kept = new Set(keep);
    const reaped = [];
    for (const w of workspacesOf(snap)) {
      const path = w.directory ?? w.path;
      if (kept.has(path)) continue;
      const owned = mounts.get(path);
      const sb = owned?.sandbox ?? await sandboxId();
      const layer = clientFor(owned?.trace);
      const status = await layer.sandbox.status(sb, path);
      const clean = !status.overlay?.inodes && !status.overlay?.entries && !status.overlay?.pendingMerge;
      if (status.activity !== "Idle" || !clean) continue;
      await layer.sandbox.unmount(sb, path);
      mounts.delete(path);
      confirmedReleased.add(path);
      reaped.push({ path, branch: w.branch });
    }
    return { reaped };
  },

  async faults({ op, code = "Busy", times = 1, message }) {
    faults.set(op, { code, remaining: times, message });
    return { op, code, times };
  },

  /** Register `agentId -> {root, name}` in a DSH Host bindings.json (merge, atomic). */
  async bind({ agentId, root, name }) {
    const file = env.AEGIS_BINDINGS;
    if (!file || !agentId || !root) throw fail("InvalidInput", "bind needs AEGIS_BINDINGS, agentId and root");
    mkdirSync(dirname(file), { recursive: true });
    const data = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : { version: 3, projects: {}, workspaces: {}, sessions: {}, agents: {} };
    data.agents ??= {};
    data.agents[agentId] = { root, name: name || agentId, project: PROJECT };
    const tmp = `${file}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(data, null, 1) + "\n");
    renameSync(tmp, file);
    return { file, agentId };
  },

  async shutdown() {
    return explicitShutdown();
  },
};

/** Unmount everything this bridge still holds (except with `keep`). */
async function releaseMounts() {
  const failures = [];
  for (const [path, owned] of mounts) {
    try {
      await clientFor(owned.trace).sandbox.unmount(owned.sandbox, path, true);
      mounts.delete(path);
      confirmedReleased.add(path);
    } catch (error) {
      failures.push({
        path,
        branch: owned.branch,
        sandbox: owned.sandbox,
        error: error?.message ?? String(error),
      });
    }
  }
  return failures;
}

let cleanupPromise = null;
let closePromise = null;

function cleanupMounts() {
  if (!cleanupPromise) {
    cleanupPromise = releaseMounts().finally(() => {
      cleanupPromise = null;
    });
  }
  return cleanupPromise;
}

function closeLayer() {
  if (!closePromise) {
    closePromise = Promise.resolve()
      .then(() => lf?.close?.())
      .catch(() => undefined);
  }
  return closePromise;
}

let closing = false;
let accepting = true;
let activeOperations = 0;
let idleWaiters = [];

function operationStarted() {
  activeOperations++;
}

function operationFinished() {
  activeOperations--;
  if (activeOperations === 0) {
    for (const resolve of idleWaiters.splice(0)) resolve();
  }
}

async function waitForOperations() {
  if (activeOperations === 0) return;
  await new Promise((resolve) => idleWaiters.push(resolve));
}

function unresolvedText(failures) {
  return failures
    .map((item) => `${item.path} branch=${item.branch} sandbox=${item.sandbox}: ${item.error}`)
    .join("; ");
}

async function explicitShutdown() {
  accepting = false;
  await waitForOperations();
  const failures = await cleanupMounts();
  if (failures.length) {
    throw fail("CleanupFailed", `owned mounts remain: ${unresolvedText(failures)}`);
  }
  await closeLayer();
  setImmediate(() => process.exit(0));
  return { ok: true };
}

async function terminalShutdown(code, reason) {
  if (closing) return;
  closing = true;
  accepting = false;
  await waitForOperations();
  let delay = 50;
  for (;;) {
    const failures = await cleanupMounts();
    if (!failures.length) break;
    log(`${reason} cleanup unresolved: ${unresolvedText(failures)}`);
    await new Promise((resolve) => setTimeout(resolve, delay));
    delay = Math.min(delay * 2, 5000);
  }
  await closeLayer();
  process.exit(code);
}

// ---------------------------------------------------------------- framing

const MAX_FRAME = 64 * 1024 * 1024;
let buffer = Buffer.alloc(0);
let inFlight = 0;

function send(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const head = Buffer.alloc(4);
  head.writeUInt32BE(body.length, 0);
  process.stdout.write(Buffer.concat([head, body]));
}

async function handle(frame) {
  let request;
  try { request = JSON.parse(frame); } catch (error) {
    send({ id: null, ok: false, error: { code: "InvalidInput", message: `bad JSON frame: ${error.message}` } });
    return;
  }
  const { id, op, args = {} } = request ?? {};
  if (!accepting && op !== "shutdown") {
    send({ id, ok: false, error: { code: "Closing", message: "bridge is draining and accepts no new operations" } });
    return;
  }
  const trace = request?.trace ?? args.trace;
  const effectiveTrace = trace ?? (args.path ? mounts.get(args.path)?.trace : null);
  const fn = ops[op];
  if (!fn) {
    send({ id, ok: false, error: { code: "UnknownMethod", message: `unknown op ${op}` } });
    return;
  }
  const counted = op !== "shutdown";
  if (counted) operationStarted();
  try {
    if (sdkCompatibilityError) throw sdkCompatibilityError;
    const result = await fn({ ...args, trace });
    mirrorDshTrace(effectiveTrace);
    send({ id, ok: true, result: result ?? null });
  } catch (error) {
    mirrorDshTrace(effectiveTrace);
    if (op === "mount" && error?.code) log(`mount failed: ${error.code}: ${error.message}`);
    send({ id, ok: false, error: { code: error?.code ?? "Failed", message: error?.message ?? String(error), detail: error?.detail ?? null } });
  } finally {
    if (counted) operationFinished();
  }
}

process.stdin.on("data", (chunk) => {
  buffer = buffer.length ? Buffer.concat([buffer, chunk]) : chunk;
  while (buffer.length >= 4) {
    const length = buffer.readUInt32BE(0);
    if (length > MAX_FRAME) { log(`frame too large: ${length}`); terminalShutdown(2, "invalid frame"); return; }
    if (buffer.length < 4 + length) break;
    const frame = buffer.subarray(4, 4 + length).toString("utf8");
    buffer = buffer.subarray(4 + length);
    inFlight++;
    handle(frame).finally(() => { inFlight--; });
  }
});

process.stdin.on("end", () => { terminalShutdown(0, "EOF"); });
process.on("SIGTERM", () => { terminalShutdown(0, "SIGTERM"); });
process.on("SIGINT", () => { terminalShutdown(0, "SIGINT"); });
process.on("uncaughtException", (error) => log("uncaught:", error?.stack ?? String(error)));
process.on("unhandledRejection", (error) => log("unhandled:", error?.stack ?? String(error)));
log(`ready project=${PROJECT} home=${HOME} sdk=${SDK}`);
