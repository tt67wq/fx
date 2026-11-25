# ISSUE-38 — auto_compact_tokens 绝对 cap 无下限，小值会塌掉折叠后保留预算（T-38-review F1）

- **状态**: closed（2026-11-25 修复随 ISSUE-37 合入 main，merge 227e6a297；地板 min_tokens=50_000 clamp + R1 env 覆盖过滤；终审 approve、独立测试全项 PASS。非阻塞尾巴 N1-N3/R5 见 fx-pi2 分支 review.md/test-report.md，下次改动带走）
- **发现时间**: 2026-11-25
- **来源**: T-38-review（fx-pi2，changes-requested，评审对象 effb1d132）；conductor 已核 window.zig:93/118 确认 compact_at_tokens 同时是 afterTokens/compactedTokens 的锚
- **关联模块**: src/core/compactor/window.zig（compactAtTokens）、settings.zig、src/core/config/settings_keys.zig

## 现象

ISSUE-37 方案 A 的 compactAtTokens 对 percent 有 min/max 夹逼（10-80），对 tokens cap 只有 >0 检查。但 compact_at_tokens 不只决定触发时机，还决定折叠后保留预算：

- afterTokens = min(compact_at/2, usable*20%)（window.zig:93-101）
- compactedTokens 按 compact_at/2（window.zig:118-126）

1M 窗口模型代入：cap=300K 时保留预算降到 0.86 倍；cap=100K 降到 0.29；cap=1000 时 afterTokens=500，auto 每轮 due 且 /compact 几乎清空会话。用户误填小值（如把 1000 当 1000K）后果严重。

契约「minimum 0 无上限」是设计缺口，非实现偏离。

## 修法（conductor 已定）

仿 min_percent 模式：settings.zig 加 min_tokens 常量与 isValidTokens；compactAtTokens 对 cap 做下限夹逼（低于地板按地板走，不是拒绝——与 percent 的 clamp 行为一致）；config/schema/cli set 校验同步 minimum；红测试钉住「cap 低于地板按地板」。设置 description 写明「cap 同时决定折叠后保留预算」。

地板值 conductor 定 50_000（保证 afterTokens >= 25_000，高于任何合理 fixed_tokens；数据上真实压力峰值 p50 70.9K，50K 地板不影响 ISSUE-37 的目标场景）。

## 随同修复（review 非阻塞项，同一轮带走）

- F2：validateKnownSettingsObject 加 auto_compact_tokens 分支（与 auto_compact_percent 对称，3 行 + 测试）。
- F3：orchestrator decision trace 参数表补 config.auto_compact_tokens。
- F6：compactAtTokens 文档注释补 cap 语义。
- F7：加一条 compactionSize 组合链路测试（断 cap 透传到 compact_at_tokens）。
- F4/F5 不做：u32 收窄与 0 哨兵路由是形状变更，另议。

## 处置

- [ ] 红测试（conductor）
- [ ] 修复实现（fx-pi1，T-38-fix）
- [ ] 重审（fx-pi2）
- [ ] 独立测试 + 真机（fx-pi2，T-38-test）
