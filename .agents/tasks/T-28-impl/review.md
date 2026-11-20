# T-28-review — 收养 store fd 收尾与表述收敛评审

- 评审者：fx-pi1（未参与 T-28-impl 实现，作者独立性成立）
- 所核 commit：红 972fb14f5cc7dd554bf1d3645076e88e505b86af，绿 82a58eeb4abc1e53ecd539c79eeedd9e7484891e，文档 bc58a5eb9eec51b6f007a8659cd1f689949eed92（fx-pi2 分支 T-28-impl，基线 integrate-issue29@0323b5f35）
- verdict：**approve**

## 1. 收尾完备性 — 成立

- 终结路径核清独立复核：Capture 置 .consumed 的路径恰为 abort（:829）、discard 的
  .retained 分支（:842）、releaseRetained 的 .retained 分支（:855）；discard/releaseRetained
  其余态均转 abort，.consumed 早返回/空操作。三处均在置 .consumed 前调用
  deinitOwnedStore，且排在 deleteSpool 之后（先移映射再 deinit store），覆盖完整。
- makeUnavailable 置 .unavailable 非终结消费，其 streaming/sealed_file 分支已
  deleteSpool 关 fd；后续任一终结调用再 deinitOwnedStore，无遗漏。
- 幂等性：deinitOwnedStore 先置 owned_store=false 再取 backing；二次调用
  owned_store=false 直接返回。运行时提供的 backing（owned_store=false）完全不动。
  红测试对三条路径各做了二次终结调用断言，绿后通过。
- 悬空引用：deinit 后 backing=null、owned_store=false。此后 deleteSpool 遇
  backing null 早返回（:885），canonicalizeForComparison/retain 对 .consumed 态
  返回 null/空，无解引用已销毁 store 的路径。adoptedStoreOpenFiles 判据读
  backing null 返回 0，测试自身亦安全。
- 唯一残留（报告已诚实记录，非阻塞）：成功 retain 并发布后 orchestrator 置
  replay_handed_off=true 跳过 discard，且生产代码无对 execution.command_replay_capture
  的 releaseRetained 调用（独立 grep 证实：releaseRetained 的生产调用点仅
  managed_execution 三处，其余为测试）。capture 停 .retained，收养 store fd 留到
  进程退出。该路径不属 Capture 终结路径，本票红线不动 orchestrator，归 ISSUE-30
  后续票合理；今日生产不可达（app/ask 恒有 capability 或 ephemeral，
  ensureReplayBacking 恒 no-op；生产 shell 走 managed_execution，T-26 同源）。

## 2. 红绿链 — 成立（评审者独立复跑红）

- 判据：adoptedStoreOpenFiles = 收养 store.files.count()（open spool fd 数），
  retain 后断言 1、终结后断言 0。确定性：无时钟/网络依赖，纯 fd 计数。
- 独立复核：git worktree 检出 972fb14f5，zig build test 实测
  releaseRetained 与 abort 两测试 "expected 0, found 1" 红；discard 原本绿
  （deleteSpool 已关）。与 red-evidence.txt 一致。
- 绿 82a58eeb4：owned_store + deinitOwnedStore + 三终结路径调用，纯增量 26 行。
  评审者自跑主测试二进制：10020 passed / 2 skipped / 0 failed，三个 adopted
  测试逐条 OK（含幂等二次调用）。

## 3. 语义零变化 — 成立

- diff 0323b5f35..bc58a5eb9 仅 command_replay_store.zig（+106，纯增量无删行）
  与三个文档；execution_memory.zig、tooling/ 零 diff。
- ensureReplayBacking 收养条件（backing null ∧ .buffered）未改；retain/retainRequired/
  finalizeCommandReplay 行为未动；required/best_effort finalize 分支不受影响。
- 运行时级 store（capability/ephemeral）owned_store=false，deinitOwnedStore 对其
  恒空操作，生命周期不受影响。

## 4. 表述收敛 — 准确

- T-25 报告「releaseRetained 关闭句柄」原表述确不准确：releaseRetained 只 free
  描述符 handle 字符串、abort 在 .retained 态空操作，二者原本不关收养 store fd。
  修正后描述与代码事实一致（discard 经 deleteSpool 关；T-28 三路径 deinit）。
- 「活缺口」收敛为「toolRunCommand 路径（测试/wasi/兼容后端）的契约缺口」，注明
  生产 shell 走 managed_execution、result.command_replay_capture 恒 null、
  finalizeCommandReplay 生产 no-op，与 T-26 核查结论逐条吻合。
- ensureReplayBacking 新增 4 行注释（生产恒 no-op、owned_store 归属、ISSUE-30
  残留）与实现一致。

## 5. 机械核验（评审者自跑，fx-pi2 checkout）

1. zig build test：主测试二进制完整跑 10020 passed / 2 skipped / 0 failed（EXIT=0）。
2. zig fmt --check src/：FMT=0。
3. bash scripts/check-public-surface.sh：SURFACE=0；scripts/check-agents-boundary.sh：AGENTS=0。

## 6. 红线核对

- tests/tla/ 零触碰（diff name-only 计数 0）；admission/permissions/catalog 零触碰
  （diff 仅 command_replay_store.zig + 文档）。
- 无新 CLI 面/settings 键/环境变量；无个人路径（diff  grep 个人 home 前缀为空）。

## 备注（非阻塞）

- 评审者红复跑时另见 command_runner「runtime cancellation observed at the timeout
  deadline stays graceful」flake（failed without output），与 impl-report 首轮绿
  遇到的同名 flake 一致，与本改动无关（不涉及 command_replay_store），复跑即绿。
- ISSUE-30 交接残留建议后续票在 orchestrator 交接处对 owned_store capture 补
  releaseRetained/discard；本票范围内处理正确。
