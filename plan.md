# T-23b 方案 — codemode 超时的部分输出回传、长命令预算与轮询引导（ISSUE-23 差距清单 2-4 项）

只读方案，零 `src/` 改动。基线：分支 `T-23b-plan` @ `6d6ff8713`（含 23a merge `289303f4c`）。
每条结论给逐字锚点（`文件:行`）与会话记录数据，取舍与否决项单列。

## 结论先行

1. **部分输出通道（问 1）**：否决原候选 (a) 逐条 400B 与 (b) 写 host 捕获缓冲。改为
   **每个 script 调用一个 1KiB 固定摘录槽**，存"最近一次已完成嵌套调用"的结果文本，
   头尾保留 + 共享 omitted 标记，**只进失败体**，且新增节紧跟 headline。
2. **预算（问 2）**：默认 30s 与 `@options` 1000..120000 上下界都不动（`host.zig:21,30-32`），
   `clampRunScriptTimeout` 不动（`bridge.zig:403-410`）。数据说 95% 以上的嵌套命令在帽内，
   而真正超预算的两类（长命令、脚本内等人）都不是"默认值偏短"。
3. **轮询引导（问 3）**：只扩 23a 那一行 headline，合并为一段，不加新错误、不加控制面、
   不动 schema 文案预算。
4. **recovery/TLA（问 5）**：不动 `tests/tla/recovery/`，也不新增模型或驱动。
5. 顺带修一处**文案不实**（`builtins/tools.zig:743-744` 关于预算封顶嵌套命令的说法），
   并把"预算传递未减 remaining"记为遗留发现另开票，不并入本轮。

## 数据基线与评估口径

来源 `~/.fx/sessions/v2`（v2 会话记录，96 个会话，记录跨度 11-06 11:25 → 11-18 16:40）：

- 工具调用 2482 条；`codemode` 结果 1935 条：success 1650、failure 285。
- failure 分解：**Timeout 145（50.9%）**、ScriptError 119、缺 `script` 字段 12、
  `@options` 越界拒绝 4。与 ISSUE-23 的"约 51%"一致。
- **口径警告一（合入时间）**：嵌套摘要节 11-13 才合入（`5930aaf10` Close ISSUE-11），
  失败体头尾 11-17 才合入（`a8921136c` T-12）。所以"今天的行为"只能看 11-13 之后的
  **22 条超时样本**；全窗 145 条只用于分布趋势。109 条"裸 headline"全部属 11-13 前。
- **口径警告二（时长含义）**：`duration_ms` 含准入与人工权限等待
  （`tool_runtime.zig:1300-1303`、`bridge.zig:83-86`），**不等于命令运行时长**。
  摘录帽的参照量改用命令输出字节数。
- 失败体长度（全窗 145 条）：p50 31B（裸 headline）、p90 375B、max 4238B。

## 问 1 — 部分输出的通道

### 现状锚点

- 失败体只有三节：headline → `Partial output before failure` / `Console output before failure`
  （脚本自己的 `text()`/`console.log`）→ `Nested tool calls before failure (not undone):`
  状态行（`codemode_tool.zig:115-148`、`193-210`、标题常量 `:85`）。
- 状态行只有 `name/outcome/duration_ms`（`tool_runtime.zig:1297-1304`），
  32 条封顶 + overflow 标记（`:1306-1307`、`:1359-1366`），行缓冲 128B（`codemode_tool.zig:203`）。
- 脚本侧捕获缓冲只有 `text_buf`/`console_buf`，`takePartialOutput` 只搬这两条流
  （`host.zig:136-142`、`:168-178`）。
- **嵌套结果文本的生命周期**：`bridge.call` 拿到 `result.model_output` 后返回给脚本
  （`bridge.zig:189-193`），该文本随 `arena_state`/`result_arena_state` 一起在这次调用返回时
  释放（`bridge.zig:73-80`）。脚本没打印它就永久消失——这就是 ISSUE-23 现象的机制根因。

### 裁决：单槽摘录（候选 (a) 的改形）

