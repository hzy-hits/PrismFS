# AegisFleet 验收测试（UAT）

| 项 | 值 |
| :--- | :--- |
| 文档版本 | 1.0 |
| 被测版本 | 代码 `bc005ff`（main-agent decision）· 文档 `1f69738` |
| 验收环境 | macOS arm64 · Erlang/OTP 28 · Node v22.22.0 · Gleam 1.19.2 · LayerFS 模拟器 |
| 验收日期 | 2026-10-21（以实际运行环境时钟为准） |
| 一键验收 | `./scripts/uat.sh` → 本次 **PASS=24 FAIL=0** |
| 范围外事项 | 见 [NOT_IMPLEMENTED.md](NOT_IMPLEMENTED.md) |

---

## 1. 验收目标

本次验收只针对以下**已实现且可验证**的声明：

1. 内核能在真实 LayerFS 模拟器上完成 `fork → mount → exec → commit → unmount → verify → publish` 全链路。
2. Workspace 的 16 槽位由 `WorkspacePoolActor` 统一管理；worker 被杀/崩溃时自动 `unmount(discard)` 并归还槽位，不依赖调用方写 `finally`。
3. `Busy` / `Capacity` 等瞬时冲突按指数退避重试；排队者有独立超时，不会永久占位。
4. `VerifiedCommit` 是不透明类型，未通过验证的 Commit 在编译期就无法传给 `publish`。
5. Race / MapReduce / Portfolio 三个拓扑**默认都不写 `main`**；只有 `--publish` 或显式 `fleet publish` 才发布。
6. Portfolio 会跑完所有候选、全部验证、输出决策包（含 branch / commit / 改动文件 / 验证耗时 / stdout），由主 Agent 决定选哪个或上抛。
7. 每次发布都重新过验证门禁，并确认 Branch head 未移动；按验证过的 Commit id 发布。
8. 每个 Agent 的调用写出 DSH 兼容的 `layerfs_trace:1`，可被 DSH 真实的 `Collector` 消费。
9. 残留挂载（例如 BEAM 整机异常）可由 `fleet reap` 安全清理；Bridge 优雅退出时也会清理自己登记过的挂载。
10. 独立 escript 可在不依赖 `gleam run` 的情况下完成上述流程。

## 2. 非验收范围

以下**不在本次验收内**，不得据此判定通过：DSH GUI 中的舰队可视化、`FleetSubagentProvider`、Docker Live 模式、Pipeline 拓扑、Blackboard、HTTP/MCP API、Rust NIF、CPU 级进程抢占、自动选优、服务端强制门禁。详见 [NOT_IMPLEMENTED.md](NOT_IMPLEMENTED.md)。

---

## 3. 环境与准备

### 3.1 依赖

- Erlang/OTP **28**（`erl` 可用）
- Node.js **≥ 22**
- 一个 LayerFS checkout（默认 `/Users/huangzhenyu/Projects/layerfs`，用 `LAYERFS_DIR` 覆盖）
- Gleam：`scripts/env.sh` 优先使用 `../.toolchain/gleam`（1.19.2），否则 PATH 上的 `gleam`；可用 `GLEAM_BIN` 覆盖

### 3.2 一键准备

```bash
cd aegisfleet
source scripts/env.sh     # 设置临时 home、模拟器 SDK、trace 目录
./scripts/build.sh        # 生成 ./aegisfleet
```

`scripts/env.sh` 会创建临时 LayerFS home，所有用例都不会触碰你正在运行的 DSH 实例。

手动用例可以先创建一个一次性项目（命令会打印要 eval 的 exports）：

```bash
eval "$(./scripts/seed.sh priv/fixture_portfolio uat-pf)"
./aegisfleet portfolio --verify "$(command -v node) check.js" a:… b:… c:…
```

### 3.3 一键验收

```bash
./scripts/uat.sh
```

脚本逐条打印 `PASS/FAIL`，最后输出 `acceptance: PASS=24 FAIL=0`，非零退出表示有失败项。它覆盖本文第 4 节的自动化用例；需要人工判断的用例见第 5 节。

---

## 4. 自动化用例（本次实测 24/24 通过）

### A. 构建与静态门禁

| ID | 目的 | 命令 | 期望 | 本次结果 |
| :--- | :--- | :--- | :--- | :--- |
| UAT-01 | 干净编译 | `gleam build` | 退出 0 | PASS |
| UAT-02 | 代码格式 | `gleam format --check src test` | 退出 0 | PASS |
| UAT-03 | 内核测试全绿 | `./scripts/test.sh` | `11 passed, no failures` | PASS |
| UAT-04 | 编译期门禁 | `./scripts/prove_opaque.sh` | 编译器拒绝 `UnverifiedCommit`，输出 `PASS` | PASS |

