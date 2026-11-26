# ISSUE-40 — read_tool_result 被截断提示和 codemode 描述推荐，但沙箱内不可达，25 次失败 / 24 个 session

- **状态**: open（待立项）
- **发现时间**: 2026-11-26
- **来源**: 全量 169 个 session 日志分析（11-19 后本类 25 次失败 / 24 个 session，最新 2026-11-26；本轮分析自身也实犯一次）
- **关联模块**: src/builtins/tools.zig:717-719（read_tool_result spec，internal=true 且无 sandbox_reachable）、src/tools/codemode/bridge.zig:1440（derivedFace 只放行 sandbox_reachable）、src/core/session/result_store.zig:463（截断提示文案）、src/builtins/tools.zig:745（codemode_description "read_tool_result reads the full output"）

## 现象

输出超预算时 fx 给模型的指引是：

```
Full result is stored outside session JSON. Use read_tool_result with this handle to inspect a byte range or literal query.
```

codemode 描述也写 "read_tool_result reads the full output"。但在 codemode 沙箱内：

1. read_tool_result 标记 `internal = true` 且未标 `sandbox_reachable`，不在 derivedFace（bridge.zig:1440）；
2. searchTools 索引建在同一个 face 上，**搜不到它**（"use searchTools to discover tools" 的兜底建议也失效）；
3. 模型照提示调用 → `unknown codemode tool: read_tool_result. did you mean: read_file, ...`，did-you-mean 全是无关工具。

结果：脚本内拿到截断输出后**没有任何合法途径读全文**，只能重跑命令或换 grep 缩小输出，浪费调用且可能重复副作用。

## 修法

方向二选一：

1. **A 放开可达**（倾向）：read_tool_result 加 `sandbox_reachable = true`（只读、requires_approval=false，权限面无新增风险）。同步核对 catalog 十 schema 哨兵测试（catalog.zig:233 一带）与目录字节预算。
2. **B 改提示**：截断提示与 codemode 描述改为"结束脚本后在下一轮直接调 read_tool_result"。零代码风险但多一轮往返，脚本内多步工作流仍断链。

注意 internal=true 的语义（不进模型默认工具面）与 sandbox_reachable 是否互斥需要先确认；若互斥，A 需要拆成两个正交开关。

## 处置

- [ ] 确认 internal 与 sandbox_reachable 的关系
- [ ] 决策 A/B（倾向 A）
- [ ] 落地 + face/schema 哨兵测试更新
- [ ] 观察指标：下轮 session 分析 unknown codemode tool: read_tool_result 是否归零

## 性价比排名（2026-11-26）

第 1 / 6。25 次失败散布 24 个 session，波及面最广；A 方案是 spec 一个 flag 级改动，只读工具风险低。建议最先施工。
