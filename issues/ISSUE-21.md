# ISSUE-21 — codemode 目录预算通知与配置打磨（T-15 复审 F2/F4/F5/F6）

- **状态**: closed
- **发现时间**: 2026-11-17
- **来源**: T-15-impl 复审（review.md @ T-15-review 6a059a98f）非 blocking findings
- **工作量**: 小
- **关联**: ISSUE-15（已关闭，机制已合并 main 40b77a045）

## 现象

ISSUE-15 实现复审指出四条同主题打磨项：目录预算的通知与配置面细节未对齐仓库既有先例。

## Findings（复审原文摘录）

1. **F2 通知地板与实际通知体积不匹配，且通知本身不受预算度量。** catalog_hint 实测 404 B，512 B 地板只剩约 108 B，而一个 omitted 条目序列化后约 58 B，只够 1-2 条。
2. **F4 默认预算 16 KiB 写了两处。** catalog.default_budget_bytes（仅同文件测试使用）与 context_limits.Name.codemode_catalog_bytes 的 defaultBytes 应归一。
3. **F5 通知不提预算键与覆盖方式。** mcp/tool_search.zig:349 与 skill_runtime.zig:3304 的预算通知都写出键名、观测字节、生效字节、来源标签以及 override 方式；codemode 通知应对齐同形。
4. **F6 limit 上限报错文案与实际检查不符且无测试。** searchTools("q", {limit: 100000}) 报 "must be a positive integer"，但 100000 正是正整数。应拆成"必须为正整数"与"超出上限"两条消息并补测试。

## 修复方向

按复审建议集中一张 issue 处理；全部是小改动 + 测试。F5 改动用户可感知的通知文案，属 fx-cli-shape 复核范围（通知文案形态对齐既有两个先例即可，无需新审批）。

## 处置

- [ ] F2 地板按实际通知体积重算（hint 404 B + 若干 omitted 条目余量）
- [ ] F4 默认值单源
- [ ] F5 通知补键名/字节/来源/override（对齐 tool_search.zig:349 先例）
- [ ] F6 limit 报错拆两条消息 + 测试


## 处置

四条全部落地并合入 main（T-21-impl，ec2aeccbe）：F4 默认预算单源于 context_limits；F5 预算通知追加 hint 尾部（observed/effective/source + --context-limit override）；F2 地板 512→1024 并钉哨兵测试；F6 limit 报错拆两条（含 Infinity 与 65536 边界）。独立验证 approve-with-comments（verify.md，T-21-verify cb88db4b4）。方案/报告归档 .agents/tasks/T-21-impl/。