| 维度 | 结论 |
| --- | --- |
| 谁拥有 | `CodemodeHostState` 新增一个固定缓冲槽（与 `nested_argument_error` 同处、同形，`tool_runtime.zig:1316-1329`、`:1354`）。写点：现有四次 `recordNestedCall`（`bridge.zig:153,168,183,189`），签名多带一段文本入参；`recordNestedCall` 存记录时顺带写槽。读点：**只有** `formatFailureBody`。渲染归 `codemode_tool.zig`。 |
| 帽多大 | 1024B 常量 `max_nested_output_excerpt_bytes`，与 `max_nested_call_records` 同放（`tool_runtime.zig:1306-1307` 旁）。参照量：直连 shell 命令落盘输出字节 n=291，p50 645B、p90 4211B、p95 6180B、max 39340B——1KiB 是"能认出卡在哪一步"的量级，不是全文回传（全文另有句柄回读）。 |
| 截断形状 | 走 `text_utils.writeHeadTailOmittedBounded(..., .down)`（`text_utils.zig:100-116`）写进固定 writer，标记常量即 ISSUE-12 的 `omitted_bytes_marker_template`（`text_utils.zig:73`），逐字节与 `shell.zig:38-48`、失败体现形同源。**注意** `NestedArgumentError.set` 今天是 head-only 截（`tool_runtime.zig:1324-1328`），新槽不照抄这一半。 |
| denied/failure 也带吗 | 带。denied 的文本是权限理由（`bridge.zig:152-155` → `deniedReason:627-639` → `deniedResult:676`），failure 的文本是 `tool_execution_failed` JSON 且已含 stderr 摘要（`command_result_mapping.zig:60-90`）——这两类正是"卡在哪"的信号，也受同一个帽。**清空**的情形：bridge 返回 error（`bridge.zig:167-169`）与规范化失败（现无结果文本，既有测试 `bridge.zig:1501` 已锁"records nothing"），置空即可，绝不允许上一条的摘录串到下一条记录上。第 33 条起 overflow 只翻标记不新增记录（`tool_runtime.zig:1360-1363`），槽同样冻结。 |
| 呈现位置 | 新节紧跟 headline，排在 `Partial output` 之前。理由与 23a 之前评审 F1 同源：存储预览只保 4KiB 头尾（`result_store.zig:16`、`previewText:641-646`），成功体摘要因此被挪到头部（`codemode_tool.zig:212-217`）；放最后最容易被预览切掉。 |
| 量级 | 见下方"否决 (a) 原形"。 |

为什么"最后一跳"就够：11-13 之后的 22 条超时样本 **22/22 都至少有一条已完成嵌套记录**，
其中 5 条只有 `ask_user_question`（人在答题），其余以 `run_command` 为主；全窗 145 条里
52 条（36%）是 `sleep`/循环形状。也就是说每条超时都有一个明确的"最后一次输出"，
没有任何一条需要同时看多条才判断得出来。

### 否决项

- **否决 (a) 原形（逐条 `NestedCallRecord` 带 400B 摘录）**：`nested_calls` 是 `[32]` 定长数组
  （`tool_runtime.zig:1350`），逐条 400B = 12.8KiB、逐条 1KiB = 32KiB，而 `CodemodeHostState`
  是**每一次工具调用**都构造的栈变量（`tool_runtime.zig:737`，宿主 `executeToolCallInner:672`）。
  同时 32×400B 也直接顶穿失败体的呈现预算（今天每流 4KiB，`codemode_tool.zig:83`）。
- **否决 (b)（嵌套结果同步进 host `text_buf`/`console_buf`）**：`appendSuccessOutput` 原样吐这两条流
  （`codemode_tool.zig:172-185`），于是成功路径会把同一条命令的输出打两遍，直接违反红线
  "部分输出只进失败体，不进成功路径"；还会抢占 1MiB 捕获帽与头尾预算，把脚本自己的
  `text()` 挤掉，并使 `takePartialOutput` 不再是纯脚本视角。
