# T-23b 方案 — codemode 超时的部分输出回传、长命令预算与轮询引导（ISSUE-23 差距清单 2-4 项）

只读方案，零 `src/` 改动。基线：分支 `T-23b-plan` @ `6d6ff8713`（含 23a merge `289303f4c`）。
本版为评审 `review-plan.md`（`be329fac1`，T-23b-review）后的修订版，修订项与两处不采纳理由见末节。
每条结论给逐字锚点（`文件:行`）与会话记录数据，取舍与否决项单列。

## 结论先行

1. **部分输出通道（问 1）**：否决原候选 (a) 逐条 400B 与 (b) 写 host 捕获缓冲。改为
   **每个 script 调用一个 1KiB 固定摘录槽**，存"最近一次**已返回**的嵌套调用"的 `model_output`
   头尾，**只进失败体**，新增节紧跟 headline。覆盖面不靠"命令跑完"这一侥幸：
   被预算杀掉的嵌套调用同样返回一份带 `output_delta` 的 shell 快照（问 1"覆盖矩阵"），
   而 QuickJS 的 deadline 只能在 JS 指令之间触发，**永远不会跳过在飞的那一条**。
2. **预算（问 2）**：默认 30s 与 `@options` 1000..120000 上下界都不动（`host.zig:21`、`:30-32`），
   `clampRunScriptTimeout` 不动（`bridge.zig:403-410`）。875 条嵌套 `run_command` 里 p95 27.4s、
   p99 37.2s、0 条超过 120s；而 3 条把 `@options` 打到硬上限 120000 的脚本仍超时，因为等的是人。
3. **轮询引导（问 3）**：只扩 23a 那一行 headline，合并成一段，不加新错误、不加控制面、
   不给 schema 描述加段落。
4. **recovery/TLA（问 5）**：不动 `tests/tla/recovery/`，也不新增模型或驱动。
5. 顺带修一处**文案不实**（`builtins/tools.zig:743-744`），且**净字数不得增长**（C4）；
   把"ambient 未减 remaining"记为遗留发现 A 另开票。

## 数据基线与评估口径

来源 `~/.fx/sessions/v2`（v2 会话记录）。**语料是活的**：本轮方案与评审自身的 codemode 调用
也在写入，故所有数字按**扫描时刻 2026-11-18 19:22（+08:00）** 计，并记录级去重
（同一 `(session, seq, type, call_id)` 只算一次，崩溃恢复会重复追加）。

- 会话 101 个；`tool_call` 2610 条、`tool_result` 2599 条；`codemode` 结果 2062 条。
- `codemode` failure 298 条：**Timeout 148（49.7%）**、ScriptError 133、缺 `script` 字段 12、
  `@options` 越界拒绝 5。与 ISSUE-23 的"约 51%"同量级。
- **口径警告一（合入时间）**：嵌套摘要节 11-13 才合入（`5930aaf10` Close ISSUE-11），
  失败体头尾 11-17 才合入（`a8921136c` T-12）。"今天的行为"只看 11-13 09:56 之后的
  **25 条超时样本**；全窗 148 条只用于分布趋势。裸 headline（无摘要节）样本全部落在 11-13 前。
- **口径警告二（时长含义）**：`duration_ms` 含准入与人工权限等待
  （`tool_runtime.zig:1300-1303`、`bridge.zig:83-86`），**不等于命令运行时长**，
  所以时长分位数是上界。摘录帽的参照量改用命令输出字节数。
- 失败体长度（全窗 148 条）：p50 31B（裸 headline）、p90 375B、max 4238B。

## 问 1 — 部分输出的通道

### 现状锚点：文本在哪里生、在哪里死

- 失败体只有三节：headline → `Partial output before failure` / `Console output before failure`
  （脚本自己的 `text()`/`console.log`）→ `Nested tool calls before failure (not undone):`
  状态行（`codemode_tool.zig:115-148`、`193-210`、标题常量 `:85`）。