### B. Race：只报告，主 Agent 决策

| ID | 目的 | 命令（`uat.sh` 内部） | 期望 | 本次结果 |
| :--- | :--- | :--- | :--- | :--- |
| UAT-05 | Race 不自动发布 | `./scripts/demo.sh` | 输出 `NOT published (caller decides)` | PASS |
| UAT-06 | 决策后才发布 | 同上（demo 扮演主 Agent） | 输出 `main updated from race-alpha` | PASS |
| UAT-07 | 发布内容正确 | 同上 | 输出 `main:/src/value.txt = 42` | PASS |
| UAT-08 | 无残留 Workspace | 同上 | 输出 `[pool] 0/16 Workspaces in use` | PASS |

### C. MapReduce：合流后仍不自动发布

| ID | 目的 | 命令 | 期望 | 本次结果 |
| :--- | :--- | :--- | :--- | :--- |
| UAT-09 | 合流后只报告 | `./aegisfleet demo-map-reduce "$AEGIS_FIXTURE_MR"` | `NOT published (caller decides)` | PASS |
| UAT-10 | 决策后才发布 | 同上 | `main updated from merge-` | PASS |
| UAT-11 | 合并结果正确 | 同上 | `main:/src/a.txt = A` | PASS |

### D. 可观测性与 DSH 契约

| ID | 目的 | 命令 | 期望 | 本次结果 |
| :--- | :--- | :--- | :--- | :--- |
| UAT-12 | DSH Collector 能读舰队 trace | `node verify/collector_contract.mjs` | `collector accepted 5 fleet trace lines` | PASS |
| UAT-13 | 残留挂载 janitor | `node verify/leak_reap.mjs` | `reap: { reaped: [...] }`，之后 `snapshot after reap: []` | PASS |
| UAT-14 | `lfs.js` 补丁可应用 | `git -C "$LAYERFS_DIR" apply --check integration/lfs-fleet.patch` | 退出 0 | PASS（仅证明可应用；运行中的 DSH 仍需手动应用并设置 `AEGIS_FLEET_BIN`） |

### E. Portfolio：全量评估、包不发布

| ID | 目的 | 命令 | 期望 | 本次结果 |
| :--- | :--- | :--- | :--- | :--- |
| UAT-15 | 三个不同方案全部验证 | `fleet portfolio --verify "node check.js" a:… b:… c:…` | `3 verified; nothing published` | PASS |
| UAT-16 | 决策包机器可读 | 同上 | `[packet] {"aegisfleet":1,…"published":null,…}` | PASS |
| UAT-17 | 评估阶段 `main` 不变 | 读取 `main:/src/value.txt` | `0` | PASS |
| UAT-18 | 拒绝隐式发布 | `fleet portfolio --publish c …` | `portfolio never publishes`，退出 1 | PASS |
| UAT-19 | 选择后显式发布 | `fleet publish pf-c --verify "node check.js"` | `main updated from pf-c` | PASS |
| UAT-20 | 发布内容正确 | 读取 `main:/src/value.txt` | `44` | PASS |

### F. 负向与保护

| ID | 目的 | 命令 | 期望 | 本次结果 |
| :--- | :--- | :--- | :--- | :--- |
| UAT-21 | `publish` 必须带验证命令 | `fleet publish some-branch` | `publish needs --verify`，退出 1 | PASS |
| UAT-22 | 不存在的 Branch | `fleet publish nope --verify "node check.js"` | `no Branch named nope`，退出 1 | PASS |
| UAT-23 | 验证期间 head 移动则拒绝 | 慢验证 + 并发写入 | `moved while verifying; nothing published`，退出 1 | PASS |
| UAT-24 | 独立 escript | `./aegisfleet help` | 输出 `aegis fleet` | PASS |

---

## 5. 内核测试明细（`./scripts/test.sh` 的 11 个用例）

这些是 gleeunit 级的可复跑测试，覆盖自动化脚本未逐条展开的底层断言。

