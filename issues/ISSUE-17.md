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