- 状态行只有 `name/outcome/duration_ms`（`tool_runtime.zig:1297-1304`），32 条封顶 + overflow
  （`:1306-1307`、`:1359-1366`），行缓冲 128B（`codemode_tool.zig:203`）。
- 脚本侧捕获缓冲只有 `text_buf`/`console_buf`，`takePartialOutput` 只搬这两条流
  （`host.zig:136-142`、`:168-178`）。
- **嵌套调用走哪条执行路径（评审 C1 的机制要害）**：`canonicalRunCommand` 把脚本面
  `run_command` 归一化为**注册工具 `shell`**（`bridge.zig:585-622`）⇒
  `executeToolCallAuthorized`（`bridge.zig:157-170`）⇒ `shell_impl.call` ⇒ `callRun`
  （`src/tools/shell/shell.zig:614`，超时值取 `:673-676`）⇒ `finishPrepared` ⇒
  `formatSnapshotWithLimit`（`:1626-1697`）⇒ `formatSnapshotRaw`（`:1828-1883`）。
  快照 JSON 带 `state` / `session_id` / `duration_ms` / `full_output_handle` / `"error"` /
  **`output_delta`（已截到 `max_tool_result_bytes`，超限用头尾+句柄提示）**。
  **它不经过 `Command.timeoutFailure`**：那个无 stdout 的 stub 只挂在 `toolRunCommand`
  （`tool_runtime.zig:2129-2144` + `command_result_mapping.zig:93-124`），服务的是
  `run_command` 兼容后端（`executeRunCommandBackend:1377-1399`，入口 `:725-731`），
  codemode 嵌套调用永远到不了那里。
- **在飞的那一条一定会先返回**：deadline 只在 QuickJS 指令边界触发
  （`host.zig:631-648` 的 `interruptHandler` 与 `:269-321` 的检查点）。脚本阻塞在同步
  bridge 回调里时没有 JS 指令可中断，因此嵌套调用先返回、先 `recordNestedCall`
  （`bridge.zig:189`），脚本随后才死在下一个指令边界。

### 覆盖矩阵：三种形态各自往槽里放什么

| 形态 | 触发条件 | 记录 outcome | 槽里的内容 |
| --- | --- | --- | --- |
| 命令正常跑完 | 命令时长 < 其超时 | `ok` | 完整 `output_delta`（超限则快照自己已头尾截 + 句柄） |
| 等待到点仍在跑 | 默认 `yield_time_ms` 30s（`managed_execution_contract.zig:6-7`）先于超时 | `ok`（`.running` 不算失败，`shell.zig:1899-1910`） | `state:"running"` + `session_id` + 已产出的 `output_delta` + 句柄 |
| 被自己的 `timeout_ms` 杀 | `error.TimeoutExpired` ⇒ `.stopped`（`managed_execution.zig:1600-1605`）⇒ `snapshotFailed` | `failure` | `"error":"TimeoutExpired"` + 已产出的 `output_delta` + 句柄 |

第三行正是评审担心的"在飞那一条没有输出"：它**有**输出，因为 shell 快照本来就把已捕获字节
留在 body 里，`timeoutFailure` stub 不在这条路上。ISSUE-23 举的 `run_command: ok (31496ms)`
是第二行（30s 时 yield 返回 running，记为 ok），也是本方案覆盖的形态。

真实残余限制（写进 PR 描述，不粉饰）：

- 槽是 1KiB 摘录，不是全文；全文仍在 `full_output_handle` 指向的落盘件里，
  `read_tool_result` 已接受 `fx-command-replay-*.bin` 形态句柄（`read_tool_result.zig:386`、`:496`）。
- 脚本死在纯 JS 计算（没有嵌套调用）时槽为空。11-13 后 25 条样本里这种形态 **0 条**。
- 记录行的 `ok` 不等于"命令成功"（第二行），真相在摘录的 `state` / `"error"` 字段里。
  本轮不改 outcome 语义（红线：不改执行语义），靠摘录把真相送到模型眼前。

