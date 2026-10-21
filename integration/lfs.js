#!/usr/bin/env node
// `lfs`: the LayerFS calls an agent makes most, as one command each, so a
// bash call need not write an SDK script. The Host gives every bash call of a
// LayerFS conversation its path as DSH_LAYERFS_CLI; it imports the SDK of
// DSH_LAYERFS_SDK and works on DSH_LAYERFS_PROJECT. Each command makes its
// calls once; a refusal prints `<code>: <message>` and exits 2.
const USAGE = `usage: node "$DSH_LAYERFS_CLI" <command> ...
  status                         project and its Branches
  log <branch> [n]               newest Commits of a Branch
  ls <ref> [path]                list a folder (default /)
  cat <ref> <path>               print a file
  grep <ref> <pattern> [path]    search
  diff <a> <b>                   files that differ between two Branches
  fork <name> [from]             new Branch (from main by default)
  write <branch> <path> [msg]    file content from stdin, one Commit
  run <branch> <command> [msg]   run bash in a new Workspace of the Branch and
                                 Commit what it changed (--discard: keep nothing)
  fleet <command> ...            the AegisFleet kernel: status, reap, race, run
                                 (needs AEGIS_FLEET_BIN, the aegisfleet escript)
A ref is main, a Branch, a Commit id or a Layer id; paths are absolute.`;

const [cmd, ...rest] = process.argv.slice(2);
const discard = rest.includes("--discard");
const args = rest.filter((a) => a !== "--discard");
if (!cmd || cmd === "help" || cmd === "--help") { console.log(USAGE); process.exit(cmd ? 0 : 1); }
const project = process.env.DSH_LAYERFS_PROJECT;
if (!project || !process.env.DSH_LAYERFS_SDK) {
  console.error("lfs: this conversation has no LayerFS project (DSH_LAYERFS_PROJECT is unset); work on the local folder");
  process.exit(1);
}
const { LayerFS } = await import(process.env.DSH_LAYERFS_SDK);
const lf = new LayerFS(project);
const short = (id) => (id ? String(id).slice(0, 12) : "-");
const need = (n) => { if (args.length < n) { console.error(USAGE); process.exit(1); } };
const stdin = async () => { const parts = []; for await (const c of process.stdin) parts.push(c); return Buffer.concat(parts).toString("utf8"); };
let code = 0;

async function all(first, next) {
  const items = [];
  for (let page = await first(0); ; page = await next(page.nextPagePos)) {
    items.push(...page.items);
    if (!page.hasMore) return items;
  }
}

/**
 * One Bash call in a new Workspace of the project's service Sandbox: mount,
 * exec, Commit, unmount. The Sandbox is shared by the project's calls and
 * stays for the next one; the first call that needs it starts it. A call that
 * fails before its unmount discards its Workspace (one unmount either way). A
 * service Sandbox whose container is gone or stopped is closed, so the next
 * call starts a new one.
 */
async function run(branch, command, message) {
  const sb = await lf.service();
  let path;
  try {
    path = await lf.sandbox.mount(sb, branch);
  } catch (error) {
    if (error?.code === "NoSuchSandbox" && error.detail?.containerGone) {
      await lf.sandbox.close(sb).catch((e) => console.error(`lfs: could not close ${sb}: ${e.message}`));
    }
    throw error;
  }
  let unmounting = false;
  try {
    const r = await lf.sandbox.exec(sb, path, command);
    process.stdout.write(r.stdout);
    process.stderr.write(r.stderr);
    if (r.truncated) console.error("lfs: output was cut at 1 MiB per stream");
    code = r.exitCode;
    if (!discard) {
      const c = await lf.sandbox.commit(sb, path, message || `run: ${command.split("\n")[0].slice(0, 200)}`);
      console.error(`lfs: exit ${r.exitCode}; ${c.kind} ${short(c.head)} on ${branch}`);
    }
    unmounting = true;
    await lf.sandbox.unmount(sb, path, discard);
  } finally {
    if (!unmounting) await lf.sandbox.unmount(sb, path, true).catch((e) => console.error(`lfs: could not unmount ${path}: ${e.message}`));
  }
}

