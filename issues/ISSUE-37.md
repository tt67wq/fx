# ISSUE-37 — auto/nudge 压缩阈值锚在窗口百分比上，1M 窗口下永不触发；论证改绝对上界（待立项）

- **状态**: proposed（等待立项）
- **发现时间**: 2026-11-25
- **来源**: ISSUE-27 P2 双 worker 论证（T-37b 反方数据，conductor 只读复跑核实）；P2 裁决的前置一
- **关联模块**: src/core/compactor/settings.zig、window.zig（compactAtTokens/due）、src/core/agent/runtime/orchestrator.zig（nudge）、src/core/config/model_capabilities.zig

## 现象

auto 压缩与 P0 nudge 的触发点都锚在「模型可用输入窗口的百分比」上：

- auto：`auto_compact_percent` 默认 80（settings.zig:8），`compactAtTokens = percentOf(usable, percent)`（window.zig:143-146），`due()` 判 request >= at（window.zig:128-132）。
- nudge：auto 点的 3/4（orchestrator.zig:6353-6377，常量写死）。
- usable 由窗口减输出预留得出（model_capabilities.zig:213 requestOutputTokens）。

主力模型全是 1M 窗口时，阈值被推到 697K-812K（nudge 523K-609K），真实用量永远够不着。

## 数据（143 session / 4812 请求 / 17 天，2026-11-06 至 11-25）

脚本在 .agents/tasks/T-37b/（scan/thr/comp/mix.py，本地不入库），conductor 复跑全 exit 0。

| 指标 | 实测 |
|---|---|
| auto 阈值命中 | 0 / 143 session |
| P0 nudge 命中 | 1 / 143 |
| 压缩事件 | 4 次，全部用户手动（Origin=manual） |
| 手动压缩时的峰值占 auto 阈值 | 14%、47%、65% |
| provider overflow | 0 |
| 每请求 prompt | p50 70.9K / p90 346K / p99 507K / 最大 557K |
| 各模型峰值占 auto 阈值 | qwen4-max 0.80 / glm-5.3-flash 0.61 / MiniMax-M3.1-Flash 0.36 / kimi-for-coding 0.26 |

推论：用户凭成本与延迟直觉在远未到阈值时就压了；宿主侧两级确定性触发器几乎不发力。「何时该压」的真实判据是绝对规模（成本/延迟），不是窗口占用率。

数据边界：单一开发者机器、17 天，结论限定为现有用法，非全称否定。size.request_tokens 是 fx 估算值，若偏低只会让 auto 更难触发，结论方向不变。

## 方案空间（立项后先论证再选）

| 方案 | 形状 | 顾虑 |
|---|---|---|
| A 绝对 token 上界 | 新 profile 设置如 auto_compact_tokens（0=沿用百分比），取 min(百分比点, 绝对点) | 命名与 auto_compact_percent 的关系要过 fx-cli-shape；两键并存语义要钉死 |
| B 成本上界 | 按 provider 计价的每请求成本阈值 | 计价数据可得性未核；比 A 复杂 |
| C 调低默认 percent | 零新面 | 对小窗口模型误伤（80%→30% 在 128K 窗口上过早压）；治标 |
| D 按模型分档默认 | model_metadata 加 per-model 阈值 | 面扩大，维护成本高 |

倾向 A：一处配置解释全部 4 次真实压力事件；不动 compactor front door 契约、不加模型面、不交契约哈希税。nudge 跟随同一锚点（3/4 关系保留）。

## 边界与不做的事

- 不改 window.choose 选段逻辑、不动 checkpoint 格式、不碰模型面工具。
- compactor 边界：settings/window 都在模块内，外部仍只经 compactor.zig；预计 check-compactor-boundary.sh 零改动。
- overflow 恢复路径不动，仍是最后兜底。
- 与 ISSUE-27 P2 的关系：本 issue 是 P2 的前置一；若 A 落地后压力事件被 auto 覆盖，P2 的需求论证进一步减弱。

## 需要维护者确认

1. 是否立项，及方案取向（A/B/C/D）。
2. 若 A：键名与两键并存语义（min？绝对优先？percent 废弃路径？）走 fx-cli-shape 评审。
3. 默认绝对值定多少（数据支持 ~300K-400K 一带已有真实压力，但要考虑小窗口模型不受影响）。

## 处置

- [ ] 维护者立项并定方案取向
- [ ] fx-cli-shape 评审新设置（若 A）
- [ ] TDD 实现 + 单测（阈值解析/min 语义/nudge 跟随）
- [ ] e2e：构造大窗口低占用场景验证 auto 触发
- [ ] 构建二进制真机验证（AGENTS.md 就绪门槛）
- [ ] 文档：--help / settings schema / fx.sh 手册页同步

## 验证状态

代码锚点已核实（行号见上）；数据脚本 conductor 只读复跑通过。方案未实现，未编译任何改动。
