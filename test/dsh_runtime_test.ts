import { strict as assert } from 'node:assert'
import { mkdir, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { Context } from '@deepseek-ai/cordis'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import { SessionId } from '@deepseek-ai/dsh-session'
import SubagentRuntime from '@deepseek-ai/dsh-subagent'
import * as ShellEnv from '@deepseek-ai/dsh-shell-env'
import { test } from 'vitest'

const dshDir = process.env.DSH_DIR
const prismfsRoot = process.env.PRISMFS_ROOT
const binary = process.env.PRISMFS_BINARY
const sdk = process.env.DSH_LAYERFS_SDK
const home = process.env.DSH_LAYERFS_HOME
const project = process.env.DSH_LAYERFS_PROJECT

if (!dshDir || !prismfsRoot || !binary || !sdk || !home || !project) {
  throw new Error('DSH_DIR, PRISMFS_ROOT, PRISMFS_BINARY and DSH_LAYERFS_* values are required')
}

const prismfs = await import(pathToFileURL(join(prismfsRoot, 'integration/dsh-plugin.mjs')).href)
const { sessionBranch } = prismfs
const { simClient } = await import(new URL('./client.js', pathToFileURL(sdk).href).href)
const { mountLocalActivations, startTestActivation } = await import(
  pathToFileURL(join(dshDir, 'packages/subagent/subagent/tests/local-activation.ts')).href,
)
const { MockAdapter, textResponse, toolCallResponse } = await import(
  pathToFileURL(join(dshDir, 'packages/core/agent-loop/tests/mock-adapter.ts')).href,
)
const spawn = await import(
  pathToFileURL(join(dshDir, 'packages/subagent/subagent-spawn-in-process/src/index.ts')).href,
)

function strings(value: unknown): string[] {
  if (typeof value === 'string') return [value]
  if (Array.isArray(value)) return value.flatMap(strings)
  if (value && typeof value === 'object') return Object.values(value).flatMap(strings)
  return []
}

function toolResults(session: { snapshotEvents(): unknown[] }) {
  return strings(session.snapshotEvents()).flatMap((text) => {
    try {
      const value = JSON.parse(text)
      return value && typeof value === 'object' && 'branch' in value && 'commit' in value ? [value] : []
    } catch {
      return []
    }
  })
}

test('native DSH spawn children use PrismFS across multiple bash turns', async () => {
  const root = await mkdtemp(join(tmpdir(), 'prismfs-dsh-runtime-'))
  const ctx = new Context()
  try {
    await mkdir(join(root, 'src'))
    const layerfs = simClient(home, project)
    await layerfs.layerfs.project.init(root)
    const initialSnapshot = await layerfs.operator.inspect.snapshot()
    const initialMain = initialSnapshot.branches.find((branch: { name: string }) => branch.name === 'main')
    assert.ok(initialMain)
    await mountAgentLoopTestDependencies(ctx, { workingDirectory: true })
    await mountLocalActivations(ctx)
    await ctx.plugin(AgentLoop, { agents: [] })
    await ctx.plugin(SubagentRuntime)
    await ctx.plugin(spawn, { providerName: 'spawn' })
    await ctx.plugin(ShellEnv)
    ctx.shellEnv.register({
      name: 'prismfs-runtime',
      variables: {
        DSH_LAYERFS_PROJECT: { description: 'LayerFS simulator project.' },
        DSH_LAYERFS_SDK: { description: 'Pinned LayerFS simulator SDK.' },
        DSH_LAYERFS_HOME: { description: 'Private simulator home.' },
      },
      resolve: () => ({
        DSH_LAYERFS_PROJECT: project,
        DSH_LAYERFS_SDK: sdk,
        DSH_LAYERFS_HOME: home,
      }),
    })
    const adapter = new MockAdapter([
      toolCallResponse('a-write', 'bash', { command: 'printf A > src/agent-value' }),
      toolCallResponse('a-read', 'bash', { command: 'cat src/agent-value' }),
      textResponse('A complete'),
      toolCallResponse('b-write', 'bash', { command: 'printf B > src/agent-value' }),
      toolCallResponse('b-read', 'bash', { command: 'cat src/agent-value' }),
      textResponse('B complete'),
    ])
    ctx.llm.registerAdapter(['mock'], adapter)
    await ctx.plugin(prismfs as never, { binary })
    const parent = await ctx.agentLoop.create(SessionId(`prismfs-parent-${process.pid}`), {
      provider: 'mock',
      model: 'mock',
    }, { cwd: root })
    const executeChild = async (label: string, expected: string) => {
      const activation = await startTestActivation(ctx, 'spawn', {
        parent,
        label,
        prompt: [{ type: 'text', text: `Write and read ${expected}` }],
      })
      const result = await activation.result
      const results = toolResults(activation.localAgent.session)
      assert.equal(result.stopReason, 'completed')
      assert.ok(
        results.some((entry) => entry.stdout === expected),
        JSON.stringify(activation.localAgent.session.snapshotEvents()),
      )
      assert.ok(results.length >= 2)
      assert.ok(results.every((entry) => entry.branch === sessionBranch(activation.localAgent.session.header.id)))
      assert.equal(results[0].commit, results[1].commit)
      await activation.dispose()
      return { session: activation.localAgent.session, branch: results[0].branch, commit: results[0].commit }
    }
    const a = await executeChild('prismfs child A', 'A')
    const b = await executeChild('prismfs child B', 'B')
    assert.notEqual(a.branch, b.branch)
    assert.notEqual(a.commit, b.commit)
    const finalSnapshot = await layerfs.operator.inspect.snapshot()
    const finalMain = finalSnapshot.branches.find((branch: { name: string }) => branch.name === 'main')
    assert.equal(finalMain.base, initialMain.base)
    assert.deepEqual(finalSnapshot.sandboxes.flatMap((sandbox: { workspaces: unknown[] }) => sandbox.workspaces), [])
  } finally {
    await ctx.fiber.dispose()
    await rm(root, { recursive: true, force: true })
  }
})
