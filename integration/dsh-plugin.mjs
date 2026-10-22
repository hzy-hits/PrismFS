import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { dirname, isAbsolute, join } from "node:path";

export const name = "prismfs-bash";
export const inject = ["tools", "shellEnv"];

export function sessionBranch(sessionId) {
  if (typeof sessionId !== "string" || !sessionId) throw new Error("PrismFS requires a DSH session");
  return `dsh-${createHash("sha256").update(sessionId).digest("hex").slice(0, 40)}`;
}

function invoke(binary, args, env) {
  return new Promise((resolve, reject) => {
    // Do not pass AbortSignal: killing the kernel would abandon its leases.
    const child = spawn(binary, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "", bytes = 0, overflow = false;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (part) => {
      bytes += Buffer.byteLength(part);
      if (bytes > 24 * 1024 * 1024) overflow = true;
      if (!overflow) stdout += part;
    });
    child.stderr.on("data", (part) => { stderr = (stderr + part).slice(-16000); });
    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (code !== 0) reject(new Error(`PrismFS step failed (${signal ?? code}); cleanup is not confirmed: ${stderr}`));
      else if (overflow) reject(new Error("PrismFS response exceeded 24 MiB; step settled but output was not retained"));
      else {
        try { resolve(JSON.parse(stdout)); } catch { reject(new Error("Invalid PrismFS step response")); }
      }
    });
  });
}

export function createRunner(config, run = invoke) {
  if (!isAbsolute(config.binary ?? "")) throw new Error("PrismFS config.binary must be an absolute path");
  const pending = new Map();
  let closing = false;
  return {
    async execute(args, exec, managed) {
      if (closing) throw new Error("PrismFS plugin is closing");
      const branch = sessionBranch(exec.agent?.session.header.id);
      if (!managed.DSH_LAYERFS_PROJECT || !managed.DSH_LAYERFS_SDK || !managed.DSH_LAYERFS_HOME) {
        throw new Error("Choose a LayerFS project before running PrismFS bash");
      }
      if (typeof args.command !== "string" || !args.command.trim()) throw new Error("command must not be empty");
      if (args.run_in_background || args.workdir !== undefined || args.sandbox_permissions !== undefined) {
        throw new Error("PrismFS bash runs foreground commands at the Workspace root; background, host workdir and sandbox overrides are unsupported");
      }
      const timeout = args.timeout_ms ?? 120000;
      if (!Number.isSafeInteger(timeout) || timeout < 1 || timeout > 600000) throw new Error("timeout_ms must be an integer from 1 to 600000");
      const key = JSON.stringify([managed.DSH_LAYERFS_HOME, managed.DSH_LAYERFS_PROJECT, branch]);
      const previous = pending.get(key) ?? Promise.resolve();
      const operation = previous.catch(() => {}).then(async () => {
        exec.signal.throwIfAborted();
        const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(AEGIS_|DSH_|LAYERFS_)/.test(key)));
        Object.assign(env, managed, {
          AEGIS_BRIDGE: config.bridge ?? join(dirname(config.binary), "priv", "bridge_worker.mjs"),
          AEGIS_EXEC_TIMEOUT: String(timeout),
        });
        const result = await run(config.binary, ["step", branch, config.base ?? "main", args.command], env);
        if (result.branch !== branch || result.published !== false || typeof result.commit !== "string" || !Number.isInteger(result.exitCode)) {
          throw new Error("PrismFS returned an invalid step identity");
        }
        if (exec.signal.aborted) {
          throw new Error(`Cancelled after step settlement; branch=${branch}, commit=${result.commit || "none"}, cleanup confirmed. Completed changes may have been committed.`);
        }
        return result;
      });
      pending.set(key, operation);
      try { return await operation; }
      finally { if (pending.get(key) === operation) pending.delete(key); }
    },
    async close() {
      closing = true;
      await Promise.allSettled([...pending.values()]);
    },
  };
}

export function apply(ctx, config) {
  const runner = createRunner(config);
  ctx.effect(() => () => runner.close(), "prismfs: settle tool calls before teardown");
  ctx.tools.register({
    name: "bash",
    description: "Run a foreground bash command at your session's isolated project root. Checkpoints changes even on nonzero exit; returns output, branch and immutable commit identity; never publishes. Each call uses a fresh Workspace. Do not leave background processes running. Stop waits for the current call to settle and clean up.",
    parameters: {
      type: "object",
      properties: {
        command: { type: "string", description: "Shell command using project-relative paths." },
        timeout_ms: { type: "integer", description: "Command deadline in milliseconds, 1–600000; default 120000." },
      },
      required: ["command"],
      additionalProperties: false,
    },
    output: {
      schema: { type: "object", additionalProperties: true },
      render: (_args, value) => [{ type: "text", text: JSON.stringify({
        ...value,
        stdout: String(value.stdout ?? "").slice(-16000),
        stderr: String(value.stderr ?? "").slice(-16000),
        truncated: value.truncated || String(value.stdout ?? "").length > 16000 || String(value.stderr ?? "").length > 16000,
      }) }],
    },
    execute: (args, exec) => runner.execute(args, exec, ctx.shellEnv.collect(exec)),
  });
}
