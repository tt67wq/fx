# T-26-impl 实现报告 — bridge.call 对 result.command_replay_capture 的消费责任核查

- 分支：fx-pi2（起点 main e9448eaed）
- Issue：issues/ISSUE-29.md 处置项 2（同源隐患）
- 结论：**核查支（任务第 2 支）**。当前代码中没有任何经 bridge.call 的嵌套路径能造出非 null 的 ToolExecutionResult.command_replay_capture；生产嵌套 shell 的 capture 由 managed execution 运行时自持自清。不改执行语义，仅在 bridge.call 消费点补归属契约注释。

## 一、核查表：能产生或传递 command_replay_capture 的入口

字段唯一写入点：`finishCommandToolResult`（src/core/tooling/tool_runtime.zig:2368 `owned.command_replay_capture = capture`），只被 `toolRunCommand`（:2030）调用。`toolExecutionResultFromDispatch`（:1478-1508）与 file_mutation、vision、subagent、MCP、ask_user_question 各路径均不写该字段（全仓 grep 仅 :2368 与测试 support.zig:1543 两处赋值）。

| # | 入口 | 会否造出非 null capture | 谁消费 | 谁清理 |
|---|------|------------------------|--------|--------|
| 1 | bridge.call → executeToolCallAuthorized（bridge.zig:158，request 不传 command_replay_capture）→ executeRegisteredTool → 生产 shell.call → callRun（shell.zig:614-700）→ managed_execution.startCaptured | 否（结果字段恒 null）。capture 造在 managed_execution.zig:258/:315 的 entry.replay_capture，不上 ToolExecutionResult | managed 运行时自己：finalizeReplayLocked（managed_execution.zig:493-507）retain 后 releaseRetained；结果经 tool_result_memory.command_output_replay + command_result_json.output_file 句柄传递（shell.zig:1533-1577） | Entry.deinit（:374）与 clearAuthorityLocked（:1381-1384）releaseRetained；artifact 文件是会话态，由句柄引用，bridge 的 result_commit.commit()（bridge.zig:177-180）触发 tombstone 回收执行槽 |
| 2 | toolRunCommand（唯一结果字段生产者）← executeRunCommandBackend（:1426-1457）← dispatch_ctx.run_command_backend.execute | 会（capability/ephemeral/interactive 任一成立时，commandReplayPolicy :2008-2028），但**bridge.call 不可达**：唯一调用 backend.execute 的注册工具是测试专用 test_captured_shell（callTestCapturedShell :2702-2723，executor_kind .run_command :2733）；生产 shell 是 executor_kind .terminal + runtime_provider .run_command，其 call 从不触碰 backend（shell.zig 全文无 run_command_backend 引用） | 直接调用方：orchestrator.zig:11540-11550（取消路径 discard + retainCancelledCommandReplay）、:11704-11740（discard + finalizeCommandReplay）；executeToolCallAuthorized 的 defer 只 abort **request 传入的续传** capture（:416-419），不覆盖新造的结果 capture | 同左；toolRunCommand 内部未转移时自行 abort（:2083-2086、:2155-2158） |
| 3 | wasi 路径 executeWorkspaceToolCallInner（:709-729，comptime wasi 分支 :467） | 否（对 bridge 而言）：要求单工具 registry 且 executor_kind .run_command；bridge.call 硬编码 check.tool_registry = builtin_tools.registry（bridge.zig:129，16 个工具）→ semanticFailure，无 capture | — | — |
| 4 | run_command 兼容 stub（dispatchRunCommandCompatibility，tool_dispatch.zig:520-532，仅 legacy 环境）| 会造 capture（tool_runtime.zig:2071-2086），但只在 toolRunCommand 内被调（:2064），随入口 2 不可达；与 ISSUE-29 原文「codemode 嵌套调用不经此处」一致 | 入口 2 的消费者 | 入口 2 的清理 |
| 5 | 其余嵌套面（read_file/glob_files/grep_files/write_file/edit_file/web_fetch/ask_user_question/vision/run_script→shell） | 否：均不写结果字段；write/edit 走 file_mutation_execution，无 capture | — | — |
| 6 | read_tool_result（非 sandbox_reachable，列全）| 其内部 Capture.create（read_tool_result.zig:524 为测试；生产读路径只读已有句柄）自持 | 自身 | 自身 retainRequired/releaseRetained |

