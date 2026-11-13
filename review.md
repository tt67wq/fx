# Review: ISSUE-14 最小修改方案（conductor 草案）

- 结论：changes-requested
- 评审 base SHA：13713b9b66a15834519203d9968166cdd3be403e（分支 fx-pi1）
- 评审对象：设计方案，非代码实现

架构方向（experimental 开关 + registry 推导 + 白名单不再硬编码）成立，引用的代码事实与行号全部属实，准入不放松的主张经核实成立。但核心推导规则（方案要点 2）按原文不可实现且含事实错误：开启态会丢失 run_command、误收 install_skill。需要重写推导规则并补齐传值管道后方可进入实现。

## 1. 代码事实核实

方案引用的行号与语义全部吻合，逐项确认：

- 白名单硬编码四项：src/tools/codemode/bindings.zig:23-28（glob_files、grep_files、read_file、run_command）。
- bridge.zig:368 schemas() 按 bindings.tools 逐项 lookup；bridge.zig:358-361 registeredName 把 run_command 特判映射到 shell。
- bridge.zig:97 check.tool_registry = builtin_tools.registry，嵌套准入对全量 registry 解析。
- host.zig:340-348 编译期 whitelist_literal 拼进 JS shim；host.zig:607 运行时 bindings.find(name) 决定脚本可转发谁。
- settings_keys.zig:121 experimental switches（codemode、rtk），profile-only；config_runtime.zig:203-210 有对应 accessor 先例。

两处补充事实，方案未提及但对推导规则有决定性影响：

- codemode 工具本身不在 builtin registry 内：src/builtins/tools.zig:764-781 的 all 数组共 16 项，不含 codemode。executor_kind == .codemode 的排除对当前 registry 是防御性的（测试 registry 或将来加进来时才生效）。
- RunCommandCompatibility 结构只有 matches 与 execute 两个回调（src/core/tooling/tool_dispatch.zig:321-325），没有名字字段。

## 2. 推导规则评估：规则按原文不可实现

### 2a. run_command_compatibility 规则是事实错误

方案要点 2 称「run_command_compatibility != null 的按兼容名收录（shell→run_command）」。实际：

- run_command_compatibility 挂在 install_skill 上（src/builtins/tools.zig:549-553），shell 的 spec（src/builtins/tools.zig:410-441）没有该字段。该字段是「shell 文本命令捕获」机制（tool_dispatch.zig:503 起），不是沙箱面命名机制。
- shell→run_command 的映射硬编码在 bridge.registeredName（bridge.zig:358-361）与 canonicalNestedCall，没有可推导的名字来源。

按方案原文执行的结果：shell 不会被任何规则收录（见 2b），开启态的 run_command 直接消失；install_skill 反而命中规则 2，而它是 requires_approval 的写工具（src/builtins/tools.zig:537），绝不应进沙箱面。

### 2b. reads_only_fn(空参) 探测不可实现

- 签名是 fn(ToolInput) bool（tool_dispatch.zig:336）。ToolInput 是 decode 之后的擦除指针（tool_dispatch.zig:129-141），不存在「空参」构造方式。
- 传入伪造 ToolInput 对参数敏感的实现是未定义行为：shell.zig:1997 与 subagent.zig:269 都会 deref erased.as(Input) 读参数字段。
- 走 decode("{}") 探测则多数工具因 required 字段 decode 失败（shell 的 action 必填，src/builtins/tools.zig:418）。
- 语义层面 reads_only_fn 是「按参数分类」，不是「按工具分类」：shell 的 run/stop 返回 false、interact 可能 true（shell.zig:1996-2002）；subagent 的 wait/status 为 true、message/stop 为 false（subagent.zig:268-273）。任何单点探测都无法代表整工具。

### 2c. 即使探测修好，扩面范围方案没有识别

当前 registry 下 readsOnly 恒 true 的非 internal 工具有六个：glob_files（glob_files.zig:302）、grep_files（grep_files.zig:530）、read_file（read_file.zig:454）、web_fetch（fetch_args.zig:75）、ask_user_question（ask_user_question.zig:289）、vision（vision.zig:63）。即开启态脚本会获得出站网络请求与用户交互提问能力。web_search 因 provider_executed 排除（web_search spec，src/builtins/tools.zig:396 附近），这点规则正确。脚本内调用 ask_user_question 会在 30 秒脚本预算内阻塞等待人工回答，这是产品级决策，方案只字未提。

### 2d. executor_kind == .codemode 排除

对当前 registry 是廉价防御，保留即可。除 codemode 外没有其他自引用路径：subagent 在修正后的规则下不会被收录，且 bridge.call 用 builtin registry 解析，未收录的名字在 find 处就被拒（host.zig:607）。

## 3. fx-cli-shape 合规性

机制选择合规：

- 规则 8（unfinished 用 experimental.<name>）与 references/rules.md:144-145 完全吻合；profile-only、默认 off 与 experimental.codemode 先例一致。
- fx config set 写路径经 settings_keys.find（src/core/cli/cli_config.zig:104-106），children 加入 settings_keys.zig 即覆盖；cli_config.zig:992 的覆盖测试因 "experimental" 已在 files_only_keys（cli_config.zig:460）自动满足。

