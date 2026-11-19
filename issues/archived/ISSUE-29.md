# ISSUE-29 — run_command 兼容后端超时结果无输出（发现 B）

- **状态**: closed（2026-11-19）
- **发现时间**: 2026-11-19
- **来源**: T-23b 方案（遗留发现 B，范围按评审 C1 重划）
- **工作量**: 中
- **关联**: ISSUE-23（23b）、ISSUE-28（发现 A）、ISSUE-30（review 非阻塞发现跟进）

## 现象

无 stdout 的超时 stub 只在 run_command 兼容后端：`Command.timeoutFailure` 造的 `model_output` 只有 timeout=true + cleanup 三行，已捕获字节留在 replay capture 里（command_result_mapping.zig:93-124、tool_runtime.zig:2129-2144）。Capture 由调用方负责 retainRequired/abort（command_replay_store.zig:659-676、:773-781），而该 stub 路径不给句柄提示（句柄提示先例：appendModelHandleNotice command_replay_store.zig:22-39 + execution_memory.zig:1239-1260）。

codemode 嵌套调用不经此处（23b 方案问 1 锚点已证），所以 B 不是 23b 的前置，也不影响摘录覆盖率。

另记一处同源隐患：`bridge.call` 不消费 `result.command_replay_capture`（bridge.zig:157-193，ToolExecutionResult 无 deinit，tool_contracts.zig:94-119），若某条嵌套路径确实造出 Capture，其 spool 件无人 abort/retain。

## 处置

- [x] 让 timeoutFailure stub 路径把已捕获字节送到模型（T-25-impl：finalizeCommandReplay 的 best_effort 分支在 .timed_out 时追加句柄提示，与 required 分支对齐；新增 Capture.ensureReplayBacking。红 6ff98fb4a → 绿 0cf6949e9，review approve 983f1d87b）。
- [x] 核 bridge.call 对 result.command_replay_capture 的消费责任（T-26-impl：核查结论——嵌套路径恒 null，无泄漏；补 7 行归属契约注释 0eda7df7f，review approve 27b2e1e27）。
- [x] 归 shell 运行时而非 recovery；tests/tla/ 零触碰，无需 TLA 论证。

## 关闭备注（2026-11-19）

整合于 integrate-issue29 分支（全量 zig build test / fmt / public-surface 全绿，FX_BENCH 冒烟干净）。评审非阻塞发现转 ISSUE-30 跟踪（backing-null 子路径 fd 收尾 + 表述收敛）。