补充锚点：
- bridge.call 的 request 不含 command_replay_capture（bridge.zig:158-168），故 executeToolCallAuthorized 的续传 abort defer（:416-419）在此恒 inert。
- 生产 ctx 恒带 managed_executions 与 ephemeral_command_replay（app_agent_runtime.zig:417-423），嵌套 shell 必走入口 1；managed_executions 为 null 时 callRun 直接 unavailable 失败（shell.zig:621），仍无 capture。
- 结果 capture 的消费者清单（全仓）：orchestrator 两处（上表）、executeTestRunCommand 系测试的 defer abort（tool_runtime.zig:5857、:6042 等）、tests/support.zig:1543。bridge.call 不在其中——但因字段恒 null，无泄漏。

## 二、结论与改动

论证链：结果字段唯一生产者 toolRunCommand → 唯一触达方式是 run_command backend → 生产注册表无工具的 call 调用该 backend（仅测试 test_captured_shell）→ bridge.call 又硬编码生产注册表 → 嵌套结果字段恒 null。生产嵌套命令的 capture 归 managed execution 运行时所有，retain/release 闭环完整，artifact 文件是句柄引用的会话态而非孤儿。

改动（最小加固之注释支，零语义变化）：
- src/tools/codemode/bridge.zig：在结果消费点（result_commit 提交块前）补 7 行归属契约注释，写明字段恒 null 的原因、生产 capture 的真实归属，以及「若未来有嵌套路径交出 capture，bridge 必须在此 abort」的契约。不加防御性 abort：该分支今日不可达，且无法经 bridge.call 构造红测试（注册表覆盖是 admission 语义，红线禁动），加不可测的死代码违背最小改动。

## 三、验收证据

1. zig build test 全绿：TEST_EXIT=0（本机 Debug，约 390s）。注释改动仍触编译，故照跑。
2. zig fmt --check src/：FMT_EXIT=0。
3. bash scripts/check-public-surface.sh：SURFACE_EXIT=0；bash scripts/check-agents-boundary.sh：AGENTS_EXIT=0。
4. 产物：本 impl-report.md + 注释 commit。无红绿 commit：纯核查支，无行为改动可钉（红测试不可达正是核查结论本身）。
5. 真机冒烟（./zig-out/bin/fx，本 checkout 新构建）：
   - `fx --version` → 0.0.16，EXIT=0，stderr 0 字节。
   - `fx help`、`fx ask --help` → EXIT=0，stderr 0 字节。
   - tmux 交互启动（FX_SOUND=0）：首帧正常（v0.0.16 · auto · qwen4-max），会话存活，/exit 退出，stderr 0 字节，无 abort。

## 四、红线自查

- 只动 capture 归属注释；执行语义、admission/permissions/catalog 零触碰；tests/tla/ 零触碰。
- 无新 CLI 面/settings 键/环境变量；无个人路径入代码与报告。
- zig fmt 后提交。

## 五、遗留提示（不在本票范围）

- 入口 2 的契约缺口仍潜在存在：executeToolCallAuthorized 把新造结果 capture 交给调用方，orchestrator 有消费而 bridge 没有。今日不可达；若未来把 executor_kind .run_command 的工具接入生产注册表或改 wasi 路径，须按 bridge.zig 新注释在 bridge 补 abort，并先开票论证。
- ISSUE-29 处置项 1（timeoutFailure stub 的输出送达）属 toolRunCommand 兼容路径，与本票独立，仍 open。
