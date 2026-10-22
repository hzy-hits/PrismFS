import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const control = process.env.CONTROL_DIR
  || join(process.env.AEGIS_HOME, process.env.AEGIS_PROJECT);
mkdirSync(control, { recursive: true });
const logFile = join(control, "events.jsonl");
const record = (event, detail = {}) =>
  appendFileSync(logFile, `${JSON.stringify({ event, ...detail })}\n`);

async function waitForGate(name) {
  const gate = join(control, name);
  if (existsSync(gate)) return;
  await new Promise((resolve, reject) => {
    const timer = setInterval(() => {
      if (existsSync(gate)) {
        clearInterval(timer);
        clearTimeout(deadline);
        resolve();
      }
    }, 5);
    const deadline = setTimeout(() => {
      clearInterval(timer);
      reject(new Error(`timed out waiting for gate ${name}`));
    }, 10000);
  });
}

let unmountAttempts = 0;
let mountedCount = 0;

export class LayerFS {
  constructor(project) {
    this.projectName = project;
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
        if (process.env.BLOCK_MOUNT === "1" || branch.includes("late-mount")) {
          await waitForGate("allow-mount");
        }
        record("mount-success", { sandbox, branch });
        mountedCount++;
        writeFileSync(join(control, "mounted-count"), String(mountedCount));
        return "/controlled/workspace";
      },
      exec: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
      commit: async () => ({ kind: "Committed", head: "commit", commit: { id: "commit" } }),
      unmount: async (sandbox, path, discard) => {
        unmountAttempts++;
        record("unmount", { sandbox, path, discard, attempt: unmountAttempts });
        if (process.env.BLOCK_UNMOUNT === "1") await waitForGate("allow-unmount");
        if (this.projectName.startsWith("discard-upgrade-") && !discard) {
          const error = new Error("dirty workspace requires discard");
          error.code = "Busy";
          throw error;
        }
        const failuresFile = join(control, "unmount-failures");
        const failures = existsSync(failuresFile)
          ? Number(readFileSync(failuresFile, "utf8").trim())
          : 0;
        if (unmountAttempts <= failures || existsSync(join(control, "fail-unmount"))) {
          const error = new Error("controlled unmount failure");
          error.code = "Busy";
          throw error;
        }
        mountedCount = Math.max(0, mountedCount - 1);
        writeFileSync(join(control, "mounted-count"), String(mountedCount));
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
