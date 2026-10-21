# AegisFleet 未实现 / 未验证 / 不承诺事项

| 项 | 值 |
| :--- | :--- |
| 文档版本 | 1.0 |
| 对应版本 | git `bc005ff` |
| 配套验收 | [UAT.md](UAT.md)（24/24 PASS） |
| 原则 | 本文列出的内容**不构成已完成能力**；不要用 UAT 的通过项推断它们可用 |

状态口径：

- **未实现**：代码里没有，或只有空壳。
- **部分实现**：核心路径在，但缺少生产必需的环节。
- **已实现未验证**：代码在，但本次环境无法验证（例如 Live Docker）。
- **设计外**：明确不在本系统职责内。

---

## 1. 总表

| ID | 能力 | 状态 | 影响 | 补齐所需 | 规模 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| G-01 | DSH `FleetSubagentProvider` | 未实现 | 子 Agent 不会自动获得 Branch/Workspace | 改 `@dsh-layerfs/host`：provider + 生命周期 + env | M |
| G-02 | `ensureFleetDaemon` 随 `dsh web` 启停 | 未实现 | 需手动启动 `fleet` | `ctx.effect` 包一层守护进程 | S |
| G-03 | DSH GUI 中的舰队可视化 | 部分实现 | trace 可被 Collector 读，但界面看不到 | 真实 Session + `bindings.json` + Provider | M |
| G-04 | Live / Docker 模式 | 已实现未验证 | 只保证模拟器行为 | 在 live 项目重跑 UAT + daemon 容量测试 | M |
| G-05 | LLM 子 Agent worker | 未实现 | worker 只能跑 shell 命令 | Provider 派生 DSH subagent，结果回传 | L |
| G-06 | Pipeline 拓扑 | 未实现 | 无阶段/回滚/重试 | 新增 `topologies/pipeline.gleam` + 测试 | M |
| G-07 | FactBlackboard | 未实现 | 跨分支事实/踩坑不共享 | 新增 actor + worker 注入 + 测试 | M |
| G-08 | HTTP / MCP API | 未实现 | 只能 CLI/进程内调用 | Mist/Wisp server + 鉴权 | M |
| G-09 | Rustler NIF / Unix Socket 直连 | 未实现 | 多一层 Node 桥与 JSON 开销 | 原生绑定或 socket 协议 | L |
| G-10 | 跨进程全局槽位记账 | 部分实现 | 多控制面共享 Sandbox 可能超卖 | 全局租约表/daemon 侧强制 | M |
| G-11 | CPU 级抢占 | 部分实现 | 输家的远端 shell 可能继续跑 | 暴露进程句柄（operator/daemon API） | M |
| G-12 | 自动选优 / 评分 | 设计外（当前） | “哪个更好”由主 Agent/用户判断 | 显式指标 + `BestOf`，仍不自动发布 | M |
| G-13 | 服务端强制验证门禁 | 未实现 | 直接调 SDK 可绕过内核发布 | daemon policy / 签名 receipt | L |
| G-14 | 决策包持久化 / 审计回执 | 未实现 | 决策只在 stdout，trace 不含决策 | 写 receipts + journal | S |
| G-15 | Branch 生命周期 / GC | 未实现 | Portfolio 会留下所有候选分支 | 保留策略 + 删除/归档 | S |
| G-16 | 鉴权与多租户 | 未实现 | 本地信任模型 | API/Socket 鉴权、能力隔离 | L |
| G-17 | 指标 / 告警 / OTel | 未实现 | 只有 CLI stats 与 DSH trace | metrics endpoint + 埋点 | M |
| G-18 | CI / 打包 / 发布 | 未实现 | 无流水线、无镜像、无签名 | CI（带 LayerFS 依赖）、镜像、release | M |
| G-19 | TTL 回收测试 | 已实现未验证 | 长时间挂死租约无回归保护 | 缩短 TTL 的测试 | S |
| G-20 | Live 之外的后端矩阵 | 未实现 | Windows/远程 daemon 未验证 | 平台矩阵 | M |

---

## 2. DSH 宿主集成（M4，未实现）

### 2.1 当前状态

- 只交付了 `integration/lfs-fleet.patch`：给 `lfs.js` 增加 `fleet` 子命令，已在真实 checkout 上 `git apply --check` 通过。
- **补丁尚未应用**到正在运行的 DSH 源树（本会话对 `Projects/layerfs` 只有读权限）。因此现在运行中的 DSH 里，`node "$DSH_LAYERFS_CLI" fleet ...` **不可用**，除非你先应用补丁并设置 `AEGIS_FLEET_BIN`。
- Bridge 有 `bind` op，可以原子合并 `bindings.json`，但没有接到宿主生命周期里。
- trace 格式已用真实 `Collector` 验证（UAT-12），但这只证明“能读”，不证明“会显示”。