- **否决"只回传句柄、不回传摘录"**：句柄只在命令输出落盘时才存在，短输出没有句柄；
  而摘录本身天然把句柄带上（shell 信封 JSON 头部就带 `full_output_handle` 与 `duration_ms`，
  真机样本可见），`read_tool_result` 也已接受 `fx-command-replay-*.bin` 形态句柄
  （`read_tool_result.zig:386`、`:496`）。不需要第二条通道，零新增控制面。
- **否决"成功路径也带"**：红线。
- **诚实边界（必须写进 PR 描述）**：若超时那一刻命令本身被预算杀掉，`bridge` 收到的
  `model_output` 只有 `timeout=true` + cleanup 三行，**没有 stdout**
  （`command_result_mapping.zig:93-124`；已捕获的输出留在 replay capture 里，
  `tool_runtime.zig:2129-2144` 把它交给 `finishCommandToolResult` 而不进 `model_output`）。
  ISSUE-23 举的 `run_command: ok (31496ms)` 属"命令自己跑完了"那一类，本方案覆盖；
  "被杀那一类"要动 shell 层的超时结果，越出 codemode 边界，见"遗留发现 B"。

## 问 2 — 预算收口（数据）

### 结论

默认 30s **保持**，`@options` 界 1000..120000 **保持**，`clampRunScriptTimeout` **保持**
（`host.zig:21`、`:30-32`、`bridge.zig:403-410`）。本轮只改文案。

| 证据 | 数值 |
| --- | --- |
| 嵌套 `run_command` 记录时长（全部 codemode 体，n=779） | p50 3931ms、p90 15193ms、p95 27832ms、p99 36637ms、max 60017ms；**>30s 31 条（4.0%）、>120s 0 条** |
| 其余嵌套工具 | `read_file` n=126 p50 1ms；`write_file` n=43 p99 19405ms；`edit_file` n=25 max 2241ms；`grep_files` n=17 max 3386ms；`glob_files` n=11 max 12ms |
| 超时样本里 `run_command` 记录的最长 6 条（11-13 后，n=24） | 34424 / 36637 / 44534 / 46680 / 60013 / 60017ms |
| 另一类根本不是长命令 | 22 条里 **5 条只有 `ask_user_question`** 记录：43680 / 95575 / 172119 / 177109 / 337527ms（人在脚本里答题）。其中 3 条已把 `@options` 打到硬上限 120000，等待仍是 172119 / 177109 / 337527ms ⇒ 预算根本不封顶人工应答，抬帽或抬上限对这类零收益 |
| 用 `@options` 的极少 | 145 条超时里仅 3 条真在首个非空行声明 `@options`（全是 120000）；另有 **4 条因越界被拒**（声明 180000×2、300000×2），脚本一行没跑（`codemode_tool.zig:47`、`:921` 的越界文案） |
| 长命令的现成去处 | 直连 shell 命令时长 n=299：p50 109ms、p95 15732ms、max 368204ms（6 分钟级）；这条路由 shell 自己的 yield + interact 承接（`managed_execution_contract.zig:6-7`，run 的 yield 默认/上限都是 30000；interact 上限 300000，`builtins/tools.zig:105`），不需要 codemode 预算 |

**谁赢（`@options` vs ambient）**：不存在相争。`@options` 只决定脚本墙钟
（`effective_timeout_ms` + `timeout_from_options`，23a 已把来源写进 headline，
`codemode_tool.zig:24`、`:297`、`:447-452`），ambient 只是把这个墙钟往下传给嵌套命令
（`bridge.zig:58-62`）。所以本轮的取舍是"要不要改传法"，答案是**不改**（见遗留发现 A）。

### 遗留发现 A（建议单开 ISSUE，不并入 23b）

注释与文案都声称"嵌套 shell 运行拿到 `min(requested, remaining)`，停滞命令不会活过脚本 deadline"
（`bridge.zig:52-57`、`tool_runtime.zig:1340-1343`）。对 codemode 嵌套路径**不成立**：

- `applyAmbientBudget` 塞进去的是**整个预算**，不是剩余（`bridge.zig:58-62`；
  既有测试断言的正是整值 30_000，`bridge.zig:1396-1415`）。
