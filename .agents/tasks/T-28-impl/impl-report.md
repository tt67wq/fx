# T-28-impl 实现报告 — ISSUE-30 收养 store fd 收尾 + 表述收敛

- 实现者：fx-pi2。分支 T-28-impl，基线 integrate-issue29 HEAD 0323b5f35。
- 红 commit：972fb14f5（先于绿）；绿 commit：82a58eeb4（收尾实现）+ 文档 commit（本报告与措辞）。
- Issue：issues/ISSUE-30.md（T-25-review 两条非阻塞发现）。

## 一、fd 收尾（TDD）

### 终结路径核清（动手前）
Capture 的状态机终结（.consumed）路径共三条，全部覆盖：
- abort：buffered/streaming/sealed_file/unavailable/retained 各态清理后置 .consumed（.consumed 早返回）。
- discard：.retained 经 deleteSpool+free 置 .consumed；其余态转 abort。
- releaseRetained：.retained 经 free(handle) 置 .consumed；.consumed 空操作；其余态转 abort。
- makeUnavailable 置 .unavailable（非终结消费），其 streaming/sealed_file 分支已经 deleteSpool 关闭 spool fd；后续 abort/discard/releaseRetained 再收尾。失败路径（materializeInline/promoteAndAppend 的 errdefer）亦经 deleteSpool 关闭 fd，故 .unavailable 不遗留 open fd。

### 缺陷
ensureReplayBacking 收养的 EphemeralStore 是 capture 自有的匿名对象，无外部所有者。retain 成功后 spool 的 dup fd 留在 store.files 映射里：
- discard 经 deleteSpool 关闭它（原本正确）；
- releaseRetained 只 free 描述符 handle 字符串，不关 store fd（泄漏）；
- abort 在 .retained 态为空操作，不关 store fd（泄漏）。
arena.deinit 只回收内存、不关 fd，故被收养 store 的 fd 泄漏至进程退出。

### 修法（评审建议，微调）
- Capture 增 owned_store: bool = false；ensureReplayBacking 收养时置 true。
- 新增私有 deinitOwnedStore(self, alloc)：owned_store 为 true 时 store.deinit()（关闭映射内全部 fd 并 free key）+ alloc.destroy(store)，置 owned_store=false、backing=null。幂等：运行时提供的 backing（owned_store=false）不动；二次调用空操作。
- 在三条终结路径的 .consumed 转换前调用 deinitOwnedStore，且排在 deleteSpool 之后（先从映射移除 spool handle，再 deinit store）。
- 不改 retain/retainRequired/finalizeCommandReplay 的任何行为；不改执行语义；admission/permissions/catalog/tests/tla 零触碰。

### 红绿
- 红（972fb14f5）：command_replay_store.zig 增 3 个测试 + adoptedStoreOpenFiles 判据（收养 store 映射 open fd 数）。
  - adopted replay backing closes its spool on releaseRetained：retain 后 fd=1，releaseRetained 后断言 fd=0 → 红（expected 0, found 1）。
  - adopted replay backing closes its spool on abort：同上 → 红（expected 0, found 1）。
  - adopted replay backing closes its spool on discard：原本绿（deleteSpool 已关）。
  - 实测红：zig build test EXIT=1，20/22 steps（1 failed），10275/10284 passed（2 failed）。证据 .agents/tasks/T-28-impl/red-evidence.txt。
- 绿（82a58eeb4）：owned_store + deinitOwnedStore + 三终结路径调用。3 测试转绿（含幂等二次调用断言）。

### 残留（诚实记录，生产不可达，建议后续票）
成功 retain 并发布后，orchestrator 置 replay_handed_off=true，其 defer 跳过 discard，且全仓无任何对 execution.command_replay_capture 的 releaseRetained 调用——capture 停在 .retained，收养 store 的 fd 直到进程退出才回收。该「无终结调用」的交接路径不属于 Capture 终结路径，本票红线（只动 Capture 收尾、不动 finalize/orchestrator）无法在 Capture 内关闭它。彻底修复需在 orchestrator 交接处对 owned_store capture 补一次 releaseRetained/discard（交接假设会话拥有 replay，而 owned_store 无会话所有者）。今日生产不可达：app_agent_runtime.zig:417-423 与 cli_ask:1934 保证 capability 或 ephemeral 至少其一非 null，ensureReplayBacking 恒 no-op；且生产 shell 走 managed_execution，result.command_replay_capture 恒 null（T-26 同源）。本票修复的是「终结路径被调用时」的 fd 泄漏（releaseRetained/abort 确为真实缺陷），交接残留另行开票。

## 二、表述收敛（文档）
.agents/tasks/T-25-impl/impl-report.md（本工作树副本，git -f 入库）：
- 「capture 自有 store 的保留文件句柄仅在 discard/abort/releaseRetained 时关闭」→ 修正为准确描述（releaseRetained/abort 原本不关 store fd，T-28 终结路径 deinit 修复），并补残留条目。
- 「活缺口」→ 收敛为「toolRunCommand 路径（测试/wasi/兼容后端）的契约缺口」，注明生产 shell 走 managed_execution、finalize 在生产 no-op、与 T-26 同源。
- ensureReplayBacking 补注释：生产恒 no-op、收养 store 归 capture 所有（owned_store）并在终结路径 deinit、无终结交接残留见 ISSUE-30。

## 三、验收证据
1. 红先于绿（972fb14f5 → 82a58eeb4），红实测失败留证（red-evidence.txt）。zig build test 全绿：独立 --cache-dir /tmp/t28-cache 全量重跑，22/22 steps succeeded，10020/10022 passed（2 skipped，0 failed）。首轮绿曾遇 1 例无关 flake（core.execution.command_runner.test.runtime cancellation observed at the timeout deadline stays graceful，failed without output），复跑即绿，与本改动无关（不涉及 command_replay_store）。
2. zig fmt --check src/ 退 0。
3. bash scripts/check-public-surface.sh 退 0；scripts/check-agents-boundary.sh 退 0（另 compactor/indexer/recovery 边界各退 0）。
4. 产物：红/绿 commit + 本报告 .agents/tasks/T-28-impl/impl-report.md + red-evidence.txt + T-25 报告修正。
5. 真机冒烟：FX_BENCH=1 ./zig-out/bin/fx help 退 0、stderr 0 字节。

## 四、红线自查
- 只动 Capture 收尾（owned_store/deinitOwnedStore/三终结路径）与注释/报告措辞；retain/retainRequired/finalizeCommandReplay 行为未动；执行语义未改。
- admission/permissions/catalog/tests/tla 零触碰（diff 仅 command_replay_store.zig + 文档）。
- 无新 CLI 面/settings 键/环境变量；无个人路径。
- zig fmt 后提交。
