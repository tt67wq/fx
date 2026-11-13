# T-14-6 扩面产物

分支 fx-pi1，起点 ef429e741（已 merge main 到 e3b65bd79）。红 commit 1ce937211。

## 新沙箱面（开启态，9 项）

按注册顺序（`bridge.derivedFace` 遍历 `builtin_tools.registry`，再追加 run_command）：

    glob_files, grep_files, read_file, write_file, edit_file,
    web_fetch, ask_user_question, vision, run_command

注意与契约文本的差异：契约写的是 "`... read_file, edit_file, write_file, ...`"，但
`src/builtins/tools.zig` 的 `all` 数组里 `write_file` 在 `edit_file` 之前。实现按契约
自己的规则（"按注册顺序"）输出，golden 测试锁定的是注册顺序，即 write_file 在前。

关闭态仍是 4 项：glob_files, grep_files, read_file, run_command。

## 先红证据

单元（golden 名单）：

    error: 'tools.codemode.bindings_tests.test.sandbox face keeps the shipped
           surface whether the gate is off or on' failed:
           expected 9, found 4

e2e（deny 准入）：gate 开启、`permission: { edit: "deny" }` 下，脚本
`tools.call("write_file", ...)` 当时返回 `error-text`（"unknown codemode tool: write_file"），
因为 write_file 尚未进面。

## 后绿

- 单元：`zig build test` 退出码 0（9930+ 测试）。
- e2e：`bun test codemode-admission.test.ts cli.test.ts` → 151 pass, 6 skip, 0 fail。
  首次跑出现 1 fail（含 cli.test.ts 在内），重跑连续两次全绿；按 AGENTS.md 视为偶发，
  未改动任何测试断言。

## 修复轮额外发现的真 bug（本任务修）

扩面让 `write_file`/`edit_file` 进入脚本可达后，嵌套写文件失败于
`file mutation execution requires distinct call and result owners`：
`bridge.call` 把同一个 arena 同时用作 `call_allocator` 与 `result_allocator`。
修法：在 `bridge.call` 另开 `result_arena_state`，只把它的 allocator 传给
`result_allocator`；call arena 仍承担 prepared mutation 的生命周期。属
`src/tools/codemode/` 所有权内，准入路径未改动一行。

## ask_user_question 决策注释位置

`src/builtins/tools.zig` 的 `ask_user_question` spec 中，`.sandbox_reachable = true`
上方三行注释说明：脚本调用会在脚本自身 wall-clock 预算内阻塞等待人工回答，且该调用
仍照常通过准入评审。产物记录即本段。

## 准入不放松

- `bridge.call` 的 `check.tool_registry = builtin_tools.registry` 与逐次
  `tool_admission.requestPermissionOutcome` 未改动。
- deny 用例证明：配置 deny 的写操作进入面后仍被拒绝，且工作区文件未被创建，
  脚本看到 `{"denied":true,"reason":...}`。

## 未做（按契约）

MCP 工具与 searchTools（ISSUE-15）；ISSUE-17 的三个既有 CI 失败。