### 25 样本逐条探针（评审 C1 要求的核对）

会话记录**不存**嵌套调用的 `model_output`（2482→2610 条 `tool_call` 里 `codemode-nested-*`
为 0 条，已实测），所以逐条核对只能按：该样本最后一条已完成记录的 `name/outcome/duration_ms`
+ 脚本里最后一条 `command` 字面量 + 失败体是否已引用过快照 JSON 三者合判，
**属上界推断，实现票须用真机一次运行坐实**。结果（11-13 09:56 后，n=25，每条 ≥1 条记录）：

| 槽内容判定 | 条数 | 说明 |
| --- | --- | --- |
| 高价值：命令输出 | **17** | 最后一条是 `run_command` 且命令有产出（`gh release download`、`sh install.sh 2>&1 \| tail -45`、`swift ocr_vision.swift`、`curl -sL --max-time 45 …`、`git clone …` 等） |
| 高价值：拒绝/失败理由 | **3** | `run_command: denied (60010/60013/60017ms)`，槽里是 `deniedReason` 文本 ⇒ "卡在权限" |
| 低价值：人工答案文本 | **5** | 只有 `ask_user_question` 记录（43680/95575/172119/177109/337527ms），答案已在脚本 `text()` 里，摘录增量近零 |
| 近空：裸 `sleep` | **0** | 评审推测的"循环形状最后一次是 `sleep`"未成立：轮询脚本把 `sleep` 与检查命令**交替**发，最后一条是检查命令（`tail -2 log`、`ps -ef \| grep`），有产出 |

⇒ 20/25（80%）槽内容有诊断价值，5/25（20%）是人工答案形态，那 5 条该由问 3 的 headline
文案负责，不该由摘录负责。方案不再宣称"单槽覆盖全部"，只宣称"覆盖除人工等待外的全部形态，
且覆盖不依赖发现 A 的越预算行为"。

### 裁决：单槽摘录

| 维度 | 结论 |
| --- | --- |
| 谁拥有 | `CodemodeHostState` 新增一个固定缓冲槽（与 `nested_argument_error` 同处、同形，`tool_runtime.zig:1316-1329`、`:1354`）。写点：现有四次 `recordNestedCall`（`bridge.zig:153,168,183,189`），签名多带一段文本入参；`recordNestedCall` 存记录时顺带写槽。读点：**只有** `formatFailureBody`。渲染归 `codemode_tool.zig`。 |
| 取哪份文本 | `result.model_output`，**不取** `shellResult(...)` 编码后的串（`bridge.zig:190-193`）：后者多一层 JSON 转义，会把 1KiB 预算吃在转义上。三种形态（覆盖矩阵）都落在这一个字段上，所以槽只有一条规则、零分支。 |
| 帽多大 | 1024B 常量 `max_nested_output_excerpt_bytes`，与 `max_nested_call_records` 同放（`tool_runtime.zig:1306-1307` 旁）。参照量：命令落盘输出字节 n=292，p50 645B、p90 4211B、p95 6180B、max 39340B ⇒ 1KiB 保住中位全量、p90 约留 1/4，定位是"认出卡在哪一步"，全文靠句柄回读。 |
| 截断形状 | `text_utils.writeHeadTailOmittedBounded(..., .down)`（`text_utils.zig:100-116`）写进固定 writer，标记即 ISSUE-12 的 `omitted_bytes_marker_template`（`text_utils.zig:73`）。失败体的头尾形状先例是 `codemode_tool.zig:101-110`（`appendFailureOutputHead`），同款标记的第二处使用者是 `src/tools/codemode/shell.zig:38-48`（`encodeResultJson`）。**注意** `NestedArgumentError.set` 今天是 head-only 截（`tool_runtime.zig:1324-1328`），新槽不照抄这一半。 |
| denied/failure 也带吗 | 带。denied 的文本是权限理由（`bridge.zig:152-155` → `deniedReason:627-639` → `deniedResult:676`），failure 的文本是命令失败 JSON 且已含 stderr 摘要（`command_result_mapping.zig:60-90`）——25 样本里 3 条靠它。**清空**的情形：bridge 返回 error（`bridge.zig:167-169`）与规范化失败（无结果文本，既有测试 `bridge.zig:1501` 起已锁"records nothing"），置空即可，绝不允许上一条串到下一条。第 33 条起 overflow 只翻标记不新增记录（`tool_runtime.zig:1360-1363`），槽同样冻结。 |
| 呈现位置 | 新节紧跟 headline，排在 `Partial output` 之前。理由与评审 F1 同源：存储预览只保 4KiB 头尾（`result_store.zig:16`、`previewText:641-646`），成功体摘要因此被前置（`codemode_tool.zig:212-217`）；放最后最容易被预览切掉。 |
| 量级 | 见下方"否决 (a) 原形"。 |

