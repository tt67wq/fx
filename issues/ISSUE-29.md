# ISSUE-29 — run_command 兼容后端超时结果无输出（发现 B）

- **状态**: open
- **发现时间**: 2026-11-19
- **来源**: T-23b 方案（遗留发现 B，范围按评审 C1 重划）
- **工作量**: 中
- **关联**: ISSUE-23（23b）、ISSUE-28（发现 A）

## 现象

无 stdout 的超时 stub 只在 run_command 兼容后端：`Command.timeoutFailure` 造的 `model_output` 只有 timeout=true + cleanup 三行，已捕获字节留在 replay capture 里（command_result_mapping.zig:93-124、tool_runtime.zig:2129-2144）。Capture 由调用方负责 retainRequired/abort（command_replay_store.zig:659-676、:773-781），而该 stub 路径不给句柄提示（句柄提示先例：appendModelHandleNotice command_replay_store.zig:22-39 + execution_memory.zig:1239-1260）。

codemode 嵌套调用不经此处（23b 方案问 1 锚点已证），所以 B 不是 23b 的前置，也不影响摘录覆盖率。

另记一处同源隐患：`bridge.call` 不消费 `result.command_replay_capture`（bridge.zig:157-193，ToolExecutionResult 无 deinit，tool_contracts.zig:94-119），若某条嵌套路径确实造出 Capture，其 spool 件无人 abort/retain。

## 处置

- [ ] 让 timeoutFailure stub 路径把已捕获字节送到模型（句柄提示或头尾摘录，对齐 ISSUE-12 先例）。
- [ ] 核 bridge.call 对 `result.command_replay_capture` 的消费责任，补 abort/retain 归属。
- [ ] 该改动属 shell 执行生命周期，归 shell 运行时而非 recovery；若需动 TLA 先开票论证。
