# ISSUE-30 — backing-null best_effort capture 的收养 store fd 收尾与「活缺口」表述收敛（T-25-review 发现）

- **状态**: open
- **发现时间**: 2026-11-19
- **来源**: T-25-review（fx-pi2，approve 附非阻塞发现），评审对象 fx-pi1@0cf6949e9
- **工作量**: 小
- **关联**: ISSUE-29（T-25-impl 落地）、T-26-impl（同源结论）

## 现象

1. `Capture.ensureReplayBacking`（command_replay_store.zig，T-25-impl 新增）收养的 EphemeralStore 在 backing-null 超时子路径每命令泄漏 1 fd + 1 unlinked /tmp 文件至进程退出：retained fd 无所有者收尾。今日生产不可达（app_agent_runtime.zig:417-423 与 cli_ask 保证 capability 或 ephemeral 至少其一非 null），测试进程退出即回收，不阻塞。
2. T-25-impl 报告中「releaseRetained 关闭句柄」措辞不准确；「活缺口」表述宜收敛为「toolRunCommand 路径（测试/wasi/兼容后端）的契约缺口」。

## 处置

- [ ] Capture 增 owned_store 标志，releaseRetained/discard 时 deinit 收养 store；或该子路径改内联头尾摘录。
- [ ] 修正 impl-report 措辞（或以本票为准记录），必要时补一行代码注释。
- [ ] 与 T-26 核查同源：生产 shell 走 managed_execution，result.command_replay_capture 恒 null，finalizeCommandReplay 在生产为 no-op——若后续重构 touched 该契约，先核本链。