### 否决项

- **否决 (a) 原形（逐条 `NestedCallRecord` 带 400B 摘录）**：`nested_calls` 是 `[32]` 定长数组
  （`tool_runtime.zig:1350`），逐条 400B = 12.8KiB、逐条 1KiB = 32KiB，而 `CodemodeHostState`
  是**每一次工具调用**都构造的栈变量（`tool_runtime.zig:737`，宿主 `executeToolCallInner:672`）。
  同时 32×400B 也顶穿失败体的呈现预算（今天每流 4KiB，`codemode_tool.zig:83`）。
- **否决 (b)（嵌套结果同步进 host `text_buf`/`console_buf`）**：`appendSuccessOutput` 原样吐这两条流
  （`codemode_tool.zig:172-185`），成功路径会把同一条命令的输出打两遍，直接违反红线
  "部分输出只进失败体，不进成功路径"；还会抢占 1MiB 捕获帽与头尾预算，把脚本自己的
  `text()` 挤掉，并使 `takePartialOutput` 不再是纯脚本视角。
- **否决"只回传句柄、不回传摘录"**：短输出没有句柄；而摘录本身天然把句柄带上
  （快照 JSON 头部就有 `full_output_handle` 与 `duration_ms`，`shell.zig:1872-1876`）。
  不需要第二条通道，零新增控制面。
- **否决"成功路径也带"**：红线。
- **否决"为被杀命令改 shell 超时结果"**：本问的"覆盖矩阵"已证 codemode 形态不需要它；
  仍缺输出的只有 `run_command` 兼容后端那条 stub 路径，见遗留发现 B。

## 问 2 — 预算收口（数据）

### 结论

默认 30s **保持**，`@options` 界 1000..120000 **保持**，`clampRunScriptTimeout` **保持**
（`host.zig:21`、`:30-32`、`bridge.zig:403-410`）。本轮只改文案。

| 证据 | 数值 |
| --- | --- |
| 嵌套 `run_command` 记录时长（全部 codemode 体，n=875） | p50 4141ms、p90 14450ms、p95 27448ms、p99 37247ms、max 60017ms；**>30s 34 条（3.9%）、>120s 0 条** |
| 其余嵌套工具 | `read_file` n=177 p50 1ms；`glob_files` n=54 p99 26ms；`write_file` n=43 p95 4228ms、max 19405ms；`grep_files` n=28 max 3386ms；`edit_file` n=25 max 2241ms |
| 超时样本里 `run_command` 记录的最长 7 条（11-13 后，共 29 条记录） | 34424 / 36637 / 44534 / 46680ms 为 `ok`；60010 / 60013 / 60017ms 为 `denied`（权限等待，不是命令时长） |
| 另一类根本不是长命令 | 25 条里 **5 条只有 `ask_user_question`** 记录：43680 / 95575 / 172119 / 177109 / 337527ms。其中 3 条已把 `@options` 打到硬上限 120000，等待仍是 172119 / 177109 / 337527ms ⇒ 预算不封顶人工应答，抬帽或抬上限对这类零收益 |
| 用 `@options` 的极少 | 148 条超时里仅 3 条在首个非空行声明 `@options`（全是 120000）；另有 **5 条因越界被拒**（声明 180000×2、300000×2 等），脚本一行没跑（`codemode_tool.zig:47`、`:921` 的越界文案） |
| 长命令的现成去处 | 直连 shell 命令时长 n=300：p50 109ms、p95 15732ms、max 368204ms；这条路由 shell 自己的 yield + interact 承接（`managed_execution_contract.zig:6-7`，run 30000；interact 上限 300000，`builtins/tools.zig:105`），不需要 codemode 预算 |

