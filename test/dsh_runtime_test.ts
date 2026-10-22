import { strict as assert } from 'node:assert'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { Context } from '@deepseek-ai/cordis'
import Group from '@deepseek-ai/cordis-plugin-group'
import Loader from '@deepseek-ai/cordis-plugin-loader'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import AgentPreset from '@deepseek-ai/dsh-agent-preset'
import AgentPresets from '@deepseek-ai/dsh-agent-preset-registry'
import { SessionId } from '@deepseek-ai/dsh-session'
import SubagentRuntime from '@deepseek-ai/dsh-subagent'
import * as ShellEnv from '@deepseek-ai/dsh-shell-env'
import { load as parseYaml } from 'js-yaml'
import type {} from '@deepseek-ai/dsh-agent'
import type {} from '@deepseek-ai/dsh-agent-preset-registry'
import type {} from '@deepseek-ai/dsh-llm'
import type {} from '@deepseek-ai/dsh-shell-env'
import type {} from '@deepseek-ai/dsh-tools'
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

const { simClient } = await import(new URL('./client.js', pathToFileURL(sdk).href).href)
const { mountLocalActivations, startTestActivation } = await import(pathToFileURL(
  join(dshDir, 'packages/subagent/subagent/tests/local-activation.ts'),
).href)
const spawn = await import(pathToFileURL(
  join(dshDir, 'packages/subagent/subagent-spawn-in-process/src/index.ts'),
).href)
const { MockAdapter, textResponse, toolCallResponse } = await import(
  pathToFileURL(join(dshDir, 'packages/core/agent-loop/tests/mock-adapter.ts')).href,
)
const Persona = await import(pathToFileURL(join(dshDir, 'packages/preset/persona/src/index.ts')).href)
const ToolSubagent = await import(pathToFileURL(join(dshDir, 'packages/subagent/tool-subagent/src/index.ts')).href)
const ToolSubagentControl = await import(pathToFileURL(
  join(dshDir, 'packages/subagent/tool-subagent-control/src/index.ts'),
).href)
const ToolSubagentListAgents = await import(pathToFileURL(
  join(dshDir, 'packages/subagent/tool-subagent-control/src/list-agents.ts'),
).href)

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

test('Loader composes the PrismFS preset for native children and scoped bash', async () => {
  const root = await mkdtemp(join(tmpdir(), 'prismfs-dsh-loader-'))
  const overlayRoot = await mkdtemp(join(tmpdir(), 'prismfs-dsh-overlay-'))
  let ctx: Context | undefined
  try {
    await mkdir(join(root, 'src'))
    const layerfs = simClient(home, project)
    await layerfs.layerfs.project.init(root)
    const initialSnapshot = await layerfs.operator.inspect.snapshot()
    const initialMain = initialSnapshot.branches.find((branch: { name: string }) => branch.name === 'main')
    assert.ok(initialMain)

    const preset = (await readFile(join(prismfsRoot, 'integration/dsh-preset.yml'), 'utf8'))
      .replaceAll('/ABSOLUTE/PATH/PrismFS', prismfsRoot)
      .replaceAll('@deepseek-ai/dsh-agent-preset', 'cordis:agent-preset')
      .replaceAll('@deepseek-ai/dsh-persona', 'cordis:prismfs-persona')
      .replaceAll('@deepseek-ai/dsh-tool-subagent-control/list-agents', 'cordis:prismfs-list-agents')
      .replaceAll('@deepseek-ai/dsh-tool-subagent-control', 'cordis:prismfs-subagent-control')
      .replaceAll('@deepseek-ai/dsh-tool-subagent', 'cordis:prismfs-subagent')
    const configPath = join(overlayRoot, 'cordis.yml')
    await writeFile(configPath, preset)

    ctx = new Context()
    ctx.baseUrl = pathToFileURL(`${overlayRoot}/`).href
    await ctx.plugin(Loader)
    ctx.loader.builtins.group = Group
    Object.assign(ctx.loader.builtins, {
      'agent-preset': AgentPreset,
      'prismfs-persona': Persona,
      'prismfs-subagent': ToolSubagent,
      'prismfs-subagent-control': ToolSubagentControl,
      'prismfs-list-agents': ToolSubagentListAgents,
    })
    await mountAgentLoopTestDependencies(ctx, { workingDirectory: true })
    await mountLocalActivations(ctx)
    await ctx.plugin(AgentLoop, { agents: [] })
    await ctx.plugin(SubagentRuntime)
    await ctx.plugin(spawn, { providerName: 'spawn' })
    await ctx.plugin(ShellEnv)
    await ctx.plugin(AgentPresets, { default: 'prismfs' })
    await ctx.loader.root.update(parseYaml(await readFile(configPath, 'utf8')) as never[])
    const presets = ctx.get('agentPresets')
    assert.ok(presets)
    assert.equal((await presets.resolve('prismfs')).id, 'prismfs')
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
    const parent = (await ctx.agents.create({
      sessionId: SessionId(`prismfs-loader-parent-${process.pid}`),
      agentOptions: { provider: 'mock', model: 'mock' },
      setup: async (agentCtx: Context) => { await presets.mount(agentCtx, 'prismfs') },
    })).agent
    const executeChild = async (label: string, expected: string) => {
      const activation = await startTestActivation(ctx, 'spawn', {
        parent,
        label,
        prompt: [{ type: 'text', text: `Write and read ${expected}` }],
      })
      try {
        const result = await activation.result
        const results = toolResults(activation.localAgent.session)
        assert.equal(result.stopReason, 'completed')
        assert.ok(
          results.some((entry) => entry.stdout === expected),
          JSON.stringify(activation.localAgent.session.snapshotEvents()),
        )
        assert.ok(results.length >= 2)
        assert.equal(results[0].branch, results[1].branch)
        assert.equal(results[0].commit, results[1].commit)
        assert.equal(activation.localAgent.session.header.agentPreset, 'prismfs')
        const names = ctx.tools.schemas(activation.localAgent).map((tool) => tool.name)
        assert.equal(names.filter((name) => name === 'bash').length, 1)
        return { branch: results[0].branch, commit: results[0].commit }
      } finally {
        await activation.dispose()
      }
    }
    const a = await executeChild('prismfs child A', 'A')
    const b = await executeChild('prismfs child B', 'B')
    assert.notEqual(a.branch, b.branch)
    assert.notEqual(a.commit, b.commit)
    const afterDispose = await layerfs.operator.inspect.snapshot()
    assert.deepEqual(afterDispose.sandboxes.flatMap((sandbox: { workspaces: unknown[] }) => sandbox.workspaces), [])
    const finalMain = afterDispose.branches.find((branch: { name: string }) => branch.name === 'main')
    assert.equal(finalMain.base, initialMain.base)
  } finally {
    await ctx?.fiber.dispose()
    await rm(overlayRoot, { recursive: true, force: true })
    await rm(root, { recursive: true, force: true })
  }
})
