# ISSUE-17 — fork main 三个 CI 失败为既有问题（非 ISSUE-14 引入）

- **状态**: open
- **发现时间**: 2026-11-13
- **来源**: PR #2 CI 分诊（run 43364009093 @ 681cc5f8 对照旧 main run 43348575668 @ 13713b9b）
- **工作量**: 中
- **关联**: PR #2（ISSUE-14）；两轮失败集合完全一致

## 失败项与初步定位

1. **Build & Test (ReleaseSafe)**：command_effect shell parity 测试
   "planner native printf forms match shell-visible execution"，linux target 下
   printf '%s' '--help' native 与 shell 输出不一致。本 PR 分支未触碰
   src/core/shell_command/。本地（macOS）该套件全绿，疑为 Linux 环境相关。
2. **E2E (MCP conformance)**：sep-2322-client-request-state 场景 3 项失败，
   不在 expected-failures baseline。本 PR 未触碰 src/mcp/。
3. **E2E (deterministic, shard 4/4)**：codemode-admission.test.ts:204
   "nested run_command is killed when the codemode script budget expires"，
   CI 两次尝试均 ~30s 超时（kill 未按时发生）。本地 3 连跑全绿（37-41s/轮），
   疑为 CI 慢环境时序敏感；本 PR 虽在 codemode 目录有改动，但未触碰
   ambient budget 与中断轮询逻辑。

## 处置方向

- 各项独立修复：1、2 需在 Linux 环境复现；3 可从放宽 CI 侧时限断言或
  排查中断轮询的慢路径入手。
- PR #2 的 ready 条件按 AGENTS.md 依赖 CI 全绿；若三项短期无法修复，
  可考虑先把修复 PR 拆出单独跑，或在 fork 上确认 baseline 后调整预期。

## 失败 2 取证结论（T-17-impl-2）

跨平台取证（macOS arm64 ReleaseSafe 本机 + node:22-bookworm 容器）check 级结果逐字节一致，三项 MUST（request-state-echoed / jsonrpc-id-different / no-state-omitted）均报 "Tool was not called by client or MRTR flow not completed"：**真实缺陷，非环境性**。已单开 issues/ISSUE-18.md 跟踪修复；处置采用 baseline-with-link（expected-failures.yml 加三项并挂 ISSUE-18，条目随修复通过自到期强制移除）。复现注意事项（D4）记录在 ISSUE-18。

## 处置

- 失败 1（printf 词形守卫）：T-17-impl-1 修复（红 ba42135c4 / 绿 947c25785 / 注释 cde032e6e），复审3 approve-with-comments，走 type:bug PR。
- 失败 3（e2e 超时）：T-17-impl-2 修复（cf6a83796 / 注释 effe3342c），复审3 approve 并背书 code 断言偏离，走 type:maintenance PR。
- 失败 2（conformance）：取证定案真实缺陷，转 issues/ISSUE-18.md + baseline-with-link。