**谁赢（`@options` vs ambient）**：不存在相争。`@options` 只决定脚本墙钟
（`effective_timeout_ms` + `timeout_from_options`，23a 已把来源写进 headline，
`codemode_tool.zig:24`、`:297`、`:447-452`），ambient 只是把这个墙钟往下传给嵌套命令
（`bridge.zig:58-62`）。所以本轮的取舍是"要不要改传法"，答案是**不改**（见发现 A）。

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
  `executeToolCallAuthorized` 请求里根本没给字段（`bridge.zig:157-170`），并在
  `tool_runtime.zig:454` 被请求里的 null 覆盖。
- 后果实测可见：默认 30s 预算的脚本里出现 `run_command: ok (36637ms)`、`ok (44534ms)`，
  脚本墙钟超预算 22%–48%，23a 的 headline 会如实报 `Timeout after 44xxxms (budget 30000ms)`
  （这不是 23a 记的"高 ~2ms 粒度"问题，是同一处更大的量级）。

为什么不并入本轮：修它等于改"命令什么时候死"，属执行语义，红线明令不改。
**且 23b 的摘录覆盖面不依赖它**：修好之后长命令退化为覆盖矩阵第三行
（`"error":"TimeoutExpired"` 的快照，仍带 `output_delta`），摘录照样有内容。
实现票用一次性真机探针坐实（不入库）：
`// @options: {"timeout_ms": 2000}` + `run_command({command:"sleep 8", timeout_ms:60000})`，
读实际 elapsed；若确为 ~8s 即坐实，再按 23a 的验证方式留证据开票。

### 遗留发现 B（范围已按评审 C1 重划）

无 stdout 的超时 stub **只在 `run_command` 兼容后端**：`Command.timeoutFailure` 造的
`model_output` 只有 `timeout=true` + cleanup 三行，已捕获字节留在 replay capture 里
（`command_result_mapping.zig:93-124`、`tool_runtime.zig:2129-2144`，
`Capture` 由调用方负责 `retainRequired`/`abort`，`command_replay_store.zig:659-676`、`:773-781`，
而该 stub 路径不给句柄提示，句柄提示的先例是 `appendModelHandleNotice`
`command_replay_store.zig:22-39` + `execution_memory.zig:1239-1260`）。
codemode 嵌套调用不经此处（问 1 锚点已证），所以 **B 不是 23b 的前置，也不影响摘录覆盖率**。
另记一处同源隐患：`bridge.call` 不消费 `result.command_replay_capture`
（`bridge.zig:157-193`，`ToolExecutionResult` 无 `deinit`，`tool_contracts.zig:94-119`），
若某条嵌套路径确实造出 `Capture`，其 spool 件无人 `abort`/`retain`。留给 B 票一并核。

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

1. `max 120000`：5 条越界拒绝（180000 / 300000）说明模型不知道上限在哪。
2. `end the script and poll in a later call`：全窗 53/148（36%）是 `sleep`/循环形状；
   11-13 后 25 条里 5 条是在脚本里等人答题（打到 120000 上限也没用）。
