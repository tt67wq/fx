# ISSUE-19 — turn_finished(.paused) 释放 lifecycle 记录不加 fence，迟到的 progress/terminal 事件杀死整个交互式会话

- **状态**: open
- **发现时间**: 2026-11-16
- **来源**: 交互式会话实测崩溃（session M9m4sqAtN-5_，fx v0.0.16 @ b58759a89）
- **严重度**: 高（一次可恢复的事件时序问题导致整个应用退出，丢失当前会话画面）
- **关联**: tests/e2e/tui-gateway-stream-lifecycle.test.ts:1601/1656 已断言该错误不得出现在 TUI；fa8bb364b（网络/网关失败持续重试）使会话更容易进入重试恢复路径

## 症状

交互式 TUI 会话中途退出，stderr 只有一行：

    fx: UnknownToolLifecycleIdentity

会话日志（~/.fx/sessions/v2/M9m4sqAtN-5_/log.jsonl）显示崩溃前最后一条是
turn_interrupted（reason=cancel，11:22:22.993），随后立即 closed：用户按 Esc
中断，崩溃发生在中断结算期间。

## 定位

### 错误的产生点

src/ui/transcript/runtime.zig 仅三处抛 error.UnknownToolLifecycleIdentity，
关键两处：

- applyProgressLifecycle（runtime.zig:6063）
- applyTerminalLifecycle（runtime.zig:6099）

收到 progress/terminal 事件时若 lifecycle_state 无对应记录且该 turn 未被
fence（turn_id 大于 finalized_turn_watermark 与 batch_finalized_turn_watermark
的较大值），返回错误而不是像 fenced 路径那样 traceLateLifecycleEvent 后吞掉。

### 为什么致命

传播链：drainEvents → applyToolLifecycle（app_worker_runtime.zig:1376/1516，
try）→ tickWithinBudget → tickAgentInContext（main.zig:3274，loopCommitFrame
内）→ event_loop.run → 顶层 reportUnexpectedInteractiveError
（app_entry_runtime.zig:560）打印 "fx: <errorName>" 并退出。事件循环里任何
冒出的错误都是进程退出级别。

### 根因：paused 释放记录但不加 fence

applyTurnFinishedLifecycle（runtime.zig:6283-6294）两个分支行为不对称：

- outcome == .interrupted：只标记取消，记录保留；随后 commitTurnFinished
  （activity_runtime.zig:413）把 batch_finalized_turn_watermark 推进到该
  turn，finishLifecycleBatch 的 commitCleanup（activity_runtime.zig:509）
  删记录时同步推进 finalized_turn_watermark。迟到事件全部被 fence 吞掉，安全。
- outcome == .paused：走 releasePausedTurn（activity_runtime.zig:472），
  直接删除该 turn 的全部记录，不推进任何 watermark。

于是存在致命窗口：记录已删、turn 未 fence。此后该 turn 任何迟到的
progress/terminal 事件命中"无记录 + 未 fence"分支 → 抛错 → 应用退出。

releasePausedTurn 是 ToolActivityState 中唯一一处删除记录却不推进 fence
watermark 的路径。

### 与取消路径的叠加

取消结算时 cancelledEventAdmission（app_worker_runtime.zig:386）只对"取消
标志置位时取出的那批事件"生效：progress 永久丢弃、无记录的 terminal 丢弃。
但 reset_cancel_after_take_events 会在下一次 take 前清掉取消标志，被
defer_until_closure 重新入队的事件及其后缀在下一个 tick 走正常路径重放。
若此时记录已被某次 paused 释放删掉，正常路径没有 admission 保护，直接命中
致命分支。

### .paused 的来源

orchestrator.zig:5267 finishUncertainToolReview：重发请求后无法确认之前的
工具调用是否执行过，turn 以 paused 收尾、checkpoint 保留给用户检查。自定义
网关（dewu/glm-5.3-flash）+ fa8bb364b 的重试改动容易走到该恢复路径。

## 复现要点

1. 交互式会话中触发一次 turn_finished(.paused)（uncertain tool review，
   或 ask/permission 让出），使 releasePausedTurn 删掉当前 turn 的记录；
2. 在同一 turn 内让一个仍在执行的工具后续产生 terminal/progress 事件
   （例如 pause 后仍在收尾的 codemode/shell 执行，或取消重排队后的事件）；
3. 该事件在未置取消标志的 tick 中被正常路径应用 → 崩溃。

日志佐证：抛错前一行有 debug_trace logf "progress/terminal without lifecycle
turn_id"（runtime.zig:6058/6094），开 ui_activity trace 可直接确认触发的
turn_id 与事件类型。

## 修复方向

1. 根因修：releasePausedTurn 释放记录的同时把该 turn 记入 fence（推进
   watermark 或引入 per-turn fence），使迟到事件走既有静默路径；
2. 防御修：progress/terminal 对"无记录且未 fence"不再返回致命错误，改为
   traceLateLifecycleEvent 式吞掉并记日志。e2e 对 scrollback 的既有断言
   （tui-gateway-stream-lifecycle.test.ts:1601）表明设计意图本就是此类
   迟到事件不得致命；
3. 补测试：paused 释放后迟到 terminal/progress 不崩溃、不出现在
   scrollback；覆盖取消重排队后正常路径重放的时序。

建议 1、2 同时落地：1 修根因窗口，2 保证同类问题不再有进程级后果。
