# ISSUE-28 — codemode 嵌套命令预算传递收口（发现 A）

- **状态**: open
- **发现时间**: 2026-11-19
- **来源**: T-23b 方案（plan.md 遗留发现 A，评审 C1）+ T-23b 实现票真机探针坐实
- **工作量**: 中
- **关联**: ISSUE-23（23a/23b）、ISSUE-29（发现 B，run_command 兼容后端超时结果无输出）

## 现象

注释与文案声称「嵌套 shell 运行拿到 min(requested, remaining)，停滞命令不会活过脚本 deadline」（bridge.zig applyAmbientBudget 注释、tool_runtime.zig ambient 字段注释），对 codemode 嵌套路径不成立：

- `applyAmbientBudget` 塞进去的是整个预算，不是剩余（bridge.zig:58-62；既有测试断言的正是整值 30_000）。
- 减 remaining 的 `effectiveCommandTimeout`（tool_runtime.zig:1936-1957）只在 run_command 兼容后端被用到，而 codemode 嵌套调用被规范化成注册工具 shell（bridge.zig:585-622）。
- 该路径读 `ctx.command_timeout_ms`，从命令自己启动起算（shell.zig:673-676）；`command_timeout_started_ms` 在 bridge.call 的 executeToolCallAuthorized 请求里没有字段，并在 tool_runtime.zig:454 被请求里的 null 覆盖。
- 后果实测：默认 30s 预算的脚本里出现 `run_command: ok (36637ms)` 等超预算记录；T-23b 实现票探针 3 实测 `@options timeout_ms:2000` + `run_command({command:"sleep 8", timeout_ms:60000})` 的实际 elapsed 为 **8077ms**（Timeout after 8077ms, budget 2000ms），坐实脚本自带 timeout_ms 整体覆盖 ambient、预算不随脚本剩余收口。

## 处置

- [ ] 修「命令什么时候死」（执行语义）：决定剩余预算语义（min(requested, remaining) 还是整预算从命令启动起算），同步修正 bridge.zig:52-57 与 tool_runtime.zig:1340-1343 两处注释/文案。
- [ ] 修好后 23b 摘录覆盖面退化为覆盖矩阵第三行（`"error":"TimeoutExpired"` 的快照，仍带 output_delta），摘录照样有内容，无需联动改摘录槽。
- [ ] 23b 已按 plan 修正 builtins/tools.zig 描述文案（净字数缩短），本票落地时无需再改描述。
- [ ] TLA：修执行语义前先开票论证是否触及 recovery 模型边界（23b 方案问 5 结论：本轮不动 tests/tla/recovery/）。
