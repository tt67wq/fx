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

## 失败 2 取证结论（T-17-impl-2，2026-11-16）

### 方法
pinned runner（@modelcontextprotocol/conformance 0.2.0-alpha.10，rev
a9896553900a2ef61787b57adfcbbe936a8ab1f9）直接对 conformance fixture 跑
sep-2322-client-request-state 单场景，带 --verbose --output-dir 保留 check 级
checks.json（绕开 run.ts:33 mkdtemp / :65 finally 删除）。两端：

- macOS 本机（Darwin 27.0.0 arm64，node 26.12.1，bun 1.4.2，macOS fx 二进制）。
- Linux docker（node:22-bookworm，glibc 2.36，node 22.23.5，bun 1.4.4，
  fx 交叉编译 aarch64-linux-gnu Debug；container 内核 6.8.0-100-generic）。

### check 级结果（两端逐字节一致）
2 passed, 3 failed（与 CI 旧 main run 43348575668 的场景级签名一致）：

| check id | macOS | Linux |
| --- | --- | --- |
| sep-2322-client-parallel-isolation | SUCCESS | SUCCESS |
| sep-2322-default-result-type-complete | SUCCESS | SUCCESS |
| sep-2322-client-request-state-echoed | FAILURE | FAILURE |
| sep-2322-client-jsonrpc-id-different | FAILURE | FAILURE |
| sep-2322-client-no-state-omitted | FAILURE | FAILURE |

三个失败项 details.message 均为：
"Tool was not called by client or MRTR flow not completed"

### 结论：真实缺陷（非环境性）
失败在 macOS 与 Linux 完全一致（同 check 集、同 message、同 2/5 比例），
排除 Linux 特有的 I/O/时序差异。这是 client（fx 的 conformance 适配层）对
SEP-2322 MRTR 请求状态记账的确定性缺口：echoed（requestState 回显）、
jsonrpc-id-different（新 JSON-RPC id）、no-state-omitted（未指定状态时省略
requestState）三项 MUST 未满足，且 runner 报的是同一上游症状（MRTR 流未完成
到工具调用），与平台无关。

### 处置（conductor 决策 D3，2026-11-16）

- 已单开 issues/ISSUE-18.md 跟踪修复（含本节证据与复现注意事项 D4）。
- baseline-with-link：expected-failures.yml 已加三项并挂 ISSUE-18。评审3 已
  指出"永久静音"论断自相矛盾，baseline 条目自带到期规则（check 开始通过
  即 CI 红），修复落地后自然强制移除。
