# T-25-impl 实现报告

> T-28 修正：本文「偏差与已知限制」与「为什么覆盖真实缺口」两节措辞已按 ISSUE-30 收敛，
> 见各节内 T-28 标注。收养 store 的 fd 收尾由 T-28 落地（owned_store 终结路径 deinit）。

## 修法选择

候选 A。改动两点，均在 finalize 层，零执行语义变更：

1. `src/core/session/command_replay_store.zig`：新增 `Capture.ensureReplayBacking`。
   backing 为 null 且 state 为 `.buffered` 时，捕获惰性收养一个 capture 自有的
   `EphemeralStore`（arena 生命周期，/tmp 无链 spool 文件，复用现有
   abort/discard/deleteSpool 清理路径），使 `retain()` 可以物化描述符而不是退回
   `.unavailable`。失败静默降级，与既有 best_effort 行为一致。
2. `src/core/agent/runtime/execution_memory.zig` `finalizeCommandReplay`：
   required 分支之后，当 `prepared.memory.command_process_presentation == .timed_out`
   时先 `ensureReplayBacking`；7 处 best_effort `retainCommandReplay` 调用点统一改为
   新助手 `retainBestEffortReplay`，在 timed_out 且 retain 结果为 `.available` 时追加
   `appendModelHandleNotice` 句柄提示并同步 `stored_output_bytes`，与 required 分支
   （execution_memory.zig:1250-1262 一带）逐行对齐。notice 追加失败按 best_effort 静默跳过。

未改：`commandReplayPolicy` 决策表、超时杀树与工具失败语义、admission/permissions、
tests/tla/。无新 CLI 面 / settings 键 / 环境变量。

## 为什么覆盖真实缺口

真实运行时（TUI 经 `managed_executions.replayStore()`，`fx ask` 经 ephemeral 兜底）
capability 与 ephemeral store 至少其一非 null，backing 非 null；此前 best_effort 超时
已能 retain 为 `.available`，但 finalize 的 best_effort 分支从不追加句柄提示，模型
拿不到句柄——这是本修复补上的契约缺口（T-28 表述收敛：限定为 toolRunCommand 路径，
即测试/wasi/兼容后端；生产 shell 走 managed_execution，result.command_replay_capture 恒 null，
finalizeCommandReplay 在生产为 no-op，与 T-26 核查同源）。backing null 子路径（无 store 的
极简运行时）此前连 retain 都失败；ensureReplayBacking 让它也能物化并通过测试契约。

## 偏差与已知限制

- backing null 时句柄提示指向 capture 自有的 ephemeral store，而 read_tool_result 读的是
  运行时级 `ctx.ephemeral_command_replay`；在真正无 store 的运行时里句柄仍不可读
  （该运行时 read_tool_result 本就没有 store）。当前 fx 自带运行时不会进入此子路径。
- capture 自有 store 的保留文件句柄收尾（T-28 修正）：原表述「仅在 discard/abort/releaseRetained
  时关闭」不准确。discard 经 deleteSpool 关闭 spool fd；但 releaseRetained 只 free 描述符
  handle 字符串、abort 在 .retained 态为空操作，二者均不关闭收养 store 映射里保留的 fd。
  T-28 为 Capture 增 owned_store 标志，并在 abort/discard/releaseRetained 全部终结路径
  deinit 收养的 store，关闭其全部 fd 并释放结构。arena 只回收内存、不关 fd，故收尾必须显式。
  与运行时级 ephemeral store 一样不引入新的跨会话持久化。
- 残留（T-28 记录，生产不可达）：成功 retain 并发布后，orchestrator 置 replay_handed_off=true，
  其 defer 跳过 discard，且无任何 releaseRetained 调用——capture 停在 .retained，收养 store
  的 fd 直到进程退出才回收。该「无终结调用」的交接路径不属于 Capture 终结路径，需在
  orchestrator 侧对 owned_store capture 补一次 releaseRetained/discard 才能彻底关闭，
  属后续票（今日生产不可达：app/ask 恒有 capability 或 ephemeral，ensureReplayBacking 恒 no-op）。

## 证据

1. 红测试转绿：`zig build test` 全绿（含
   `core.tooling.tool_runtime.test.no-save timeout command surfaces captured output to the model`，
   先红 commit 6ff98fb4a 后绿）；单次跑完，无 flake 复跑。
2. `zig fmt --check src/` 退 0。
3. `cd tests/e2e && FX_SOUND=0 bun test cli.test.ts`：139 pass / 6 skip / 0 fail。
4. `scripts/check-public-surface.sh`、`check-agents-boundary.sh`、
   `check-compactor-boundary.sh`、`check-indexer-boundary.sh`、
   `check-recovery-boundary.sh` 各退 0。
5. 真机冒烟：`FX_BENCH=1 ./zig-out/bin/fx` 退 0、stderr 0 字节；
   `FX_BENCH=1 ./zig-out/bin/fx help` 退 0。