- 减 remaining 的 `effectiveCommandTimeout`（`tool_runtime.zig:1936-1957`，配
  `command_timeout_started_ms`）只在 `run_command` 兼容后端里被用到
  （`executeRunCommandBackend:1377-1399`，注册入口 `:725-731`），而 codemode 嵌套调用被规范化成
  注册工具 `shell`（`bridge.zig:585-622`）。
- 那条路径读的是 `ctx.command_timeout_ms`，**从命令自己启动起算**（`src/tools/shell/shell.zig:673-676`），
  且脚本自带的 `timeout_ms` 会整个覆盖它；`command_timeout_started_ms` 在 `bridge.call` 的
  `executeToolCallAuthorized` 请求里根本没给字段（`bridge.zig:157-167`），并在
  `tool_runtime.zig:454` 被请求里的 null 覆盖。
- 后果实测可见：默认 30s 预算的脚本里出现 `run_command: ok (36637ms)`、`ok (44534ms)`，
  脚本墙钟超预算 22%–48%，23a 的 headline 会如实报 `Timeout after 44xxxms (budget 30000ms)`
  （这不是 23a 记的"高 ~2ms 粒度"问题，是同一处更大的量级）。

为什么不并入本轮：修它等于改"命令什么时候死"，属执行语义，红线明令不改；且收益是"少超预算"，
不改变模型能否看懂失败体。实现票先用**一次性真机探针**（不入库）确认形状：
`// @options: {"timeout_ms": 2000}` + `run_command({command:"sleep 8", timeout_ms:60000})`，
读实际 elapsed；若确为 ~8s 即坐实，再按 23a 的验证方式留证据开票。

### 遗留发现 B

被预算杀掉的命令，其**已捕获 stdout 不落 `model_output`**（`command_result_mapping.zig:93-124`）。
要让"编译到一半被杀"的日志可见，须在 shell 层的超时结果里带上保留输出或句柄提示
（replay capture 已在手，`tool_runtime.zig:2129-2144` + `execution_memory.zig:1239-1260` 的
`appendModelHandleNotice` 先例）。这属直连 shell 与 codemode 共用的失败体，影响面比 23b 大，
建议与发现 A 一并开票或单开一票，本轮明确不做。

## 问 3 — 轮询等待引导

裁决：**只改 23a 那一行 headline**（`codemode_tool.zig:447-452`），与现有 `@options` 提示合并成一段；
不加新错误类别、不加字段、不加 env/flag/setting、不给 schema 描述加段落。

通道比较（为什么是错误提示）：

- 文档：`fx.sh/docs` 在私有仓库（AGENTS.md「Documentation」），失败那一刻到不了模型；本轮仍在 PR
  描述写 Docs 段，但引导主体不能只靠它。
- schema 描述：`codemode_description` 已约 1.1k 字符、每个请求都付字节
  （`builtins/tools.zig:743-744`），而模型恰恰是在超时之后才需要这条指导；性价比负。
- 错误提示：一行、零常驻成本、23a 已有逐字 golden 可直接扩（`codemode_tool.zig:457-475`）。

建议文案（逐字交红测试钉死，仍是一行）：

```
codemode script failed: Timeout after {elapsed}ms (budget {budget}ms, from default|@options); raise it with // @options: {"timeout_ms": N} on the first script line, max 120000; for a wait or a long command, end the script and poll in a later call (shell interact on the running session) instead of sleeping in a loop
```

三个数据依据，正好对应三个新事实：

1. `max 120000`：4 条越界拒绝（180000/300000）说明模型不知道上限在哪。
2. `end the script and poll in a later call`：全窗 52/145（36%）是 `sleep`/循环形状；
   11-13 后 22 条里 5 条是在脚本里等人答题（打到 120000 上限也没用）。