const commands = {
  async status() {
    const branches = await all((p) => lf.project.list_branches(100, p), (p) => lf.project.list_branches(100, p));
    console.log(`project ${project}; main changes only by publish`);
    for (const b of branches) console.log(b.name === "main" ? `  ${"main".padEnd(24)} Layer ${short(b.base)} (published; read it, fork from it)` : `  ${b.name.padEnd(24)} head ${short(b.head)}  base ${short(b.base)}`);
    if (!branches.some((b) => b.name !== "main")) console.log("  no Branches yet: lfs fork <name>");
  },
  async log() {
    need(1);
    const page = await lf.branch.list_commits(args[0], Number(args[1] || 20), 0);
    for (const c of page.items) console.log(`${short(c.id)} ${c.message ?? ""}`);
  },
  async ls() {
    need(1);
    const items = await all((p) => lf.fs.list(args[0], args[1] || "/", 1000, p), (p) => lf.fs.list(args[0], args[1] || "/", 1000, p));
    for (const e of items) console.log(`${e.type === "dir" ? "d" : e.type === "symlink" ? "l" : "-"} ${e.path}`);
    if (!items.length) console.log(`(empty: ${args[1] || "/"} on ${args[0]} has no entries)`);
  },
  async cat() {
    need(2);
    for (let line = 1; line;) {
      const r = await lf.fs.read(args[0], args[1], line);
      process.stdout.write(r.text);
      line = r.nextLine;
    }
  },
  async grep() {
    need(2);
    const page = await lf.fs.grep(args[0], args[1], args[2] || "/", 1000);
    for (const m of page.items) console.log(`${m.path}:${m.line}:${m.text.replace(/\r?\n$/, "")}`);
    if (page.hasMore) console.error("lfs: more matches; narrow the pattern or path");
  },
  async diff() {
    need(2);
    const page = await lf.branch.diff_branches(args[0], args[1], 1000);
    for (const d of page.items) console.log(`${d.kind} ${d.path}`);
    if (page.hasMore) console.error("lfs: more differences");
  },
  async fork() {
    need(1);
    const f = await lf.branch.fork(args[0], args[1]);
    console.log(`Branch ${f.branch} from ${args[1] || "main"}, head ${short(f.head)}`);
  },
  async write() {
    need(2);
    const c = await lf.fs.write(args[0], args[1], await stdin(), args[2]);
    console.log(`${c.kind} ${short(c.head)} on ${args[0]}`);
  },
  async run() {
    need(2);
    await run(args[0], args[1], args[2]);
  },
  async fleet() {
    const bin = process.env.AEGIS_FLEET_BIN;
    if (!bin) {
      console.error("lfs: set AEGIS_FLEET_BIN to the built aegisfleet escript (see the fleet project's scripts/build.sh)");
      process.exit(1);
    }
    const { spawnSync } = await import("node:child_process");
    const child = spawnSync(bin, args, { stdio: "inherit", env: process.env });
    if (child.error) { console.error(`lfs: fleet: ${child.error.message}`); process.exit(1); }
    code = child.status ?? 1;
  },
};

const MAIN_RO = "main is read-only: it's the published version, not a Branch. Read it (ls, cat, grep main ...),\nor fork a Branch (lfs fork <name>), work there and publish it.";
if (["log", "write", "run"].includes(cmd) && args[0] === "main") { console.error(MAIN_RO); process.exit(2); }
if (!commands[cmd]) { console.error(`lfs: unknown command ${cmd}\n${USAGE}`); process.exit(1); }
try {
  await commands[cmd]();
} catch (error) {
  console.error(error?.code ? (error.message.startsWith(error.code) ? error.message : `${error.code}: ${error.message}`) : String(error?.stack ?? error));
  code = 2;
} finally {
  await lf.close().catch(() => {});
}
process.exit(code);
