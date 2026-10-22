# DSH integration

PrismFS is the middle control layer, not another agent runtime:

```text
DSH native spawn → DSH model/tool loop → PrismFS bash plugin
  → fleet step → existing Gleam pool/bridge → LayerFS
```

The plugin does not register a subagent provider. DSH retains child identity,
context, continuations, tool scheduling and Stop. Existing shell topologies stay
unchanged; native subagents do not need another topology/task protocol.

## Install

1. Build PrismFS with `./scripts/build.sh`. Keep the executable beside `priv/`.
2. Use a DSH profile that already loads the LayerFS host plugin and native `spawn`.
   Select a **test** LayerFS project. Its SDK must match `layerfs.revision`; do not
   point an old SDK at newer Live data to bypass compatibility checks.
3. Add the preset row in [`integration/dsh-preset.yml`](../integration/dsh-preset.yml)
   to the profile's Cordis configuration, replacing the two absolute paths.
4. Select `PrismFS` for a new conversation. Children inherit that preset. Do not
   load `@deepseek-ai/dsh-tool-bash`, host file tools or jobs into this preset.
   The plugin owns its scoped `bash` tool; it does not patch DSH source.
5. Ask two native subagents to each write and read a different project-relative
   file over several tool calls, then report their Branch and Commit. Review
   their outputs before choosing any publication.

The integration targets DSH source revision
`687f282e8625c6b8d11ff58211a90524be2e4317`. DSH APIs are pre-stable. An
installation using another revision needs the real-composition test repeated.
Run the opt-in simulator composition test from PrismFS after building its CLI:
`DSH_DIR=/home/ubuntu/repos/deepseek-harness ./scripts/test-dsh-runtime.sh`.
The test requires a prepared pinned DSH checkout, Node/pnpm and Erlang/escript,
not the Gleam compiler. To test a prebuilt artifact, set `PRISMFS_BINARY` and
`DSH_LAYERFS_SDK` to absolute paths; the SDK must be the compatible simulator
distribution, including its sibling `client.js`. This bypasses the separate
LayerFS checkout requirement. Without an explicit SDK (`DSH_LAYERFS_SDK` or
`AEGIS_SDK`), the script uses the pinned simulator under `LAYERFS_DIR` (default:
the sibling `layerfs` checkout). It never installs or builds dependencies.
`DSH_LAYERFS_HOME` takes precedence over `AEGIS_HOME`; if neither is supplied,
the script creates and removes a private temporary home. A supplied home is
retained. `DSH_LAYERFS_PROJECT` is honored, or defaults to a per-process test name.
It uses the pinned DSH Vitest configuration and test-only AgentLoop composition;
it starts child sessions through the real in-process spawn provider and
SubagentRuntime, with a scripted model boundary. The test also parses this
shipped preset through a real Cordis Loader tree, registers the DSH host
services from source as Loader builtins, resolves the actual
`file:///.../integration/dsh-plugin.mjs`, mounts the preset on a parent, and
checks inherited child scope and disposal. This source-host composition is
intentionally narrower than qualification of the full deployed headless
profile; it does not claim production profile or Live Docker coverage, and it
does not exercise a parent model selecting the native subagent tool.

## Ownership and results

`agent.session.header.id` determines a stable `dsh-<hash>` Branch inside the
selected project. The first call forks from `main` (or the plugin's explicit
`base` ref); later calls resume that Branch. Children start from that base, not
from a parent's uncommitted files. The model cannot choose another Branch or
project in tool arguments. Project/SDK/deployment values come from the existing
LayerFS `shellEnv` contribution, not ambient `AEGIS_*` overrides.

Calls in one plugin instance on the same project/Branch are serialized. Distinct
sessions can execute concurrently, using LayerFS's existing contention checks.
There is **no global shared pool or quota across CLI processes/DSH instances**.
This integration binds tools, not a security boundary against arbitrary code
inside the Sandbox; do not expose additional host file tools.

Each call mounts, executes, commits (including a nonzero exit), and releases its
own Workspace. A no-change call returns the previous Commit, possibly an empty
Commit field for a never-committed Branch. Empty identity is not publishable.
The CLI emits JSON only after drain and bridge shutdown succeed. Output includes
`branch`, `commit`, `kind`, `exitCode`, `stdout`, `stderr`, `truncated`, and
`published: false`. Tool rendering limits each stream to its last 16000 characters.

A commit refusal fails the tool; the current CLI cleanup policy discards the
uncommitted overlay. It does not claim a candidate was saved. Do not concurrently
edit these owned Branches outside this adapter. Conflict recovery with retained
overlays is not implemented here.

## Stop, timeout and teardown

- Already-cancelled/queued calls do not start a kernel.
- Stop **does not kill the kernel or call global `reap`**. An admitted command
  finishes (or reaches its command deadline), then commits and cleans up before
  the plugin settles. Changes can therefore be committed after Stop.
- `timeout_ms` defaults to 120000, with a maximum of 600000. Commands execute
  through the Sandbox's GNU `timeout` with 5 seconds of kill escalation. The
  Sandbox image must supply GNU `timeout` and Bash. This is foreground-only;
  daemonized/background descendants are unsupported.
- Bridge exec/commit reply deadlines are not proof of completion. The step waits
  for their definitive settlement and disables TTL reclamation of its live lease.
  A stuck backend can keep Stop pending beyond the command deadline.
- Failed unmounts retain the existing pool/bridge ownership and retry behavior.
  A cleanup error is not reported as successful JSON. Unknown outcomes, forced
  process loss and DSH restart recovery are not made durable by this adapter.
- Cordis disposal stops admission and awaits accepted tool calls.

This follows [LayerFS Core Ideas](https://layerfs.ai/docs/core-ideas/): the Branch
lives across agent turns; a Workspace normally lives for one tool call. No daemon
or second LLM loop is added. Instant OS cancellation and cross-process capacity
arbitration are not claimed.

## Publication

This preset deliberately exposes no publication tool. An operator chooses the
candidate and runs `aegisfleet publish <branch> --verify '<command>'` in the
matching project environment. The existing gate verifies an isolated immutable
snapshot and publishes that exact identity. There is no new expected-main CAS.
The plugin's canonical tool value is structured; DSH's native child completion
remains its assistant output, so the preset asks children to report their IDs.

## Checks

```sh
./scripts/build.sh
node --test test/dsh_plugin_test.mjs test/bridge_lifecycle_test.mjs
./scripts/test.sh
DSH_DIR=/home/ubuntu/repos/deepseek-harness ./scripts/test-dsh-runtime.sh
```

The opt-in runtime test exercises real AgentLoop child sessions, the in-process
spawn provider, the actual PrismFS tool, and the shipped scoped preset through
the Loader against the LayerFS simulator. Its test-only Loader host registers
the pinned DSH source modules as builtins so the preset's production file
namespace is resolved without installing a deployed profile. It does not claim
full headless-profile or Live Docker qualification.
