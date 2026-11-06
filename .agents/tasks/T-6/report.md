# T-6 — G1 准入 spike：脚本内调用的嵌套准入可行性

基线：fx-pi-1 分支头（见 git log）。本报告只读代码 + 一个新增测试文件，未改任何源码。

## 1. 准入 Input 字段清单（谁产生、工具执行期是否可得）

tool_admission.Input（src/core/tooling/tool_admission.zig:64-80）共 16 个字段。执行期可得性按「工具执行帧里是否拿得到等价物」判断；执行帧的持有者是 tool_runtime.Context（构造于 src/core/app/app_agent_runtime.zig:381-410 一带），Context.admissionInput() 是 pub 方法（src/core/tooling/tool_runtime.zig:258-290）。

| 字段 | 谁产生 | 工具执行期是否可得 |
|---|---|---|
| workspace_root | App 组装 Context（app_agent_runtime.zig） | 可得（ctx.workspace_root） |
| access_scope | App，同上 | 可得 |
| permission_review_turn | 仅在准入闭包里由 App/CLI/Subagent 适配器注入（app_agent_runtime.zig:783、841；cli_ask.zig:2349；subagent/agent_adapter.zig:868），orchestrator 每次调用前构造（orchestrator.zig:6066-6094，10959 调用） | 不可得：执行期的 Context 里它是 null。需要为嵌套调用现造一个（有先例，见第 2、3 节） |
| permission_grants | live authority 快照或 App 引擎（tool_runtime.zig:313-330） | 可得（ctx.permission_grants） |
| permission_rules | 同上 | 可得 |
| session_permission_state | live authority 或 run.admission（app_agent_runtime.zig:317-345） | 可得（ctx.permission_state_override） |
| session_permission_state_provider | admissionInput 内部从 ctx.session 构造（tool_runtime.zig:268-271） | 可得（构造函数自带） |
| tool_registry | App | 可得 |
| worker: *WorkerRuntime | App：.worker = &agent.worker（app_agent_runtime.zig:402） | 可得（指针，随 Context 按值复制） |
| mcp_review_schema_json | 仅 MCP bridge 注入（tool_runtime.zig:972） | 可得（通常 null） |
| permission_prompter | tool_admission.workerPrompter(&agent.worker)（app_agent_runtime.zig:403；tool_admission.zig:2075-2081） | 可得 |
| advertised_dynamic_tool_names | App / live authority | 可得 |
| mcp_runtime | mcpRuntimeCapabilities(self)（tool_runtime.zig:273） | 可得 |
| context_limits | App | 可得 |
| auto_classifier | admissionAutoClassifier()（tool_runtime.zig:332-347） | 可得 |
| terminal_review_context | terminalReviewContext()（tool_runtime.zig:292-311） | 可得 |

结论：执行期唯一缺的是 permission_review_turn，而它恰恰可以在嵌套调用处合成（先例：MCP bridge 在工具执行期构造了一个完整的 ReviewTurnContext，src/core/tooling/tool_runtime.zig:974-983，其中 pending_assistant 是只含当前调用的人造 assistant 消息）。任务书里「准入 Input 需要 orchestrator 的运行时借用」的前提不成立：Input 不借用 orchestrator，它借用的 WorkerRuntime 指针在执行帧里就有。

## 2. 调用链（文字版）与执行上下文句柄设计

调用链（root agent，一次工具调用）：

1. UI/main 线程 spawn worker 线程：app_process_runtime.zig:39-47（agentWorkerThreadMain）。
2. worker 循环：runWorkerLoop → workerLoop → processQueuedWork（app_process_runtime.zig:165-187），整个 turn（含工具执行）都在这一条 worker 线程上。
3. orchestrator 对每个 tool call 先准入：buildReviewTurnContext（orchestrator.zig:6066-6094，10959 调用）→ runtime_tool_admission.requestToolPermissionTraced（orchestrator.zig:11018）→ deps.requestPermission 闭包（app_agent_runtime.zig:776-816），闭包内 toolContext(...) + ctx.admissionInputWithLiveAuthority（tool_runtime.zig:313-330）→ tool_admission.requestPermissionOutcome；ask 时经 Prompter 阻塞等人（见第 4 节）。
4. 准入通过后执行：deps.executeToolCall（orchestrator.zig:11487；deps.zig:313-336）→ tool_runtime.executeToolCallAuthorized（tool_runtime.zig:408-502）→ executeToolCallInner（668）或 executeWorkspaceToolCallInner（709）或 file_mutation_execution.execute。
5. 执行帧构造 DispatchContext 并挂后端：command_backend = RunCommandBackendState{ .runtime = ctx }（tool_runtime.zig:727、832）、subagent_provider（841-850）→ tool_dispatch.dispatchAuthorizedToolCall（tool_dispatch.zig:864-885）→ input.tool.call(ctx, input.value)。
6. 取消检查在调用返回后：cancel_if_requested_after_call → 丢结果、error.Cancelled（tool_dispatch.zig:875-881）。

