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

const { LayerFS, Operator } = await loadSdk();
const lf = new LayerFS(PROJECT);

/** The simulator's own read model, when this bridge drives a simulated project. */
let simOperator = null;
if (env.AEGIS_SIM_CLIENT) {
  const entry = isAbsolute(env.AEGIS_SIM_CLIENT) ? pathToFileURL(env.AEGIS_SIM_CLIENT).href : env.AEGIS_SIM_CLIENT;
  const { simClient } = await import(entry);
  simOperator = simClient(HOME, PROJECT).operator;
}

/** One SDK client per trace name: the SDK writes that file's trace lines. */
const clients = new Map();
function clientFor(trace) {
  if (!trace || !TRACE_DIR) return lf;
  let client = clients.get(trace);
  if (!client) {
    const file = join(TRACE_DIR, `${trace}.jsonl`);
    client = new LayerFS(PROJECT, { trace: file });
    clients.set(trace, client);
  }
  return client;
}

/** Sandboxes this process mounted in, so a lost kernel still cleans up. */
const mounts = new Map();
let sandbox = SANDBOX || null;

async function sandboxId() {
  if (!sandbox) sandbox = await lf.service();
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

  async mount({ branch, trace }) {
    fireFault("mount");
    if (!branch) throw fail("InvalidInput", "mount needs a branch");
    const sb = await sandboxId();
    const path = await clientFor(trace).sandbox.mount(sb, branch);
    mounts.set(path, { branch, trace: trace ?? null, at: Date.now() });
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
    if (!path) throw fail("InvalidInput", "unmount needs path");
    const sb = await sandboxId();
    try {
      return await clientFor(mounts.get(path)?.trace).sandbox.unmount(sb, path, !!discard);
    } finally {
      mounts.delete(path);
    }
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
    fireFault("publish");
    return clientFor(trace).branch.publish(branch, commit || undefined);
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
    const sb = await sandboxId();
    const kept = new Set(keep);
    const reaped = [];
    for (const w of workspacesOf(snap)) {
      const path = w.directory ?? w.path;
      if (kept.has(path)) continue;
      const status = await lf.sandbox.status(sb, path);
      const clean = !status.overlay?.inodes && !status.overlay?.entries && !status.overlay?.pendingMerge;
      if (status.activity !== "Idle" || !clean) continue;
      await lf.sandbox.unmount(sb, path);
      mounts.delete(path);
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
    setImmediate(() => shutdown(0));
    return { ok: true };
  },
};

/** Unmount everything this bridge still holds (except with `keep`). */
async function releaseMounts() {
  if (!sandbox) return;
  for (const [path] of mounts) {
    try { await lf.sandbox.unmount(sandbox, path, true); } catch { /* daemon may be gone */ }
  }
  mounts.clear();
}

let closing = false;
async function shutdown(code) {
  if (closing) return;
  closing = true;
  try { await releaseMounts(); } catch (error) { log("cleanup failed:", error.message); }
  try { await lf.close(); } catch { /* already closed */ }
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
  const trace = request?.trace ?? args.trace;
  const fn = ops[op];
  if (!fn) {
    send({ id, ok: false, error: { code: "UnknownMethod", message: `unknown op ${op}` } });
    return;
  }
  try {
    const result = await fn({ ...args, trace });
    send({ id, ok: true, result: result ?? null });
  } catch (error) {
    if (op === "mount" && error?.code) log(`mount failed: ${error.code}: ${error.message}`);
    send({ id, ok: false, error: { code: error?.code ?? "Failed", message: error?.message ?? String(error), detail: error?.detail ?? null } });
  }
}

process.stdin.on("data", (chunk) => {
  buffer = buffer.length ? Buffer.concat([buffer, chunk]) : chunk;
  while (buffer.length >= 4) {
    const length = buffer.readUInt32BE(0);
    if (length > MAX_FRAME) { log(`frame too large: ${length}`); shutdown(2); return; }
    if (buffer.length < 4 + length) break;
    const frame = buffer.subarray(4, 4 + length).toString("utf8");
    buffer = buffer.subarray(4 + length);
    inFlight++;
    handle(frame).finally(() => { inFlight--; });
  }
});

process.stdin.on("end", () => { if (inFlight === 0) shutdown(0); else setTimeout(() => shutdown(0), 50); });
process.on("SIGTERM", () => shutdown(0));
process.on("SIGINT", () => shutdown(0));
process.on("uncaughtException", (error) => log("uncaught:", error?.stack ?? String(error)));
process.on("unhandledRejection", (error) => log("unhandled:", error?.stack ?? String(error)));
log(`ready project=${PROJECT} home=${HOME} sdk=${SDK}`);
