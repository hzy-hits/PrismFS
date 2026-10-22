# AegisFleet 未实现 / 未验证 / 不承诺事项

| 项 | 值 |
| :--- | :--- |
| 文档版本 | 1.1 |
| 对应版本 | 本地工作树（Workpack A ~ E；未推送远端） |
| 配套验收 | [UAT.md](UAT.md)（30/30 PASS） |
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
| G-01 | DSH `FleetSubagentProvider` | 已实现未验证 | provider 已写好并按默认 `spawn` 之外的方式注册；默认 preset 仍用 `spawn` | 重启 DSH、把 `tool-subagent` 指向 `fleet` 并实测一次派生/Stop | M |
| G-02 | `ensureFleetDaemon` 随 `dsh web` 启停 | 部分实现 | 环境变量与 `DSH_LAYERFS_FLEET` 已注入，但进程仍不随 `dsh web` 启停 | `ctx.effect` 包一层守护进程 | S |
| G-03 | DSH GUI 中的舰队可视化 | 部分实现 | trace 可被 Collector 读；provider 已登记 `childSessionId -> {root, name, branch}`，界面仍未实测 | 真实 Session + `bindings.json` + Provider | M |
| G-04 | Live / Docker 模式 | 已实现未验证 | 只保证模拟器行为 | 在 live 项目重跑 UAT + daemon 容量测试 | M |
| G-05 | LLM 子 Agent worker | 部分实现 | 内核 worker 仍只能跑 shell 命令；`fleet-provider.js` 已能把 DSH 的 subagent 隔离到独立 Branch | 内核侧 LLM worker 循环 + 结果回传 | L |
| G-06 | Pipeline 拓扑 | 已实现 | 阶段门禁、按阶段回滚重试、耗尽干净停止 | —（UAT-25..28 守护） | M |
| G-07 | FactBlackboard | 已实现（未自动注入 worker） | 跨分支事实/踩坑/接口锁已可共享；worker 命令前缀仍是手工拼 | 把快照注入 `worker_runner` 的 exec 前缀 | M |
| G-08 | HTTP / MCP API | 未实现 | 只能 CLI/进程内调用 | Mist/Wisp server + 鉴权 | M |
| G-09 | Rustler NIF / Unix Socket 直连 | 未实现 | 多一层 Node 桥与 JSON 开销 | 原生绑定或 socket 协议 | L |
| G-10 | 跨进程全局槽位记账 | 部分实现 | 多控制面共享 Sandbox 可能超卖 | 全局租约表/daemon 侧强制 | M |
| G-11 | CPU 级抢占 | 部分实现 | 输家的远端 shell 可能继续跑 | 暴露进程句柄（operator/daemon API） | M |
| G-12 | 自动选优 / 评分 | 设计外（当前） | “哪个更好”由主 Agent/用户判断 | 显式指标 + `BestOf`，仍不自动发布 | M |
| G-13 | 服务端强制验证门禁 | 未实现 | 直接调 SDK 可绕过内核发布 | daemon policy / 签名 receipt | L |
| G-14 | 决策包持久化 / 审计回执 | 已实现 | `<home>/decisions/<project>/` 下的 packet/latest/receipts | —（UAT-29 守护） | S |
| G-15 | Branch 生命周期 / GC | 部分实现 | 决策记录可 `prune_packets`，`stale_branches` 给出候选；Branch 删除仍未实现（SDK 无删除原语） | daemon/SDK 侧删除或归档 | S |
| G-16 | 鉴权与多租户 | 未实现 | 本地信任模型 | API/Socket 鉴权、能力隔离 | L |
| G-17 | 指标 / 告警 / OTel | 未实现 | 只有 CLI stats 与 DSH trace | metrics endpoint + 埋点 | M |
| G-18 | CI / 打包 / 发布 | 未实现 | 无流水线、无镜像、无签名 | CI（带 LayerFS 依赖）、镜像、release | M |
| G-19 | TTL 回收测试 | 已实现未验证 | 长时间挂死租约无回归保护 | 缩短 TTL 的测试 | S |
| G-20 | Live 之外的后端矩阵 | 未实现 | Windows/远程 daemon 未验证 | 平台矩阵 | M |

---

## 2. DSH 宿主集成

### 2.1 当前状态

- 当前接入是仓库内的 `integration/dsh-plugin.mjs` 和独立 preset，见
  [安装、生命周期和验收边界](DSH.md)。保留 DSH 原生 `spawn`，不替换 provider。
- 每个 DSH session 绑定独立 Branch，Bash 经过 `fleet step` 和已有 pool/bridge；
  每次调用使用临时 Workspace。非零命令退出也提交实际修改，结果不自动发布。
- 旧 Workpack 文档曾描述外部 checkout 的 `fleet-provider.js`，但固定的 LayerFS
  checkout 不含它；不能把那份历史描述当成本仓库的可安装实现。

### 2.2 仍缺少的部分

1. 即时中止在途远程命令、跨 CLI 共享容量和强杀后的持久化恢复。不以新增 daemon
   作为多轮 agent 的前提；未决操作继续等待，不能把超时当成资源消失。
2. 工具值含结构化 Branch/Commit；原生子 agent 完成消息仍是 DSH 的 assistant
   output，没有新增完成结果协议。验证/发布仍由独立的现有入口执行。
