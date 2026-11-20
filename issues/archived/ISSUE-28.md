# ISSUE-28 — codemode 嵌套命令预算传递收口（发现 A）

- **状态**: closed（2026-11-20）
- **发现时间**: 2026-11-19
- **来源**: T-23b 方案（plan.md 遗留发现 A，评审 C1）+ T-23b 实现票真机探针坐实
- **工作量**: 中
- **关联**: ISSUE-23（23a/23b）、ISSUE-29（发现 B，已关闭归档）、ISSUE-30（搭车已关闭归档）

## 现象

注释与文案声称「嵌套 shell 运行拿到 min(requested, remaining)，停滞命令不会活过脚本 deadline」（bridge.zig applyAmbientBudget 注释、tool_runtime.zig ambient 字段注释），对 codemode 嵌套路径不成立：

- `applyAmbientBudget` 塞进去的是整个预算，不是剩余（bridge.zig:58-62；既有测试断言的正是整值 30_000）。
- 减 remaining 的 `effectiveCommandTimeout`（tool_runtime.zig:1936-1957）只在 run_command 兼容后端被用到，而 codemode 嵌套调用被规范化成注册工具 shell（bridge.zig:585-622）。
- 该路径读 `ctx.command_timeout_ms`，从命令自己启动起算（shell.zig:673-676）；`command_timeout_started_ms` 在 bridge.call 的 executeToolCallAuthorized 请求里没有字段，并在 tool_runtime.zig:454 被请求里的 null 覆盖。
- 后果实测：默认 30s 预算的脚本里出现 `run_command: ok (36637ms)` 等超预算记录；T-23b 实现票探针 3 实测 `@options timeout_ms:2000` + `run_command({command:"sleep 8", timeout_ms:60000})` 的实际 elapsed 为 **8077ms**（Timeout after 8077ms, budget 2000ms），坐实脚本自带 timeout_ms 整体覆盖 ambient、预算不随脚本剩余收口。

## 处置

- [x] 修「命令什么时候死」：语义按用户拍板 **min(requested, remaining)**（remaining = 脚本 deadline − 嵌套调用发起时刻，admission 之前采样）。applyAmbientBudget 改塞 remaining；tool_runtime.zig:454 null 覆盖修复；DispatchContext 增默认 null 标记字段；shell.zig callRun 有标记走 min、无标记 requested-wins 原样。两处不实注释同步修正。（T-27-impl：红 cdc4b24f7 → 绿 8b56f4cd4）
- [x] 23b 摘录覆盖面退化为覆盖矩阵第三行：摘录槽代码零改动，第三行 E2E 断言更新为确定 failure-timeout（TimeoutExpired 快照仍带 output_delta）。
- [x] builtins/tools.zig 描述文案未动（23b 已修）。
- [x] TLA：未触及 recovery 边界，tests/tla/ 零触碰，无需开票论证。

## 修复轮（T-27-review changes-requested → T-27-fix）

评审发现预算边界 timeout/yield 竞争（remaining = 30000−ε 严格小于 yield 30000，旧第三行 E2E 由稳定绿转 33–50% flaky；旧 ok-running 结局恰是本 issue 的 bug 表现）。仲裁选项 (b)：managed_execution 增 yield_waits_for_timeout 标志（默认 false，仅嵌套标记置位），timeout <= yield 时 foreground 等待超时杀，结局确定 stopped/TimeoutExpired；直跑零变化。红 ac740b2d5（6 跑 2 fail 复现竞争）→ 绿 dc8600d6f；第三行 E2E 独立复跑 6/6 全绿。评审发现 2（compat 双重扣减隐患）补警示注释；发现 3（权限等待不吃预算）契约已接受。复审 approve（9ca1f270e）。

## 关闭备注（2026-11-20）

整合于 integrate-issue29 分支（HEAD a6b910d06）：zig build test / fmt / public-surface 全绿，e2e codemode-admission + cli 173 测试 0 fail，FX_BENCH 冒烟干净。真机探针 min 两支验证：remaining 支 2731ms（2000ms 预算杀 sleep 8）、requested 支 1586ms（requested 1500 生效）。