### 2.2 缺少的部分

1. `@dsh-layerfs/host` 的 `apply(ctx, config)` 中增加 `ctx.effect(ensureFleetDaemon(spec))`：随 `dsh web` 启停 escript/守护进程，写发现文件。
2. `ctx.subagents.registerProvider("fleet", provider)`：
   - 启动前分配 Branch 与 Workspace（调用 pool）；
   - 把 Branch/Workspace 注入子 Agent 的 bash 环境；
   - 结束后把 branch/commit/diff/verifier 输出作为结果交回主 Agent；
   - 用户 Stop / 崩溃时由 watcher 兜底回收。
3. `env.js` 注入 `AEGIS_FLEET_BIN` / `AEGIS_HOME` 等，让子 Agent 能调用 `lfs fleet`。
4. 把 `agentId → {root, name}` 写入 `bindings.json`，让 trace 出现在 Work/History。
5. 主 Agent 的“发布/上抛”决策：这是 DSH 对话层行为，内核不提供“问用户”原语。

### 2.3 影响

- 用户无法在 DSH 里用自然语言触发 `race/portfolio`；
- 看不到 worker 卡片与分支树；
- 子 Agent 不会自动隔离到独立 Branch；
- 目前只能由主 Agent 手动执行 CLI。

### 2.4 关闭条件

- 应用补丁后，在 `dsh web` 中用自然语言触发一次 portfolio；
- Work 面板出现具名 agent 卡片；
- History 面板出现候选分支；
- 用户点 Stop 后 1s 内 `snapshot.workspaces=[]`；
- 子 Agent 的结果不自动发布，主 Agent 能看到决策包。

---

## 3. Live / Docker 模式（已实现未验证）

### 3.1 当前状态

- 所有验证都在 LayerFS **模拟器**（`dsh/packages/host/src/sim`）上完成。
- Bridge 通过 `AEGIS_SDK` / `AEGIS_OPERATOR` 选择 SDK 入口，`AEGIS_SIM=1` 只是填模拟器的部署占位；理论上换 live 入口即可。
- 未在真实 `layerfs-daemon` + Docker + Store 上跑过。

### 3.2 未验证的具体行为

- daemon 真实的 16 Workspace 容量拒绝（`Failed` / `Capacity`）是否被正确重试；
- live `sandbox.commit` 的 `Conflict` / `HeadMoved` 语义与模拟器是否一致；
- `sandbox.status` 的 `activity` / `overlay` 字段在 live 下的形状（`reap` 依赖它）；
- live `exec` 的退出码、1 MiB 截断、超时行为；
- 容器清理、端口、volume 路径、macOS box。

### 3.3 关闭条件

- 用同一个 `docs/UAT.md` 在 live 项目跑通 24 条（其中 `AEGIS_SIM=1` 改为 0，补 `LAYERFS_IMAGE/DAEMON/DOCKER/VOLUME`）；
- 强制造出 17 个 mount，确认 pool 排队且 daemon 拒绝被正确退避；
- 强杀 bridge，确认 `reap` 在 live 下只清 idle+clean。

---

## 4. Worker 模型：shell，而非 LLM 子 Agent

设计文档的 `worker_runner` 描述为“支持 Shell 脚本任务与 Subagent LLM 循环”。当前只实现了前者：

- 候选是一个 `name:command`，在 Workspace 里执行；
- 没有多轮 LLM 循环、没有 token 统计、没有把 Blackboard 事实注入 prompt、没有中途追问。

因此 Portfolio 的“不同实现方案”目前必须由调用方写成脚本（或由主 Agent 预先写好脚本），不能让内核派生会自己写代码的 worker。补齐需要 G-01 / G-05。

---

## 5. 拓扑缺口

### 5.1 Pipeline（未实现）

设计文档的“闯关流水线”：Stage 1 写测试 → Stage 2 写实现 → Stage 3 压测；任意阶段失败回滚到上一阶段干净 Layer 并重试。

- 现状：没有 `pipeline.gleam`，没有阶段状态机、回滚、`max_retries_per_stage`。
- 关闭条件：新增拓扑 + 失败回滚测试 + UAT 用例。

### 5.2 Blackboard（未实现）

