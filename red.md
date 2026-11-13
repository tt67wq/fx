# T-14-1 先红后绿证据

分支 fx-pi1，base 合并 main 7fa4228c0（merge commit 4a11e2a13）。

## 先红（commit b3b1b8f）

红测试两段按契约原文加入，未改动测试本体：
- `src/core/config/config_runtime.zig`：codemode_derived_surface gate 的两段测试，
  紧随现有 codemode gate 测试之后。
- `src/tools/codemode/bindings_tests.zig`：sandbox face 测试（含 import 补充）。

`zig build test` 输出摘要（预期编译红，3 errors）：

    src/core/config/config_runtime.zig:2776:40: error: use of undeclared identifier 'codemodeDerivedSurfaceEnabled'
    src/core/config/config_runtime.zig:2797:40: error: use of undeclared identifier 'codemodeDerivedSurfaceEnabled'
    src/tools/codemode/bindings_tests.zig:21:26: error: root source file struct 'tools.codemode.bridge'
        has no member named 'sandboxFace'
    error: 3 compilation errors

## 后绿

green 实现 commit SHA：5b4f6c655（红测试 commit b3b1b8f 之后）。本文件所在提交只更新该 SHA。

验收命令（工作区，全部退出码 0）：

    zig fmt --check src/                     # OK
    zig build test                           # 9921+ pass, 0 fail（见下方说明）
    cd tests/e2e && FX_SOUND=0 bun test cli.test.ts
                                             # 139 pass, 6 skip, 0 fail

说明：首次完整 `zig build test` 出现过一次
`core.execution.command_runner.test.runtime cancellation observed at the timeout
deadline stays graceful` 失败，该测试按时间截止判定，与本次改动无交集；随后完整
重跑（313 秒，未走缓存）全绿，再跑命中缓存也全绿。

## 实现决策

1. `tool_dispatch.Tool` 新增 `sandbox_reachable: bool = false`，作为沙箱面唯一来源。
   只标记 `glob_files`、`grep_files`、`read_file` 三个读取类工具。
2. `bridge.sandboxFace(comptime registry, derived)` 返回两个 comptime 面的静态切片：
   关闭面即 `bindings.tools` 四项；开启面按 registry 顺序收集已标记工具，再追加
   `run_command`（registry 里是 `shell`，脚本名由既有 `registeredName` 特判映射，
   因此不改该特判）。运行时 gate 只在两个静态切片间二选一，无运行时字符串拼接。
3. `host.zig`：`Host` 增加 `tool_face`（默认 `bindings.tools`）与 `setToolFace`。
   shim 的 white list 由 `JS_NewArray` + `JS_NewStringLen` 注入（QuickJS 自己持有
   字符串副本，Zig 切片不跨调用存活），shim 从 `tools.__codemode_whitelist` 读取。
   `tools.call` 的查找改为 `bindings.findIn(host.tool_face, name)`；
   `bindings.find` 保留为默认面查询。
4. `bridge.schemas` 增加 `face` 参数，按面注入 tools.list，顺序即面顺序。
5. `codemode_tool.call` 用 `bridge.sandboxFace(builtin_tools.registry, state.derived_surface)`
   选面，schema 仍每调用在既有 schema_arena 构建一次。
6. gate 管道：`settings_keys.zig` 的 `experimental` children 增加
   `codemode_derived_surface`；`config_runtime.Settings` 增加
   `codemode_derived_surface_enabled: ?bool`、accessor `codemodeDerivedSurfaceEnabled`、
   类型错误 `InvalidExperimentalCodemodeDerivedSurfaceType`、overlay 合并。
   profile-only 与 project 层忽略由既有 experimental 解析路径保证（红测试已断言）。
7. 传值：`tool_runtime.Context` 增加 `codemode_derived_surface`，
   `CodemodeHostState` 增加 `derived_surface`，两处构造点从 ctx 取值。
   `main.zig` 增加缓存 gate `codemodeDerivedSurface()`（与 `codemodeGate` 同形，
   re-resolve 时一并清空）。
8. 未标记工具清单（留给后续逐个拍板，本次不进面）：`web_fetch`（出站网络）、
   `ask_user_question`（会在 30 秒脚本预算内阻塞等待人工回答）、`vision`。
   `web_search` 因 `provider_executed` 本就不能进面；`write_file`、`edit_file`、
   `shell`、`skill`、`install_skill`、`subagent`、`mcp_select_tool`、
   `read_tool_result`、`capability_search`、`codemode` 均不标记。
   因此开启态当前与关闭态完全同面（测试 B 锁定该事实），扩面留待显式标记。

## 准入不放松

`bridge.call` 的嵌套准入路径未改一行：`check.tool_registry = builtin_tools.registry`
（bridge.zig:97）仍对全量 registry 解析，每次嵌套调用仍逐次进入
`tool_admission.requestPermissionOutcome`（bridge.zig:114）。面只决定脚本可点名谁。

## 超出 ownership 清单一处（需 conductor 确认）

`src/core/app/app_agent_runtime.zig` 增加 3 行：构造 `tool_runtime.Context` 时
`@hasDecl(App, "codemodeDerivedSurface")` 守卫读取 gate。该文件是 Context 的唯一
应用侧构造点，是「main.zig 接线到 CodemodeHostState」的必经点；ownership 清单未列
它。若要求严格按清单执行，请指示替代接线方式。

`src/core/cli/cli_config.zig` 未改：`experimental` 已在 files_only_keys 中，
新 child 通过 `settings_keys.find` 自动被 `fx config` 识别，覆盖测试亦按 key 列表
自动通过。

## fx-cli-shape 走查

- `surface_diff.sh`：`+ setting codemode_derived_surface  src/core/config/config_runtime.zig`
  （唯一新增控制，无 flag/命令/env var）。
- 机制选择：规则 8（unfinished 用 `experimental.<name>`），与
  `experimental.codemode`、`experimental.rtk` 先例一致；profile-only、默认 off。
- 命名：`codemode_derived_surface` 表达「由 registry 推导的面」，与实现语义一致，
  未采用 review 草案中的 `codemode_open_surface`（open 暗示放开准入，易误读）。
- 文档：fx.sh 页面为私有仓库，本任务未改；PR 描述需补 `## Docs` 说明
  （`experimental.codemode_derived_surface` 的用途与默认值）。