能拿到执行上下文的栈帧：第 4 步的 executeRegisteredTool / executeWorkspaceToolCallInner 持有完整 tool_runtime.Context，并且已经通过「后端状态」模式把它递进 DispatchContext：RunCommandBackendState（tool_runtime.zig:1259-1263）、SubagentProviderState（2279 起），subagent 执行器从 raw_context 取回 runtime 再调 host.executeManaged（2398-2404），并把 caller_worker = ctx.worker、cancel_flag = runtimeCancelFlag(ctx) 一并传下去（2425-2438）。这就是现成的嵌套编排先例。

「执行上下文句柄」最小设计：

- 类型：仿照 RunCommandBackendState，新增 CodemodeHostState { runtime: tool_runtime.Context, script_call: ToolCall, script_location: []const u8 }。不建议新抽象层，直接复用 Context（它已含 worker、prompter、rules、classifier、observer、terminal context 等，见第 1 节表）。
- 放哪：Context 字段挂在 src/core/tooling/（tool_runtime.zig 的 provider 状态旁）；DispatchContext 侧照 run_command_backend / subagent_provider 的形状加一个可选槽（tool_dispatch.zig:218-330 的字段区）。
- 谁构造：tool_runtime.zig 的两个执行帧（727/832 附近），与现有后端同点。
- 谁传递：DispatchContext 进 tool.call；codemode 工具执行器按 executeSubagentProvider 的方式（2398-2404）从 raw_context 还原。
- 嵌套准入入口：tool_admission.zig 新增 pub fn（如 requestNestedCodemodeCall(handle, arena, call)），内部：合成 ReviewTurnContext（照抄 974-983 的做法，origin = .codemode，target_call_id = 嵌套调用 id，trusted_root_context 取 ctx.root_user_intent_context，current_turn_untrusted_messages 取 ctx.current_turn_messages）→ requestPermissionOutcome(ctx.admissionInput(), ...) → 允许则 dispatchAuthorizedToolCall 走既有执行路径。每次脚本内调用完整重走准入，无旁路。

## 3. ReviewOrigin 设计

现状：封闭枚举 ReviewOrigin = enum { root, subagent }（src/core/permissions/auto_classifier.zig:248-251）；ReviewTurnContext.origin 字段（265）；视图选择 selectReviewView（1454-1462）：subagent 一律 .contextual，root 下 command/shell_input 走 .contextual、file_mutation 走 .normal、tool 仅 schema_required 时 .contextual。origin 的全部消费点：视图选择（1456）、trace 日志（458）、review_context_kind/review_origin 序列化（1612-1613）。影响面小：加变体只需改枚举 + selectReviewView + 测试。

评审视图建议：codemode 走 .contextual。理由：(a) 脚本内调用的周围证据（脚本文本、先前工具输出）是不受信文本，评审者需要 canonical root request 来区分用户意图与注入影响，这与 AGENTS.md 中 dynamic tools / subagent actions 拿 canonical root context 的规则一致；(b) 脚本编排的动作往往不是用户逐条请求过的，normal 视图缺少判断依据；(c) 与 subagent 同为「非 root 直接意图」的来源，语义上同侧。

脚本行号携带：建议编码进嵌套 ToolCall.id（如 <parent_call_id>:cm<seq>:L<line>）。id 在准入与评审全链路是不透明字符串（ReviewTurnContext.target_call_id:265、权限请求标签、trace 458），零契约改动；评审者在 target_call_id 里直接看到行号。若后续评审提示词需要结构化位置，再给 Action.tool 加字段，不阻塞本设计。

## 4. 线程与取消

线程现状核实：

- 权限 prompter：阻塞等在 worker 自己的 condvar 上。requestWorkerPermission → worker.requestPermissionBlockingWithReview（tool_admission.zig:2063-2070；worker_runtime.zig:2664-2672）→ 挂 worker_mutex 后把请求放进单个 pending 槽并 worker_cond.wait（worker_runtime.zig:2705-2731）。调用方是 worker 线程（第 2 节第 1-3 步，app_process_runtime.zig:165-187）。
- UI 如何得知并回复：UI 线程轮询 worker.snapshotState（app_worker_runtime.zig:709-760；worker_runtime.zig:2115-2120，取 worker_mutex），经 submitPermissionResponse 提交（worker_runtime.zig:2747-2759，同一把锁）。协议是「共享状态 + condvar + 锁」，不含 thread-local，不绑定具体线程。
- terminal 屏幕采集：managed_observer.inspectInput（managed_observer.zig:59-95）→ action_executor.execute（action_executor.zig:16-72）：admit 进队列后以 2ms 睡眠轮询 takeCompletionFor（mutex 保护，client.zig:385-395），循环内检查 cancel_flag（action_executor.zig:60-70）。terminal client 全部状态在 std.Io.Mutex 之下（client.zig:219 起）。无线程亲和性。