- 现状：没有跨分支的 `FactDiscovered` / `PitfallWarning` / `InterfaceLocked`，worker 之间零共享。
- 影响：并行候选会重复踩坑；MapReduce 的接口契约无法锁定。
- 关闭条件：有历史回放的 pubsub actor + 至少一个 worker 消费路径 + 测试。

### 5.3 已实现的拓扑

Race、MapReduce、Portfolio 已实现，但：
- Race 的自动发布只保留为 `--publish` 选项（默认关闭）；
- MapReduce 只做顺序折叠 merge，不做并行 merge 树；
- Portfolio 不做自动排序（见 G-12）。

---

## 6. 协议与性能

### 6.1 HTTP / MCP API（未实现）

- 只有 CLI 与进程内 API；没有 `api/http_server.gleam`、没有 Mist/Wisp、没有 MCP tool 暴露。
- 影响：无法被非 Node/非 BEAM 的客户端远程调用；无法在 DSH 之外集成。
- 关闭条件：本地 HTTP 或 Unix socket + 鉴权 + OpenAPI/tool schema + 测试。

### 6.2 原生桥（未实现）

- 当前是“BEAM Port ↔ Node 常驻进程 ↔ SDK”的两跳；每调用一次 JSON 序列化/反序列化。
- 没有 Rustler NIF，也没有直连 `layerfs-daemon` 的 Unix Socket。
- 影响：控制面调用有额外延迟（实测 mount/commit 约 1–15ms，可接受）；高频 Store 调用不适合走这里。
- 关闭条件：NIF 或 socket 驱动 + 与现有 UAT 等价的测试。

### 6.3 背压

- BEAM 侧 pending 是内存列表；Node 侧 inFlight 无上限；没有显式背压/队列上限。
- 正常 Fleet 规模（≤16 并发）无问题；异常客户端可能撑爆内存。

---

## 7. 资源与抢占的边界

### 7.1 16 槽位是“本控制面”的容量观（部分实现）

- `WorkspacePool` 自己限制 `max_slots`（默认 16），但不知道同一 Sandbox 里其他控制面/其他 Agent 占了多少。
- 多个 `fleet` 进程共享 `_service.<project>` 时可能超卖；`Capacity` 拒绝会退避重试，但记账不跨进程。
- `reap` 只能清理 idle+clean 的残留，不能替代全局租约。
- 关闭条件：daemon 侧租约/配额，或跨进程租约文件 + 锁。

### 7.2 CPU 级抢占（部分实现）

- `sandbox.exec` 不暴露子进程句柄；Race 的抢占是“杀 BEAM worker + 丢弃 Workspace + 结构上禁止 commit/publish”。
- 输家的 shell 可能继续跑完（例如 `sleep 5`），只是永远无法发布；已 commit 的 Branch 保留。
- 关闭条件：用 `operator.process.start` + `cancel` 或 daemon 的 kill API 实现真正终止，并加 UAT。

### 7.3 被丢弃的未提交工作

- worker 被杀时其 Workspace 以 `discard: true` 卸载，未 commit 的修改丢失。
- 这是 Race 的预期行为；Portfolio 不杀 worker，所以不受影响。
- 如果未来要保留失败尝试，应在杀之前 commit 或提供 `--keep-failed`（未实现）。

---

## 8. 决策、门禁与审计

### 8.1 验证门禁是进程内编译期保证（部分实现）

- `VerifiedCommit` 的构造器私有，`publish` 只接受它——这对**走内核代码**的调用成立。
- 任何能直接访问 LayerFS SDK 的进程都可以调用 `branch.publish` 绕过内核；daemon 不强制“必须验证过”。
- `fleet publish` 通过“重新验证 + 复查 head + 按 Commit id 发布”保证 CLI 路径安全，但它不是密码学证明。
- 关闭条件：daemon 侧 policy（只允许带 receipt 的 publish）或签名 receipt；这需要改 LayerFS 核心，超出当前范围。

### 8.2 没有自动选优（设计外，当前）

- Portfolio 只给事实：branch、commit、改动文件、验证耗时、stdout；没有“哪个更好”的算法。
- 这是刻意选择：测试通过不是“更好”的证明；主 Agent/用户决定是否发布或上抛。
- 若未来加 `BestOf(metric)`，必须显式定义指标且仍然默认不自动发布。

### 8.3 决策包不持久化（未实现）

- `[packet]` 只打印到 stdout；没有写 receipts、没有 decision journal。
- trace 记录的是 SDK 调用，不记录“主 Agent 为什么选 c”。
- 关闭条件：把 packet/choice 写到 `<home>/<project>/decisions/`，并在 `fleet publish` 时校验。