3. Live Docker、GUI 卡片/分支树和真实模型调用的产品验收。

### 2.3 关闭条件

- 两个原生 DSH 子 agent 在同一项目各跑多轮工具调用，分支稳定且互不混写；
- Stop 后停止新调用，在途调用结束/超时后确认清理；不承诺 1 秒内回收；
- 无变更调用保持快照身份，清理失败不返回成功，候选不自动发布；
- 区分 mock 模型的真实运行时集成、LayerFS 模拟器与 Live 产品验收。

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

- 用同一个 `docs/UAT.md` 在 live 项目跑通 30 条（其中 `AEGIS_SIM=1` 改为 0，补 `LAYERFS_IMAGE/DAEMON/DOCKER/VOLUME`）；
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

### 5.1 Pipeline（已实现）

- `src/aegis/topologies/pipeline.gleam`：`Stage(name, command, verifier)` 顺序闯关；每次尝试 `<prefix>-<stage>-try-<k>` **从上一阶段已验证 Commit 重新 fork**，因此上一次失败的脏写物理消失；`max_retries_per_stage` 耗尽后返回 `StageFailed` 并保持 `[pool] 0/16`。
- 单测 3 条（三阶段成功 / 失败重试回滚 / 耗尽停止）+ UAT-25..28。
- 已知边界：单个 Stage 只有一条 `command`，重试时命令相同；需要“第 2 次才正确”的场景要靠 Branch 之外的标记（测试用 `home` 下的 flag 文件），内核不注入 attempt 序号。

### 5.2 Blackboard（已实现，未自动注入 worker）

- `src/aegis/blackboard.gleam`：`FactDiscovered` / `PitfallWarning` / `InterfaceLocked` 三种条目；`Subscribe` 先按 seq 重放全部历史再推新条目；`interface_conflict` 对同 path 不同签名返回先锁定条目；`snapshot_json` / `export_json` / `render_prompt` 供 shell worker 消费；`fleet blackboard` 是一个可复跑的演示。
- 单测 2 条 + UAT-30。
- 缺口：`worker_runner` 还不会在 `exec` 前自动把 `render_prompt` 拼进命令前缀（G-07 余项）。

### 5.3 已实现的拓扑

Race、MapReduce、Portfolio、Pipeline 已实现，但：
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

### 8.3 决策包已持久化（已实现）

- `src/aegis/decision_store.gleam`：`<home>/decisions/<project>/packet-0001.json`（单调 seq）、`latest.json`、`receipts.jsonl`（真 append）。
- `portfolio` / `race` / `map-reduce` / `pipeline` 都写 packet；`fleet publish` 与 `pipeline --publish` 追加发布回执；`fleet decisions` 读回。
- 仍未做：“为什么选这个”的人工理由（choice）没有单独字段；回执不是密码学签名（见 8.1）。

---

## 9. 生命周期与运维

### 9.1 Branch 保留/GC（部分实现）

- Portfolio 会让所有候选 Branch 留在 Store 里；Race 的输家也保留已 commit 的 Branch。
- 新增：`decision_store.prune_packets(home, project, keep)` 删除旧决策包，`stale_branches(candidates, keep)` 给出可回收候选（纯函数）。
- 仍未实现：Branch 的删除/归档命令——LayerFS SDK 没有删除 Branch 的原语，必须先加 daemon/SDK 能力。
- 关闭条件：`fleet prune --older-than` 或项目级保留策略（删除不可逆，必须显式确认）。

### 9.2 安全与多租户（未实现）

- 本地信任模型：谁能跑 `fleet`/SDK，谁就能操作项目；没有鉴权、没有租户隔离。
- Bridge 继承调用方环境，`AEGIS_*` 可被覆盖；命令内容会进 trace/session 记录（原有 LayerFS 行为）。
- 关闭条件：API/Socket 鉴权、能力令牌、审计。

### 9.3 指标与告警（未实现）

- 只有 `[pool]` 一行 stats 和 DSH trace；没有 Prometheus/OTel、没有队列深度/租约年龄/失败率的历史。
- 关闭条件：metrics endpoint + 关键指标 + 告警规则。

### 9.4 打包与 CI（未实现）

- 交付物是源码 + `scripts/build.sh` 生成的 escript；没有 Docker 镜像、没有签名发布、没有 CI。
- 默认 CI 环境若不包含 LayerFS 仓库，集成测试需先挂载或拉取 LayerFS 依赖。

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
| **M3** | MapReduce + Blackboard | **已完成**（Blackboard actor + 回放 + 接口锁） |
| **M4** | DSH Provider / 端到端 | **部分完成**：provider + 顶层别名 + preset 已落地，未在重启的 DSH 中实测 |

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

1. 重启 `dsh web`，实测 `FleetSubagentProvider` 与自发 portfolio（G-01/G-03）；
2. `ensureFleetDaemon` 生命周期托管（G-02）；
3. 在 live 项目跑通 UAT（G-04）。

**P1（补齐设计文档）**

4. Blackboard 快照自动注入 worker 命令前缀（G-07 余项）；
5. 全局槽位记账（G-10）；
6. Branch 删除/归档（G-15 余项）。

**P2（生产化）**

7. HTTP/MCP API（G-08）、鉴权（G-16）、指标（G-17）；
8. Rustler NIF / Unix Socket（G-09）；
9. CI、镜像、签名发布（G-18）。