3. `shell interact on the running session`：yield 到点的形态就是
   `{"state":"running","session_id":"shell-…"}`（覆盖矩阵第二行）；问 1 的摘录正好把它送到模型眼前，
   引导才有落点。脚本面无法自己续查——`run_command` 拒绝 `action != "run"`（`bridge.zig:595-602`），
   轮询只能在 codemode 外用注册工具 `shell` 的 interact。

明确不做：按记录形状条件化文案（要不要出现 poll 一句）。一个语义分支换一行提示不值，
且红线要求"只许一行级别"。

## 问 4 — 测试钉力（最小断言清单）

红绿成对，全部逐字 golden；`zig fmt --check src/ && zig build test` 为门。

1. **摘录槽本体**（`tool_runtime.zig`，紧接现有 `recordNestedCall` 测试 `:2937-2947`）
   - 短文：逐字存下，`text` 等于输入。
   - 长文：**头哨兵与尾哨兵都在**，共享 omitted 标记出现且数字等于真丢字节。
   - 空文本清空槽：先存 A、再记一条无文本记录，读回必须为空（**串条**是这里的唯一危险）。
   - 第 33 条：只翻 overflow 标记，槽冻结在第 32 条内容上。
   - **三种形态各一条**（对齐覆盖矩阵）：`ok` 完整 / `ok` + `"state":"running"` +
     `session_id` / `failure` + `"error":"TimeoutExpired"`，断言后两者仍带 `output_delta` 片段。
   - **尺寸哨兵**：`@sizeOf(CodemodeHostState)` 上限断言，挡住"逐条 400B/1KiB"复活；
     `NestedArgumentError` 既有测试不动，证明两顶帽互不寄生。
2. **bridge 归属**（`bridge.zig`，接 `:1453` outcome / `:1491` duration / `:1501` records nothing 那一组）
   - ok 路径：槽内容 = `result.model_output` 头尾（**不是** `shellResult` 编码串）；
     `full_output_handle` 在头部可见。
   - denied 路径：槽 = `deniedReason` 文本；failure 路径：槽 = 命令失败 JSON。
   - error 返回路径：槽被清空（与 `:1501` 同形）。
3. **失败体渲染**（`codemode_tool.zig`，扩现有 `:501`、`:528`、`:548`、`:657`、`:696` 金样组）
   - 新节紧跟 headline、排在 `Partial output` 之前；标题行逐字
     `Last nested output before failure (run_command, ok, 31496ms):`。
   - 槽为空 ⇒ 失败体**逐字节等于今天**（现有金样只因顺序改动而改，不因内容改动而改）。
   - **成功体逐字节不变**：现有 `:577/:596/:621/:635/:675/:728/:759` 零 diff ⇒ 红线由测试守。
   - 分配失败降级：拼不上摘录节时退回不含该节的体，整体绝不失败（照 `:696` 的 sweep 形状）。
   - headline 新文案 golden（含 `max 120000` 与 poll 一句），`:457`/`:467` 两态仍逐字。
4. **e2e**（`tests/e2e/codemode-admission.test.ts`，沿用 23a 的网关夹具与 `:308` 那条 partial-output 测的形状）
   - 正例：真机 `fx ask --quiet --json --no-save`，脚本先 `run_command` 跑一条打印唯一哨兵的短命令，
     再跑一条必然越过 `@options` 预算的命令且不打印结果；断言第二个请求里该 tool-call 的
     tool-result 文本**逐字含哨兵**、含 `Last nested output before failure` 标题、含 `- run_command: ok (` 状态行。
   - 反例（帽与截断）：嵌套输出远超 1KiB 时，断言 omitted 标记出现、体长度有界，
     **且尾部哨兵仍在**（`TAIL-SENT` 级断言，不是只查标记）。理由同 C2：shell 信封头部
     （`state`/`session_id`/`full_output_handle`/`duration_ms`）吃掉头预算，真进度在中段与尾部，
     "卡在哪一行"靠尾哨兵证明；单测金样只钉住切分算法，钉不了这条真实信封。
   - 现有两条预算测试（`:231-268`、23a 新增的 `@options` 那条）只随文案改断言；
     时序窗 `20s < elapsed < 45s`（`:247-248`）保持不变。
   - 接线：新增测试在**已分类文件内**，分类继承，无需改 `scripts/pgso/corpus.json`；
     文件已有 `tests/e2e/ci-shard-weights.json` 权重；测试不分支平台，故不进
     `tests/e2e/macos-platform-tests.json`。按 AGENTS.md，PR 描述里带一句"复核既有分类仍匹配
     该文件产品角色"的结论（C4 注意 2）。