两处缺口：

- 命名：codemode_open_surface 的 open 暗示「开放面」，与实际「registry 推导面」语义有偏差。若按下面建议改为显式字段方案，建议名字随语义调整（如 codemode_derived_surface），最终以 fx-cli-shape 走查为准。
- 传值管道缺失：DispatchContext（tool_dispatch.zig:219-264）没有任何 settings 字段，codemode_tool.call 拿不到开关值。方案要点 5 只说「按 state 开关」，没有说 state 从哪来。需要新增管道，先例是 codemode_enabled 从 config 走到 gatedToolSet（src/main.zig:4307）。

## 4. 准入不放松主张：成立

- bridge.call 每次嵌套调用新建 ToolCall（bridge.zig:63-73），check.tool_registry 固定为全量 builtin registry（bridge.zig:92-97），逐次进入 tool_admission.requestPermissionOutcome（bridge.zig:114-119），授权后才 executeToolCallAuthorized（bridge.zig:132-144）。白名单只决定脚本可点名谁，与谁免审无关，方案主张与安全事实一致。
- 测试 C 设计注意：bridge.call 硬编码 builtin_tools.registry，不能注入 mock registry。验证「新工具仍逐次准入」只能用真实工具（开启态收录的某工具，或保留的 run_command）在 deny 模式下观察拒绝结果；若方案设想的是 mock 新工具，该测试在当前结构下不可行，也不建议为此把 call 改成收 registry 参数（会削弱「永远全量 registry」的不变量）。

## 5. 最小性：存在更小且更稳的等价改法

方案的 host.zig 改动（编译期字面量改运行时拼接、bindings.find 改运行时线性查找）引入 shim 字符串生命周期管理：whitelist 字符串需由 Host 持有到 deinit，installBindings 每次 Host 初始化构建一次（host.zig:260-282）。这是真实复杂度，不是零成本。

更小改法：给 Tool 增加一个显式 comptime 可判定字段（如 sandbox_reachable: bool = false）。默认面与推导面都在 comptime 从 registry 遍历得出，运行时 gate 只是在两个静态切片之间二选一。效果：

- host.zig 的 whitelist_literal 与 bindings.find 保持 comptime，零运行时字符串、零生命周期问题。
- 「按 registry 类别推导」的诉求由 comptime 遍历满足，ISSUE-14 的修法条款（profile 设置或 registry 推导，二选一）完全成立。
- 每个新工具是否进沙箱面成为一次显式、可 review 的代码决策，而不是 reads_only_fn 语义的意外副产品。

bridge.schemas 改收 name 列表、codemode_tool 按开关选面、registeredName 映射不变，这些同意，是正确且最小的切口。

## 6. 风险与遗漏

- shim 字符串生命周期：若坚持运行时拼接方案，必须由 Host 拥有字符串并在 deinit 释放；bindings_tests.zig:9-14 的「恰四项、write_file 不在列」断言要随面参数化。
- reads_only_fn 语义漂移：这正是推导规则不可靠的根源；不要把它用作面推导依据，它的合法用途是 admission 的按参数分类（tool_admission.zig:129）。
- 扩面产品影响未识别：web_fetch 出站网络、ask_user_question 与 30 秒预算的阻塞交互、vision 的输入面，需要逐个拍板并写进方案。
- ISSUE-15 衔接：schema 每调用在 arena 重建（codemode_tool.zig:239-241），扩面后成本线性增长；方案显式推迟给 ISSUE-15 是合理的，但实现时应保持「每调用推导一次」，不要在 eval 热路径重复推导。
- 测试 A 建议加断言顺序一致：tools.list 注入顺序即 bindings.tools 顺序（bridge.zig:370），关闭态应与现状逐项且同序相等。

## 修改建议（changes-requested）

1. 重写方案要点 2：新增显式 Tool 字段（sandbox_reachable 或同义名，默认 false）作为沙箱面唯一来源；run_command 继续走 bridge.registeredName 的既有特判收录；run_command_compatibility 与沙箱面推导脱钩。
2. 删除 reads_only_fn 空参探测。测试 B 的 golden 名单直接锁定开启态期望面。
3. 补 gate 传值管道：config_runtime 新字段 + accessor + overlay 合并（仿 codemode_enabled：config_runtime.zig:73、206、1873-1877、2093），经 DispatchContext 新字段或 CodemodeHostState 传入 codemode_tool。
4. 在方案中显式列出开启态新增工具并逐一拍板（当前 registry 下若按 readsOnly 语义会是 web_fetch、ask_user_question、vision；若按显式字段方案则由标记决定），特别说明 ask_user_question 与脚本预算的交互。
5. 优先采用第 5 节的 comptime 双面切片方案，host.zig 不动编译期机制。
6. 测试 C 用真实 registry 工具在 deny 模式验证逐次准入，不注入 mock registry。
