# T-26-review — bridge.call capture 归属核查评审

- 评审者：fx-pi1（未参与 T-26-impl 实现，作者独立性成立）
- 所核 commit：0eda7df7fa9f5a8b69e955262af869bb3fe3b882（fx-pi2 分支，基线 main e9448eaed）
- verdict：**approve**

## 逐条复核（论证链）

1. **结果字段唯一生产者确为 toolRunCommand — 成立。**
   独立 grep 全仓 `.command_replay_capture =`：结果字段写入仅
   tool_runtime.zig:2368（finishCommandToolResult 内）与测试
   orchestrator/tests/support.zig:1543；:455 写的是 Context 同名字段（续传入参），
   orchestrator.zig:11735 是消费侧置 null。finishCommandToolResult 的全部生产调用点
   （:2105/:2123/:2179/:2195/:2204/:2223/:2235/:2246）都在 toolRunCommand（:2030）内，
   另一调用点 :6289 在 test 块。toolRunCommand 唯一生产调用方是
   executeRunCommandBackend（:1443）。

2. **bridge.call 硬编码注册表无工具走 run_command backend — 成立。**
   bridge.zig:129 `check.tool_registry = builtin_tools.registry`；生产注册表
   builtins/tools.zig:786-805 共 16 个工具，无一 executor_kind .run_command
   （全仓该赋值仅 tool_runtime.zig:2733 测试工具 test_captured_shell 与
   orchestrator.zig:2156，后者在 test 块内）。backend.execute 的唯一调用点是
   callTestCapturedShell（:2707），只存在于测试注册表（:2752/:2803/:2808）。
   生产 shell 是 executor_kind .terminal + runtime_provider .run_command
   （tools.zig:428/:440）：backend 虽在 executeRegisteredTool :905 注入，但
   src/tools/shell/shell.zig 全文 0 处 run_command_backend 引用，call 从不触达。
   wasi 路径 executeWorkspaceToolCallInner（:709）要求 tools.len==1 且
   executor_kind/runtime_provider 均 .run_command，对 16 工具注册表必
   semanticFailure。MCP/动态工具 executor_kind .mcp_select_tool，不经 backend。
   bridge 的 request 不传 command_replay_capture，executeToolCallAuthorized
   :416-419 的续传 abort defer 在此恒 inert。**未找到任何可造出非 null capture
   的嵌套反例路径。**

3. **生产嵌套 shell 的 capture 归属 managed execution、retain/release 闭环完整 — 成立。**
   capture 造于 managed_execution.zig:258/:315 的 entry.replay_capture，不上
   ToolExecutionResult；finalizeReplayLocked（:493-507）retain 后把句柄 dupe 进
   output_handle 再 releaseRetained；Entry.deinit（:374-376）与
   clearAuthorityLocked（:1381-1384）兜底 releaseRetained。结果经
   tool_result_memory.command_output_replay（shell.zig:1533-1537）与
   command_result_json.output_file（:1558-1574）句柄传递，闭环无孤儿。

4. **「managed_executions 为 null 时 callRun 直接 unavailable（shell.zig:621）」锚点 — 属实。**
   实际文件为 src/tools/shell/shell.zig（callRun :614，:621
   `ctx.managed_executions orelse return unavailable(ctx)`）。报告中「shell.zig」
   未带目录前缀，与 src/tools/codemode/shell.zig（44 行包装层）存在歧义，但行号
   唯一对应 src/tools/shell/shell.zig，论证不受影响。建议后续报告带全路径（非阻塞）。

## 注释核对

bridge.zig 新增恰 7 行，位于结果消费点（result_commit 提交块前），内容与上述
论证逐句一致：字段恒 null 的原因、生产 capture 归属 managed 运行时、未来若交出
capture 须在此 abort 的契约。纯 ASCII，无 emoji、无 `--` 破折号（脚本逐字符核验）。

## 机械核验（评审者自跑，fx-pi2 checkout，commit 0eda7df7f）

1. `zig build test`：TEST_EXIT=0（约 397s，无 flake）。
2. `zig fmt --check src/`：FMT_EXIT=0。
3. `bash scripts/check-public-surface.sh`：SURFACE_EXIT=0。

## 红线核对

`git diff --stat e9448eaed..0eda7df7f`：仅 impl-report.md（+52）与
src/tools/codemode/bridge.zig（+7，全部为注释行）。零语义变化；tests/tla/ 零触碰；
admission/permissions/catalog 零触碰；无新 CLI 面/settings 键/环境变量；无个人路径。

## 备注（非阻塞）

- 报告「全仓仅两处赋值」的表述精确限于结果字段；Context 同名字段（:455）与消费侧
  置 null（:11735）不构成反例，已独立确认。
- 不加防御性 abort 的取舍合理：该分支今日不可达，注册表覆盖属 admission 语义
  （红线禁动），死代码不可测；注释已写明未来契约与先开票要求。
