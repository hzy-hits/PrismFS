import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const control = process.env.CONTROL_DIR;
const logFile = join(control, "events.jsonl");
const record = (event, detail = {}) =>
  appendFileSync(logFile, `${JSON.stringify({ event, ...detail })}\n`);

async function waitForGate(name) {
  const gate = join(control, name);
  if (existsSync(gate)) return;
  await new Promise((resolve) => {
    const timer = setInterval(() => {
      if (existsSync(gate)) {
        clearInterval(timer);
        resolve();
      }
    }, 5);
  });
}

let unmountAttempts = 0;

export class LayerFS {
  constructor() {
    this.project = {
      init: async () => ({ project: "fixture", layer: "base" }),
      list_branches: async () => ({ items: [], hasMore: false }),
    };
    this.branch = {
      fork: async (name, from) => ({ branch: name, head: from }),
      publish: async () => undefined,
    };
    this.sandbox = {
      mount: async (sandbox, branch) => {
        record("mount-start", { sandbox, branch });
        if (process.env.BLOCK_MOUNT === "1") await waitForGate("allow-mount");
        record("mount-success", { sandbox, branch });
        return "/controlled/workspace";
      },
      exec: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      commit: async () => ({ kind: "Committed", head: "commit", commit: { id: "commit" } }),
      unmount: async (sandbox, path, discard) => {
        unmountAttempts++;
        record("unmount", { sandbox, path, discard, attempt: unmountAttempts });
        const failuresFile = join(control, "unmount-failures");
        const failures = existsSync(failuresFile)
          ? Number(readFileSync(failuresFile, "utf8").trim())
          : 0;
        if (unmountAttempts <= failures || existsSync(join(control, "fail-unmount"))) {
          const error = new Error("controlled unmount failure");
          error.code = "Busy";
          throw error;
        }
      },
    };
  }

  async service() {
    record("service");
    return "controlled-sandbox";
  }

  async close() {
    record("close");
  }
}