5. **不需要动的测试面**：无新 parser/命令词形 ⇒ 无 fuzz target、无 `tests/fuzz/targets.json` 条目、
   无 shell parity；无准入/权限变化 ⇒ 权限金样不动；无 catalog/目录面变化 ⇒ `catalog.zig` 与
   `context_limits` 测试不动；无 TLA 变化（问 5）。

## 问 5 — recovery / TLA 边界

**不需要动 `tests/tla/recovery/`**，也不需要新 cfg 或驱动。理由：

- recovery 只建模**单条模型请求**的事件阶梯与重试/等待决定，本身不做 I/O、不读时钟、
  不分配（`src/core/recovery/recovery.zig:1-16`，配 `NeverGivesUp`/`Heals`）。
- codemode 超时始终是**一次工具结果的失败**，交回模型后同一条请求继续；既有 e2e 已钉住
  "fx 退出 0 且失败体进第二个请求"这一形态（`tests/e2e/codemode-admission.test.ts:240-258`），
  与 T-20 方案问 5 的裁决同构（本文件历史版本问 5 段，commit `e0b937070`）。
- 摘录只改失败体的字节内容：不新增状态、不新增持久化、不新增时钟读取、不改"是否重试/何时重试/存什么"。
- 也不触及 `scripts/check-recovery-boundary.sh` 与 compactor/indexer/agents 边界
  （本轮改动全在 `src/tools/codemode/` + `src/core/tooling/tool_runtime.zig` +
  `src/builtins/tools.zig` 的一行描述）。

若后续要动 `Command.timeoutFailure` 的字节（发现 B），那是 shell 执行生命周期，
仍归 shell 运行时而非 recovery；要动 TLA 请先开票论证。

## 红线合规

- **不改准入/权限/`parity_review_free_commands`/catalog**：摘录是纯渲染，写点在记录之后，
  不改变任何一次调用是否被接受、被审或被免审。denied 文本进失败体不新增暴露
  （该文本本就随 `deniedResult` 返回给脚本）。
- **不改执行语义**：超时仍杀整树、仍是工具失败；`clampRunScriptTimeout`、`host.zig:21/30-32`、
  ambient 传法、`outcome` 映射一律不动（发现 A/B 只记不改）。
- **部分输出只进失败体**：读点只有 `formatFailureBody`；成功体金样零 diff 由测试守（问 4.3）。
- **帽与截断标记对齐 ISSUE-12**：同一个 `omitted_bytes_marker_template`（`text_utils.zig:73`）
  与 `writeHeadTailOmittedBounded`（`:100-116`）。使用者两处：失败体
  `codemode_tool.zig:101-110`、脚本面 shell 结果 `src/tools/codemode/shell.zig:38-48`。
  **不声称与直连 shell 工具同源**：`src/tools/shell/shell.zig:1654-1663` 走
  `writeHeadTailBounded` + 另一个标记常量
  （`"\n... bytes omitted; use full_output_handle for exact output ...\n"`），与前者不同形。
- 零新增控制面（无 env / flag / setting / JSON 字段）。
- 启动延迟零影响（不在启动路径）；体积增量 = 一行文案 + 一节渲染 + 1KiB 定长缓冲，
  交 `.github/workflows/binary-size.yml` 观察位。
- 本方案零个人路径；数据只报聚合数与字段名（探针里出现的绝对路径已改写为 `/Users/example/`）。

## 评审差异说明（`review-plan.md` @ `be329fac1`）

