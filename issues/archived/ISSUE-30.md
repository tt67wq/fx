# ISSUE-30 — backing-null best_effort capture 的收养 store fd 收尾与「活缺口」表述收敛（T-25-review 发现）

- **状态**: closed（2026-11-20）
- **发现时间**: 2026-11-19
- **来源**: T-25-review（fx-pi2，approve 附非阻塞发现），评审对象 fx-pi1@0cf6949e9
- **工作量**: 小
- **关联**: ISSUE-29（T-25-impl 落地，已关闭归档）、ISSUE-28（同轮整合）、T-26-impl（同源结论）

## 现象

1. `Capture.ensureReplayBacking`（command_replay_store.zig，T-25-impl 新增）收养的 EphemeralStore 在 backing-null 超时子路径每命令泄漏 1 fd + 1 unlinked /tmp 文件至进程退出：retained fd 无所有者收尾。今日生产不可达（app_agent_runtime.zig:417-423 与 cli_ask 保证 capability 或 ephemeral 至少其一非 null），测试进程退出即回收，不阻塞。
2. T-25-impl 报告中「releaseRetained 关闭句柄」措辞不准确；「活缺口」表述宜收敛为「toolRunCommand 路径（测试/wasi/兼容后端）的契约缺口」。

## 处置

- [x] Capture 增 owned_store 标志 + deinitOwnedStore，三终结路径（abort / discard / releaseRetained 的 .retained 分支，置 .consumed 前、deleteSpool 后）收尾收养 store；幂等，运行时提供的 backing 不动。（T-28-impl：红 972fb14f5 → 绿 82a58eeb4，review approve 65a10740a）
- [x] T-25 impl-report 措辞修正（releaseRetained/abort 原本不关 store fd 的准确描述 + 残留条目）；「活缺口」收敛为 toolRunCommand 路径契约缺口。（报告 commit bc58a5eb9）
- [x] 与 T-26 核查同源结论保持一致：生产 shell 走 managed_execution，result.command_replay_capture 恒 null，finalizeCommandReplay 在生产为 no-op；ensureReplayBacking 注释已说明。

## 关闭备注（2026-11-20）

整合于 integrate-issue29 分支（HEAD a6b910d06）：zig build test / fmt / public-surface 全绿，FX_BENCH 冒烟干净。