方案：证明可跨线程阻塞调用，不需要 channel 跳线。沙箱专用线程直接调用嵌套准入：(a) prompter 的阻塞等待只是 condvar 等待，任何线程合法；(b) 此时 worker 线程阻塞在外层工具调用里，同一 WorkerRuntime 上不存在并发准入，单 pending 槽（worker_runtime.zig:2705-2712）无冲突；(c) UI 侧 snapshotState/submit 只认锁不认线程。遗留核验项（进 GO 条件）：observation.Observer 的 wait_begin/wait_end 配对（permission_prompter.zig:34-46）目前只在 worker 线程触发，需确认其 emit 跨线程安全，否则把 observer 回调经 worker 线程转发。

取消：沙箱线程持有 cancel_flag = &worker.worker_cancel_requested（App 注入点 app_agent_runtime.zig:404；原子位定义 worker_runtime.zig:612），与既有路径同一原子，同一路径。进行中子工具调用的归宿：三选一取「等待完成 + 结果丢弃」。理由：fx 现有契约就是这样——dispatchAuthorizedToolCall 在调用返回后发现 cancel 置位即 deinit 结果并返回 error.Cancelled（tool_dispatch.zig:875-881）；子调用可能已产生不可逆副作用（文件写入、命令执行），中途中断会留下半完成状态且无法回滚，等待完成并丢弃结果既不放大副作用也不假装成功；长驻命令本身经由命令路径的 cancel 机制终止。等待中的权限提示被取消时，prompter 已把 wait_end 归类为 .cancelled（permission_prompter.zig:46）。

## 5. Corrupt 钉死证据（降级兼容三选一的决策输入）

代码事实（session 日志 = src/core/session_manager/）：

- 日志读取的折叠循环：src/core/session_manager/session.zig:1366-1370 —— const kind = line.header.kind orelse { state.last_seq = line.header.seq; // unknown kinds are skipped; state.clean_exit = false; continue; }：未知 kind 的行被跳过，不致命。
- 已知 kind 内解析失败：紧接的 1371 行 const body = schema.parseBody(...) catch return error.Corrupt：整次 openResume 失败。
- set 事件的 key 解析：src/core/session_manager/schema.zig:111 定义 SetKey = enum { prefs, title, permissions, usage, workspace, language, client_prompt, tool_identities, moved_files, compaction_records, v1_source }（11 个，无 codemode_store）；bodyOf 的 .set 分支用 f.req(SetKey, "key")（schema.zig:270）；req → opt → JSON 解析失败返回 error.BadBody（schema.zig:446-456）。未知 key 值在 std.json 的 enum 解析处失败 → BadBody → Corrupt。
- Corrupt 的下游：api.openResume 把 verdict corrupt 直接报 error.Corrupt（session_manager/session.zig:1243-1247），loadFolded 的 Corrupt 也原样上抛（1257-1263）；session_adapter.resumeError 把 error.Corrupt 映射为 error.InvalidSessionFormat（src/core/session/session_adapter.zig:4984）→ 老 fx 无法 resume 该会话。

测试钉死：.agents/tasks/T-6/codemode_store_corrupt_test.zig（运行方法见文件头注释，全部通过）：

1. std.meta.stringToEnum(SetKey, "codemode_store") == null。
2. parseBody(arena, .set, 未知 key 的字段串) 返回 error.BadBody，对照组 .title 正常解析。
3. 未知 kind 名同样不在 Kind 枚举中（对应 1366 行的跳过路径）；schema.zig 自带测试 "unknown kinds parse with a null kind" 佐证解析半边。

决策输入：若 codemode 的持久化事件走「set + 新 SetKey」，老 fx 读日志整体 Corrupt，会话不可 resume；若走「新 kind」，老 fx 按 1366-1370 跳过该行（代价仅 clean_exit=false）。降级兼容三选一的答案：新 kind 兼容，新 SetKey 不兼容。

## 6. GO 判定

**GO。**

理由：嵌套准入不需要新的借用通道——执行帧已持有完整 tool_runtime.Context，Context.admissionInput() 即可现造合法 Input（第 1 节表）；唯一缺口 ReviewTurnContext 有执行期合成的现成先例（MCP bridge，tool_runtime.zig:974-983）；句柄类型与传递完全复刻 run_command / subagent 后端模式，不引入第二执行路径；prompter 与屏幕采集按代码证据可跨线程阻塞（第 4 节）；取消接 worker_cancel_requested 同一原子，归宿定义为「等待完成 + 结果丢弃」，与既有 dispatch 契约一致。

风险与 GO 条件（不改变判定，列为实现前核验）：

1. observation.Observer 跨线程安全性未验证（permission_prompter.zig:34-46 的配对回调）。
2. selectReviewView 需为 .codemode 补测试（auto_classifier.zig:1464 已有同类测试可仿写）。
3. 持久化：codemode 会话事件若需落日志，必须用新 kind，不能用 set + 新 SetKey（第 5 节），否则老 fx 会话不可恢复。
4. 单 pending 权限槽意味着沙箱线程等待评审时，同一 agent 不能同时有第二个未决提示；当前 worker 线程此时必然阻塞在外层调用内，天然满足。