| # | 测试 | 断言要点 |
| :--- | :--- | :--- |
| 1 | `bridge_answers_and_traces_fork_test` | `hello`/`branches`/`fork` 正常；`tracer.jsonl` 含 `"layerfs_trace":1` 与 `branch.fork` |
| 2 | `crash_reclaims_workspace_test` | worker 持租约时被杀 → `in_use=0`、`reclaimed≥1`、`snapshot.workspaces=[]` |
| 3 | `capacity_queues_test` | 2 槽位 / 3 worker：第 3 个排队；杀 1 个后其获得租约；最终归零 |
| 4 | `busy_mount_is_retried_test` | 注入 2 次 `Busy` 后 mount 成功，`retries≥2` |
| 5 | `queue_timeout_refuses_waiter_test` | 槽位永不解锁时 waiter 在 250ms 收到 `QueueTimeout`，队列清空 |
| 6 | `race_publishes_winner_only_test` | 显式 `publish: True` 时只有赢家发布；输家在 1s 内被抢占；`main=42` |
| 7 | `race_without_a_verified_candidate_publishes_nothing_test` | 全部失败 → `AllFailed`，`main` 保持 0 |
| 8 | `race_reports_winner_without_publishing_test` | `publish: False` → winner 返回、`main` 仍为 0；调用方手动发布后才变 42 |
| 9 | `portfolio_evaluates_all_before_choosing_test` | 3 个不同实现全部 verified；`main` 仍 0；显式发布 `pf-c` 后变 44；无残留 Workspace |
| 10 | `map_reduce_merges_independent_shards_test` | 两 shard 各自过检、折叠 merge、合并后再过检；显式发布后 `main` 含 A/B |
| 11 | `map_reduce_conflict_publishes_nothing_test` | 同文件冲突 → `MergeFailed` 含 `Conflict`；`main` 无冲突文件 |

---

## 6. 通过标准

P0（必须全部通过，缺一不可）：

1. UAT-01 ～ UAT-24 全部 PASS。
2. 任何拓扑在未显式发布时都不修改 `main`（UAT-05/09/15/17）。
3. 所有发布路径都必须重新验证（UAT-19/21/23）。
4. 所有用例结束后的 `snapshot.workspaces` 为空，或 `fleet status` 显示 `no mounted Workspaces`。
5. 无 `erl_crash.dump`、无未捕获的 `badarg`/`Undef`。
6. 11 个内核测试全绿。

P1（本次不阻塞，但需记录）：Live 模式、DSH GUI、Provider 集成未完成（见 NOT_IMPLEMENTED.md）。

---

## 7. 本次验收结果

```
PASS  UAT-01 clean build
PASS  UAT-02 formatted
PASS  UAT-03 kernel tests (11)
PASS  UAT-04 compile-time gate
PASS  UAT-05 race reports only
PASS  UAT-06 race decision publishes
PASS  UAT-07 race main is 42
PASS  UAT-08 race leaves no Workspace
PASS  UAT-09 map-reduce reports only
PASS  UAT-10 map-reduce decision publishes
PASS  UAT-11 map-reduce main is A/B
PASS  UAT-12 DSH collector contract
PASS  UAT-13 janitor reaps a leaked Workspace
PASS  UAT-14 lfs.js patch applies
PASS  UAT-15 portfolio evaluates all
PASS  UAT-16 portfolio packet
PASS  UAT-17 main untouched
PASS  UAT-18 portfolio refuses --publish
PASS  UAT-19 chosen Branch publishes
PASS  UAT-20 main is 44
PASS  UAT-21 publish requires a verifier
PASS  UAT-22 publish rejects unknown Branch
PASS  UAT-23 head-move guard refuses
PASS  UAT-24 standalone escript runs

acceptance: PASS=24 FAIL=0
```

代表性实测数值（同一台机器，多次运行会波动）：

- Race：3 候选、2 个输家 `sleep 5`，race 总耗时约 **150–240ms**，DOWN 处理 **0–1ms**；
- Portfolio：3 个候选全部验证约 **200–500ms**；
- MapReduce：2 shard + 合并 + 复验约 **110–140ms**；
- 每个用例结束 `[pool] 0/16 Workspaces in use`。

---

## 8. 已知观察（不阻塞）

1. `race` 的抢占是**逻辑抢占**：杀 BEAM worker、丢弃未提交的 Workspace；远端 shell 可能继续跑完，但不可能再 commit/publish。详见 NOT_IMPLEMENTED.md。
2. `fleet publish` 的验证窗口与发布之间仍有极小的外部写入窗口；代码通过“验证后复查 head + 按 Commit id 发布”把它压到最小，但不是分布式事务。
3. `fleet status` 中 `main` 显示 `published layer <id>`，不显示 head（LayerFS 的 main 是 Layer，不是 Branch）。
4. `scripts/uat.sh` 依赖本机 `git`、`node`、`gleam` 与 LayerFS checkout；缺一不可。

## 9. 清理

`scripts/env.sh` 和 `scripts/seed.sh` 创建的都是 `/tmp/aegis-*` 临时目录，可直接删除。验收不会留下 LayerFS 挂载；若中途被 Ctrl-C 打断，执行：

```bash
fleet reap
./aegisfleet status
```

确认无残留 Workspace 后即可。

## 10. 签署

| 角色 | 结论 | 日期 |
| :--- | :--- | :--- |
| 交付方（自动化） | 24/24 PASS | 2026-10-21 |
| 验收方（人工） | ☐ 通过 ☐ 有条件通过 ☐ 不通过 | |