3. `shell interact on the running session`：带 yield 的真机样本里，最后一次嵌套结果本身就是
   `{"state":"running","session_id":"shell-…"}`；问 1 的摘录正好把它送到模型眼前，引导才有落点。
   脚本面无法自己续查——`run_command` 拒绝 `action != "run"`（`bridge.zig:595-602`），
   轮询只能在 codemode 外用注册工具 `shell` 的 interact。

明确不做：按记录形状条件化文案（要不要出现 poll 一句）。一个语义分支换一行提示不值，
且红线要求"只许一行级别"。

## 问 4 — 测试钉力（最小断言清单）

红绿成对，全部逐字 golden；`zig fmt --check src/ && zig build test` 为门。

1. **摘录槽本体**（`tool_runtime.zig`，紧接现有 `recordNestedCall` 测试 `:2937-2947`）
   - 短文：逐字存下，`text` 等于输入。
   - 长文：头尾哨兵都在，共享 omitted 标记出现且数字等于真丢字节（对齐 ISSUE-12 金样形状）。
   - 空文本清空槽：先存 A、再记一条无文本记录，读回必须为空（**串条**是这里的唯一危险）。
   - 第 33 条：只翻 overflow 标记，槽冻结在第 32 条内容上。
   - **尺寸哨兵**：`@sizeOf(CodemodeHostState)` 上限断言，挡住"逐条 400B/1KiB"复活；
     同时 `NestedArgumentError` 既有测试不动，证明两顶帽互不寄生。
2. **bridge 归属**（`bridge.zig`，接 `:1453` 起 outcome/`:1491` 起 duration/`:1501` records nothing 那一组）
   - ok 路径：槽内容 = 返回给脚本的 `model_output` 头尾；shell 信封的 `full_output_handle` 在头部可见。
   - denied 路径：槽 = `deniedReason` 文本；failure 路径：槽 = `tool_execution_failed` JSON。
   - error 返回路径：槽被清空（与 `:1501` 同形）。
3. **失败体渲染**（`codemode_tool.zig`，扩现有 `:501`、`:528`、`:548`、`:657`、`:696` 金样组）
   - 新节紧跟 headline、排在 `Partial output` 之前；标题行逐字
     `Last nested output before failure (run_command, ok, 31496ms):`。
   - 槽为空 ⇒ 失败体**逐字节等于今天**（现有金样只因顺序改动而改，不因内容改动而改）。
   - **成功体逐字节不变**：现有 `:577/:596/:621/:635/:675/:728/:759` 零 diff ⇒ 红线"不进成功路径"由测试守。
   - 分配失败降级：拼不上摘录节时退回不含该节的体，整体绝不失败（照 `:696` 的 sweep 形状）。
   - headline 新文案 golden（含 `max 120000` 与 poll 一句），`:457`/`:467` 两态仍逐字。
4. **e2e**（`tests/e2e/codemode-admission.test.ts`，沿用 23a 的网关夹具与 `:308` 那条 partial-output 测的形状）
   - 正例：真机 `fx ask --quiet --json --no-save`，脚本先 `run_command` 跑一条打印唯一哨兵的短命令，
     再跑一条必然越过 `@options` 预算的命令且不打印结果；断言第二个请求里该 tool-call 的
     tool-result 文本**逐字含哨兵**、含 `Last nested output before failure` 标题、含 `- run_command: ok (` 状态行。
   - 反例：哨兵命令输出远超帽时断言 omitted 标记出现且体长度有界（防"摘录无界"回归）。
   - 现有两条预算测试（`:231-268`、23a 新增的 `@options` 那条）只随文案改断言；
     时序窗 `20s < elapsed < 45s`（`:247-248`）保持不变。
   - 接线：新增测试在**已分类文件内**，分类继承，无需改 `scripts/pgso/corpus.json`；
     文件已有 `tests/e2e/ci-shard-weights.json` 权重；测试不分支平台，故不进
     `tests/e2e/macos-platform-tests.json`。
5. **不需要动的测试面**：无新 parser/命令词形 ⇒ 无 fuzz target、无 `tests/fuzz/targets.json` 条目、
   无 shell parity；无准入/权限变化 ⇒ 权限金样不动；无 catalog/目录面变化 ⇒ `catalog.zig` 与
   `context_limits` 测试不动；无 TLA 变化（问 5）。