| 意见 | 处置 |
| --- | --- |
| C1 覆盖依赖发现 A、在飞那条永不入槽 | **接受其结论、修正其机制**。逐条核对后：25/25 样本都有已完成记录，17 条命令输出 + 3 条拒绝理由为高价值，5 条人工答案为低价值（已如实写进覆盖率与"由文案负责"）；而"在飞永不入槽"不成立——`interruptHandler` 只在 JS 指令边界触发（`host.zig:631-648`），在飞调用必先返回并记录，且 codemode 走 `shell` 快照（带 `output_delta`，`shell.zig:1828-1883`）而非 `timeoutFailure` stub。据此新增"覆盖矩阵"，并把"发现 A 修复后覆盖率塌缩"改为"退化为矩阵第三行，仍有内容"。 |
| C1 对 sleep 形状的推测 | **数据不支持**：轮询脚本 `sleep` 与检查命令交替，最后一条是检查命令，25 条里**裸 sleep 0 条**（表已记）。 |
| C3 `shell.zig:38-48` 锚点错 | **一半成立**。该区间在 `src/tools/codemode/shell.zig` 里确实是 `encodeResultJson` 的头尾截断（`:38-48`，用的正是 `formatOmittedBytesMarker`），评审读的是 `src/tools/shell/shell.zig:35-39`（`Action` 枚举）。已把两处路径写全、补 `codemode_tool.zig:101-110`，并**删去"与 shell 逐字节同源"**这句：直连 shell 用不同标记（`:1654-1663`），原表述确实过度。 |
| C2 1KiB 可接受，反例补尾哨兵 | **接受**，已写进问 4.4 反例断言（`TAIL-SENT` 级）与问 4.1 单测。 |
| C4 注意 1：描述修正不得增长 | **接受**，写进落地顺序第 4 条：原地改写、净字数不增（`builtins/tools.zig:743-744`）。 |
| C4 注意 2：复核既有 e2e 分类 | **接受**，写进问 4.4 接线项。 |
| 探针成本 | C1 要求的 25 条逐条核对**本轮已做完**并落进问 1；实现票只剩发现 A 那一条一次性真机探针。 |

## 落地顺序（给实现票）

1. 红：问 4.1 / 4.2 / 4.3 单元金样（含三种形态、尺寸哨兵与成功体零 diff）。
2. 绿：`tool_runtime.zig` 加帽 + 槽 + `recordNestedCall` 文本入参；`bridge.zig` 四个写点；
   `codemode_tool.zig` 新节与顺序。
3. 红→绿：headline 一行（含 `max 120000` 与 poll 引导），扩 `:457`/`:467` 两态 golden。
4. `builtins/tools.zig:743-744` 描述改准（发现 A 的文案部分）：**原地改写、净字数不增**；
   与真实行为逐字对齐（预算是脚本墙钟；嵌套命令在自己不带 `timeout_ms` 时按预算封顶、
   从命令自己启动起算）。
5. e2e：`codemode-admission.test.ts` 正反两条（正例哨兵逐字可见；反例断言尾部哨兵仍在）。
6. 一次性真机探针（不入库）：只查发现 A 的 elapsed 形状（`@options 2000` + `timeout_ms 60000` +
   `sleep 8`），读数写进 impl-report；据此开"嵌套预算传递收口"与
   "`run_command` 兼容后端超时结果无输出"（发现 B，范围已缩小）两张 ISSUE。
   C1 要求的 25 条样本核对已在方案内完成，实现票无需重跑。
7. 收尾：`zig fmt src/`、`zig build test`、`./zig-out/bin/fx` 真机跑一条超时脚本眼看新节；
   PR 描述写 Docs 段（`fx.sh/docs` codemode 页补超时/预算/轮询一段）与 e2e 分类复核结论；
   `issues/ISSUE-23.md` 勾掉差距清单第 2、4 项，第 3 项记为"数据判定不改，另票"。
