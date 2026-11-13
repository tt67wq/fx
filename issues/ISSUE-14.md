# ISSUE-14 — codemode 工具面从硬编码改为可配置

- **状态**: fixing
- **发现时间**: 2026-11-10
- **来源**: fx codemode 与 pi 1.5.1 源码对比
- **工作量**: 中
- **关联**: ISSUE-15 依赖本项
- **评审**: 2026-11-13 独立评审（分支 fx-pi1，base 13713b9b6，review.md commit 3b52c1621），
  changes-requested 后按其 6 条建议修订本方案。代码事实与准入主张已由评审逐条确认。

## 现象

src/tools/codemode/bindings.zig:23 写死四个工具（glob_files、grep_files、
read_file、run_command），扩面要改代码发布。

pi 的对应行为：可调用面动态来自 active direct 与 codemode/deferred 工具
（getCodemodeCallableTools），MCP 工具可达，无需改包。

## 已核实的代码事实

- 白名单三个消费点：bridge.zig:368 schemas()；host.zig:340 编译期 whitelist
  字面量拼进 JS shim；host.zig:607 运行时 bindings.find()。
- bridge.zig:97 check.tool_registry = builtin_tools.registry：嵌套准入始终对
  全量 builtin registry 逐次执行。白名单只决定「脚本可点名谁」，不决定
  「谁免审」。扩面本身不放松准入，本项只需补测试证明。
- run_command_compatibility 字段挂在 install_skill 上（builtins/tools.zig:553），
  与沙箱面命名无关；shell 到 run_command 是 bridge.registeredName（bridge.zig:358）
  的既有特判。
- ReadsOnlyFn 是「按参数分类」语义（如 shell 的 run 为 false、interact 可能为
  true），ToolInput 是 decode 后的擦除指针，无法空参探测，不得用作面推导依据。

## 修法（评审修订版）

显式标记 + comptime 双面切片 + experimental 开关，而非自由配置列表或
reads_only_fn 推导：

1. 给 tool_dispatch.Tool 增加显式字段 sandbox_reachable: bool = false，作为
   沙箱面唯一来源。每个工具是否进面是一次显式、可 review 的代码决策。
2. 默认面与推导面都在 comptime 从 registry 遍历得出：默认面 = 现有四项
   （保持 bindings.tools），开启面 = 标记了 sandbox_reachable 的工具按原名，
   run_command 走 registeredName 既有特判收录。host.zig 的编译期 whitelist
   字面量与 bindings.find 机制不动，运行时 gate 只在两个静态切片间二选一。
3. gate 为 profile-only 开关 experimental.codemode_derived_surface（命名过
   fx-cli-shape 走查后可微调），仿 experimental.codemode 先例
   （settings_keys.zig:121、config_runtime.zig:203）。传值管道仿
   codemode_enabled：config_runtime 新字段与 accessor + overlay 合并，经
   DispatchContext 或 CodemodeHostState 传入 codemode_tool.call。
4. 开启态新增工具逐个拍板并写进本 issue。当前 registry 下候选（按 readsOnly
   语义观察，仅作拍板清单）：web_fetch（出站网络）、ask_user_question（会在
   30 秒脚本预算内阻塞等待人工回答）、vision。首个实现建议只标记读取类三件
   + run_command 维持现状面，候选工具在后续变更中逐个标记并说明产品决策。
5. bridge.schemas 改收 name 列表参数；registeredName 映射不变；codemode_tool
   按开关选面，推导在既有 schema_arena，每调用一次，不在 eval 热路径重复。

准入不放松：每个嵌套调用仍逐次走 bridge.call 的 tool_admission pipeline
（bridge.zig:97、114），新工具面只扩大「脚本可点名谁」，不扩大「谁免审」。

明确不做（归 ISSUE-15 及以后）：MCP 工具、searchTools/describeTool、schema
目录预算与阈值。

## 处置

- [x] 与 fx-cli-shape 技能核对开关命名与 surface 清单（surface_diff.sh、
      settings_keys.zig、cli_config.zig、tests/e2e/cli.test.ts、fx.sh 页面）
- [x] Tool 增加 sandbox_reachable 字段，comptime 推导开启面（要点 1、2）
- [x] gate 设置键、config_runtime 管道与传值（要点 3）
- [x] bridge.schemas 参数化与 codemode_tool 选面（要点 5）
- [x] 嵌套准入覆盖新工具面：用真实 registry 工具在 deny 模式验证逐次准入，
      不注入 mock registry（bridge.call 硬编码 builtin_tools.registry）
- [x] 单测 A：关闭 gate 时工具面与现状逐项且同序相等（tools.list 注入顺序
      即 bindings.tools 顺序，bridge.zig:370）
- [x] 单测 B：开启态 golden 名单锁定期望面，防标记漂移
- [x] 开启态候选工具（web_fetch、ask_user_question、vision）逐个拍板记录
      用户拍板：edit_file、write_file、web_fetch、ask_user_question、vision
      五个一并进面，开启态 9 项（含 run_command）。