---

## 9. 生命周期与运维

### 9.1 Branch 保留/GC（未实现）

- Portfolio 会让所有候选 Branch 留在 Store 里；Race 的输家也保留已 commit 的 Branch。
- 没有删除/归档命令，没有 TTL/保留策略。
- 影响：长期运行会积累分支；History 面板变长。
- 关闭条件：`fleet prune --older-than` 或项目级保留策略（注意：删除是不可逆的，必须显式确认）。

### 9.2 安全与多租户（未实现）

- 本地信任模型：谁能跑 `fleet`/SDK，谁就能操作项目；没有鉴权、没有租户隔离。
- Bridge 继承调用方环境，`AEGIS_*` 可被覆盖；命令内容会进 trace/session 记录（原有 LayerFS 行为）。
- 关闭条件：API/Socket 鉴权、能力令牌、审计。

### 9.3 指标与告警（未实现）

- 只有 `[pool]` 一行 stats 和 DSH trace；没有 Prometheus/OTel、没有队列深度/租约年龄/失败率的历史。
- 关闭条件：metrics endpoint + 关键指标 + 告警规则。

### 9.4 打包与 CI（未实现）

- 交付物是源码 + `scripts/build.sh` 生成的 escript；没有 Docker 镜像、没有签名发布、没有 CI。
- `.github/workflows/test.yml` 已删除：默认 CI 环境没有 LayerFS checkout，跑不了集成测试；加 CI 需要先解决依赖。
- Gleam 1.19.2 在 `../.toolchain`，hex 缓存在 `../.home`——这是本会话的沙箱变通，不是标准安装方式。

---

## 10. 测试缺口

| 缺口 | 说明 | 补齐 |
| :--- | :--- | :--- |
| Live 后端 | 全部 UAT 只跑 sim | G-04 |
| TTL 回收 | 代码有，未测 | 缩短 TTL 的单测 |
| 多控制面并发 | 未测两个 fleet 共享 Sandbox | 双进程压测 + 容量断言 |
| 长稳/soak | 未跑小时级循环 | soak 脚本 + 泄漏监控 |
| 协议 fuzz | 帧长度/坏 JSON/半包未 fuzz | property test |
| Windows/远程 daemon | 未验证 | 平台矩阵 |
| 安全 | 未做威胁建模/渗透 | G-16 |

---

## 11. 设计文档里程碑对照

| 里程碑 | 设计文档目标 | 当前状态 |
| :--- | :--- | :--- |
| **M1** | 桥接 + WorkspacePool + trace | **已完成（sim 验证）**；live 未验证 |
| **M2** | Opaque 门禁 + Race | **已完成**；抢占为逻辑抢占 |
| **M3** | MapReduce + Blackboard | **MapReduce 已完成**；Blackboard 未实现 |
| **M4** | DSH Provider / 端到端 | **未实现**；只有 `lfs.js` 补丁 |

另外新增了设计文档没有的 **Portfolio** 与 **`fleet publish`**，因为“第一个通过测试”不等于“最好的实现”，决策权应在主 Agent。

---

## 12. 明确不承诺

- **不承诺 exactly-once**：exec/commit 都是单次调用，失败不自动重放（除 mount 的显式退避）。
- **不承诺分布式一致性**：没有跨主机共识；LayerFS 的 Branch/Commit 是唯一事实源。
- **不承诺跨主机舰队**：当前是单机、单项目、单 Bridge。
- **不承诺自动解决冲突**：MapReduce 冲突会返回 `MergeFailed`，不自动选边。
- **不承诺 token/成本核算**：worker 是 shell，不是 LLM 循环，没有 token 统计。
- **不承诺生产 SLO**：没有压测、没有容量规划、没有高可用。

---

## 13. 建议优先级

**P0（让能力真正可用）**

1. 应用 `lfs.js` 补丁并设置 `AEGIS_FLEET_BIN`；
2. 实现 `FleetSubagentProvider` + `ensureFleetDaemon`（G-01/G-02）；
3. 在 live 项目跑通 UAT（G-04）。

**P1（补齐设计文档）**

4. Pipeline（G-06）与 Blackboard（G-07）；
5. 决策包持久化/回执（G-14）；
6. 全局槽位记账（G-10）。

**P2（生产化）**

7. HTTP/MCP API（G-08）、鉴权（G-16）、指标（G-17）；
8. Rustler NIF / Unix Socket（G-09）；
9. CI、镜像、签名发布（G-18）。