## 问 5 — recovery / TLA 边界

**不需要动 `tests/tla/recovery/`**，也不需要新 cfg 或驱动。理由：

- recovery 只建模**单条模型请求**的事件阶梯与重试/等待决定，本身不做 I/O、不读时钟、
  不分配（`src/core/recovery/recovery.zig:1-16`，配 `NeverGivesUp`/`Heals`）。
- codemode 超时始终是**一次工具结果的失败**，交回模型后同一条请求继续；既有 e2e 已钉住
  "fx 退出 0 且失败体进第二个请求"这一形态（`tests/e2e/codemode-admission.test.ts:240-258`），
  与 T-20 方案问 5 的裁决同构（本文件历史版本 `plan.md` 问 5 段，commit `e0b937070`）。
- 摘录只改失败体的字节内容：不新增状态、不新增持久化、不新增时钟读取、不改"是否重试/何时重试/存什么"。
- 也不触及 `src/core/recovery/` 的 CI 边界脚本（`scripts/check-recovery-boundary.sh`）与
  compactor/indexer/agents 边界（本轮改动全在 `src/tools/codemode/` + `src/core/tooling/tool_runtime.zig` +
  `src/builtins/tools.zig` 的一行描述）。

若后续要建模"命令被预算杀掉时保留输出"（遗留发现 B），那是 shell 执行生命周期，
仍归 shell 运行时而非 recovery；要动 TLA 请先开票论证。

## 红线合规

- **不改准入/权限/`parity_review_free_commands`/catalog**：摘录是纯渲染，写点在记录之后，
  不改变任何一次调用是否被接受、被审或被免审。
- **不改执行语义**：超时仍杀整树、仍是工具失败；`clampRunScriptTimeout`、`host.zig:21/30-32`、
  ambient 传法一律不动（发现 A 只记不改）。
- **部分输出只进失败体**：读点只有 `formatFailureBody`；成功体金样零 diff 由测试守（问 4.3）。
- **帽与截断标记对齐 ISSUE-12**：同一个 `omitted_bytes_marker_template`
  （`text_utils.zig:73`）与 `writeHeadTailOmittedBounded`（`:100-116`），与 `shell.zig:38-48`、
  失败体现形逐字节同源。
- 零新增控制面（无 env / flag / setting / JSON 字段）。
- 启动延迟零影响（不在启动路径）；体积增量 = 一行文案 + 一节渲染 + 1KiB 定长缓冲，
  交 `.github/workflows/binary-size.yml` 观察位。
- 本方案零个人路径；数据只报聚合数与字段名。

## 落地顺序（给实现票）

1. 红：问 4.1 / 4.2 / 4.3 单元金样（含尺寸哨兵与成功体零 diff）。
2. 绿：`tool_runtime.zig` 加帽 + 槽 + `recordNestedCall` 文本入参；`bridge.zig` 四个写点；
   `codemode_tool.zig` 新节与顺序。
3. 红→绿：headline 一行（含 `max 120000` 与 poll 引导），扩 `:457`/`:467` 两态 golden。
4. `builtins/tools.zig:743-744` 描述改准（发现 A 的文案部分）：预算是脚本墙钟；
   嵌套命令只在自己不带 `timeout_ms` 时按预算封顶。
5. e2e：`codemode-admission.test.ts` 正反两条（真机 `fx ask` 哨兵逐字可见）。
6. 一次性真机探针（不入库）：坐实发现 A 的 elapsed 形状，读数写进 impl-report；
   据此开"嵌套预算传递收口"与"超时命令保留输出"两张 ISSUE。
7. 收尾：`zig fmt src/`、`zig build test`、`./zig-out/bin/fx` 真机跑一条超时脚本眼看新节；
   PR 描述写 Docs 段（`fx.sh/docs` codemode 页补超时/预算/轮询一段）；
   `issues/ISSUE-23.md` 勾掉差距清单第 2、4 项，第 3 项记为"数据判定不改，另票"。
