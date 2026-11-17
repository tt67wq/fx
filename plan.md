# T-12-plan 实现方案：codemode 输出超限头尾保留并给回读路径

对应 `issues/ISSUE-12.md`。工作树 `/Users/example/Project/Zig/fx-pi1`（分支 `T-12-plan`）。本文只做方案，不改 `src/`。

## 0. 锚点核实结论（两处与 conductor 锚点不同，须先纠偏）

核实后，ISSUE-12 的两个症状要分开看，其一**今天已经实现**，不要重复造：

1. **>16KiB 的 codemode 结果已经落盘并给句柄**。每个工具结果都过
   `src/core/agent/runtime/execution_memory.zig:928-940`：`prepared.truncated` 为真时，
   它把**完整输出**写进 `result_store.storeLargeResultManaged` / `storeLargeResult`，
   句柄存进 `memory.output_handle`，模型看到
   `result_store.formatStoredResultOutput`（`src/core/session/result_store.zig:459-467`）
   的 `<tool_result_preview>` + `<tool_result_handle>` + `Use read_tool_result` 信封。
   所以**回读路径不需要新建**，缺的只是尾部可见。
2. **真正的永久丢失在 64KiB 捕获帽**。`src/tools/codemode/host.zig:22`
   `default_output_buffer_bytes = 64 * 1024`，`appendCapped`（`host.zig:995-1008`）
   超出即丢尾且**不计数**；于是第 1 条存下的完整输出本身已缺尾。
3. **可见摘录是纯头部**。`result_store.previewText`（`result_store.zig:637`，
   `preview_bytes = 4 * 1024` 见 `result_store.zig:16`）只截前 4KiB。这是所有超阈工具共用的形状。
4. 纠偏：头尾先例的精确出处是 `src/tools/codemode/shell.zig:40-48`
   （标记在 `:42`，1MiB 帽常量在 `:7`），不是 `:33-39`。
5. 补充：`host.zig:480-485` 的 `stringify(value)`（脚本返回值）**完全无帽**，
   靠第 1 条兜住；抬高捕获帽后仍兜得住，无需单独加帽。

结论：最小正确改动 = **抬高捕获帽并计数**（host 层，codemode 独有症状）
+ **把共用预览改成头尾各半**（result_store 层，尾部缺失的根因所在）。

## 1. 头尾切分

**1.1 捕获层（src/tools/codemode/host.zig）**

- `:22` 常量值 `64 * 1024` 改为 `1024 * 1024`，改名 `default_capture_buffer_bytes`，
  `Options.output_buffer_bytes` 字段名不动（避免改已有契约），默认取它。
  1MiB 取 `tools/codemode/shell.zig:7` 同层先例。注释写明这是**捕获帽，不是模型可见预算**。
- `appendCapped`（`:995-1008`）保留头部追加语义，把静默丢弃改成**计数丢弃**：
  命中帽时 `host.text_dropped_bytes += 未写入字节数`（console 同理），仍返回 `.truncated`。
- `Result`（`:49-61`）**只增字段**：`text_dropped_bytes`、`console_dropped_bytes`、
  `capture_limit_bytes`；`takePartialOutput`（`:136-140`）同步带上，供失败路径复用。
- `text()` / `console.log` 的 JS 可见返回值（`:528-571`）语义不变：缓冲已满返回 false。
  唯一移动的是阈值 64KiB 到 1MiB，属阈值移动而非语义移动，须由测试钉住（见 4.1）。

**1.2 呈现层（src/core/session/result_store.zig）**

- `previewText`（`:637`）改为头尾各半：调用
  `text_utils.writeHeadTailBounded(writer, text, preview_bytes, omitted_marker, .down)`
  （`src/core/shared/text_utils.zig:45-67`）。已核实：标记由调用方传入、**计入预算内**
  （`:56` 先减 `marker.len` 再二分），切点走 UTF-8 边界（`:62-63`），
  输出总长恒不超过 `max_content_bytes`。头约 2KiB、尾约 2KiB。
- 4 个消费点零改动、自动继承：`result_store.zig:163`、`:201`、
  `session_log.zig:1927`、`v1_conversion.zig:1080`（另 `session_adapter.zig:2032`）。
- **禁止**改成 codemode 自己裁正文、自己存句柄：那样 `memory.output_handle` 不会被写入，
  v2 内容寻址 blob 处于 unlisted 状态，fork 后读不回
  （`session_adapter.zig:974-987`，`sessions_v2_blobs_unlisted` 埋点）。
  落盘动作必须留在 `execution_memory.zig:928-940` 这条已有路径上。

**1.3 失败与部分输出路径（src/tools/codemode/codemode_tool.zig）**

- 现 `:70` `max_failure_output_head_bytes = 4KiB` + `:80-89` `appendFailureOutputHead`
  是头部单切。超时/抛错时最想看的正是最后几行，改用同一个 `writeHeadTailBounded`
  （`.down`，同 4KiB 预算），标记换成 1.4 的统一文案。
- 成功路径 `appendSuccessOutput`（`:148-158`）：仅当命中**捕获帽**（1.1 的 dropped 大于 0）时，
  在正文末尾追加一行同文案标记，让模型知道连落盘副本都缺字节；未命中帽时不加任何标记。

**1.4 标记文案（裁决：与同层先例字节对齐，与 shell 工具的文案独立）**

- 统一为换行 + `...[N bytes omitted]...` + 换行（即 `\n...[{d} bytes omitted]...\n`），
  与 `tools/codemode/shell.zig:42` **逐字节相同**。落成一个共享常量
  （放 `core/shared/text_utils.zig`，紧邻 `writeHeadTailBounded`），
  由 1.2、1.3 与 codemode/shell 三处共用，杜绝第三套文案。
- **不要**复用 `tools/shell/shell.zig:1654` 的
  `... bytes omitted; use full_output_handle for exact output ...`：
  它点名的是 shell 自己的 `full_output_handle` 字段，而通用/codemode 结果的回读入口是
  `read_tool_result` + `<tool_result_handle>`，照抄会把模型指向不存在的字段。
- 回读提示**不写进标记**：`formatStoredResultOutput`（`:459-466`）已在信封末尾给出
  唯一权威句子（`Full result is stored outside session JSON. Use read_tool_result ...`），
  重复一遍只会挤掉正文预算。

## 2. 落盘句柄（端到端：谁写、谁读、生命周期、权限面）

- **裁决：既不复用 shell 的临时文件机制，也不由 codemode 自建，复用 `result_store`。**
  shell 的 `full_output_handle` 指向 `snapshot.output_file`（真实临时文件
  `fx-command-*.log`，需自管清理，见 `tools/shell/shell.zig:1632-1680`、
  `core/agent/runtime/tool_presentation.zig:1561-1573`），与 codemode 需求不同形。
- **谁写**：`execution_memory.zig:928-940`（既有代码，本任务不改）。managed 会话走
  `result_store.storeLargeResultManaged`（`:306-316`），legacy 走 `storeLargeResult`
  （`:236-247`）；句柄名形如 `result-{call_id}-{tool}-{hash}.txt`（`:653`、`:663`）。
- **谁读**：`src/tools/session/read_tool_result.zig` 经 `readByRangeManaged`（`:485`）
  分页，或 `searchByQuery`（`:526`）做字面查询；单次上限 `read_max_bytes = 64KiB`（`:18`），
  全文上限 `stored_text_max_bytes = 8MiB`（`:20`）。
- **暴露形状**：句柄只出现在**模型可见文本**里，不加 JS 字段。脚本返回值走
  `stringify(value)`（`host.zig:480-485`），若把句柄塞进 result 对象，等于让脚本去消费
  宿主侧存储标识，既违背红线只增不改的精神，也诱导脚本越界读文件。
- **生命周期**：写进 session 的 `.tool_results` 条目（legacy）或内容寻址 blob（v2），
  **不产生独立临时文件**，随 session 目录一并回收，无需新增 GC。已核实仓库当前
  不存在 `.tool_results` 的 prune，与今天 shell、MCP 的既有落盘同寿命。
- **权限面**：句柄在 `result_store.zig:821` `validateHandle` 白名单内（长度不超过 160、
  禁连续点号、字符集仅字母数字下划线连字符点号），只在 `SessionChildCapability`
  打开的 session route 内**按名字**解析，不接受路径，因此无遍历面，
  不新增权限规则，`src/core/permissions/` 零改动。
- **残留缺口（另开 issue，不在本任务修）**：`@options max_output_tokens` 超过 16KiB 后
  对模型可见量无影响，因为可见摘录尺寸由 `preview_bytes` 定死。要真正生效需把
  per-call 预览预算透传进 `prepareManaged`（`:109`），属独立改动。

## 3. 预算键裁决

- **结论：捕获帽用独立常量，不接 `max_tool_result_bytes`；模型可见内联预算继续由既有分层
  决定（`large_result_threshold_bytes = 16KiB`，`result_store.zig:15`，
  加上 `inline_cap = max_tool_result_bytes`），本任务这两行不改。**
- 理由一（语义）：`max_tool_result_bytes`（`src/core/config/tool_result_limits.zig:7`，
  默认 64KiB，**允许写进项目 `.fx.json`**）是每工具结果对模型可见的内联上限；
  捕获帽是沙箱宿主内存上限。接通后项目把该值设成 1MiB，一次 `codemode`
  就会静默占用约 2MiB 宿主缓冲（text 与 console，这两块在 host 分配器上、
  不受 `JS_SetMemoryLimit` 约束），而项目层根本无法表达这种意图。
- 理由二（先例对比）：ISSUE-15 的目录预算进了 `context_limits.zig` 的 `Name` 枚举
  （`codemode_catalog_bytes`，16KiB），因为那是一份**模型可见**预算；
  捕获帽不属此类，不该照抄进枚举。
- 理由三（与 shell 对齐）：`tools/shell/shell.zig:1632-1680` 的内联取
  `min(max_tool_result_bytes, 16KiB)`，全文另用 `codemode/shell.zig:7` 的 1MiB 常量。
  仓库既有做法就是内联看配置、捕获看常量，本方案沿用同一分层。
- 连带改动：`codemode_tool.zig:738-750` `effectiveScriptOptions` 里
  `max_output_tokens`（4 字节每 token）的钳制上界从 64KiB 改为引用新的 1MiB 常量，
  不写第二处字面量；`src/builtins/tools.zig:744` 描述里**两处** 64KiB
  （a 64KiB output cap 与 clamped to the 64KiB host cap）都要改，见 4 节第 10 条。

## 4. 测试清单

**单元（Zig，随源文件）**

1. `host.zig:1230-1259` 两条现有截断测试重写：现断言 `result.text.len == 32` 且全为同一字节，
   改为缓冲帽 32 字节加 `text_dropped_bytes` 等于实际未写入字节数；
   新增一例钉住 1.1 的阈值移动：`text()` 在帽内返回 true、命中帽后返回 false。
2. `host.zig` 新增：`text_dropped_bytes` 与 `console_dropped_bytes` 两流独立计数、互不串扰；
   以及一例超过 1MiB 的脚本不 OOM 且计数非零。
3. `result_store.zig` 现有 5 处 `@splat('x')` 大结果测试（`:838`、`:862`、`:1064`、
   `:1107`、`:1183`）更新期望：预览同时含头与尾，总长不超过 `preview_bytes`。
   注意这 5 处正文同质，头尾看不出差别，**必须先换成带 distinct 哨兵前缀的构造**再断言。
4. `result_store.zig` 新增两条：标记里的 omitted 数字等于 `stored_bytes` 减预览正文字节数；
   尾部以半个码点结尾时不得切断（UTF-8 边界）。
5. `codemode_tool.zig` 新增：失败路径（超时）输出为头尾各半；dropped 大于 0 时成功正文
   末尾出现捕获帽标记，dropped 为 0 时不出现。
6. `src/tools/codemode/sandbox_tests.zig`（已核实当前无截断用例）新增沙箱端到端：
   `text()` 输出 200KiB，断言结果含头部哨兵、尾部哨兵、`...[N bytes omitted]...`
   与 `<tool_result_handle>`，再用该句柄 `readByRangeManaged` 取中间区间并与原输出逐字节相等。

**e2e（Bun，确定性）**

7. 新建 `tests/e2e/codemode-output.test.ts`：`fx ask --json` 两轮。第一轮跑生成 300KiB
   `text()` 的脚本，断言结果 JSON 含头哨兵、含尾哨兵、含 omitted 标记与
   `read_tool_result` 提示；第二轮用该句柄回读中间字节区间，断言拿到中间哨兵字符串。
8. 同文件再加一例大 `return` 值路径（不调 `text()`），确认返回值同样落盘可读。
9. 接线（缺一项 CI 直接红）：`scripts/pgso/corpus.json` 的 `verification_scenarios`
   增 `verify-codemode-output`（与现有两条 codemode 同类，紧随其后），
   `tests/e2e/ci-shard-weights.json:76-77` 同侧加
   `{ "file": "codemode-output.test.ts", "weight": 3 }`。

**文档**

10. `src/builtins/tools.zig:744`：两处 64KiB 改为 1MiB 捕获帽，并补一句
    超限后头尾各半、全文经 `read_tool_result` 回读。
11. PR 描述加 `## Docs` 段：fx.sh/docs 的 codemode 页需把 64KiB 硬截断改为
    1MiB 捕获帽、超限头尾各半、全文经 `read_tool_result` 回读。

## 5. 红线自检

- 不碰 `src/core/permissions/`、不碰准入（codemode admission 相关代码零改动）。
- 不碰 `src/mcp/`、`src/core/mcp*/`。
- JS 契约只增不改：`Result` 加三字段；`Options.output_buffer_bytes` 名字与含义不变；
  `text()` 与 `console.log` 返回值语义不变（仅阈值移动，测试 4.1 钉住）。
- 不改 codemode 的 `image()` 落盘、`store()` 与 `load()`，不改 ISSUE-11 的
  `formatSuccessBody` 前缀逻辑（`codemode_tool.zig:190-220`）。
  注意该前缀会抬高正文体积，可能把原本 15KiB 的结果推过 16KiB 触发落盘，属预期行为。
- 不新增依赖，不新增临时文件类型，不改 session schema。
- 唯一越出 `src/tools/codemode/` 的改动是 1.2（共享 session 层），
  需 reviewer 确认所有超阈工具的预览改为头尾各半可接受；退路见第 6 节备选 C。

## 6. 备选与拒绝理由（供 conductor 仲裁）

- **备选 A（codemode 自建落盘加自带信封）**：`codemode_tool.zig` 把正文裁到
  16KiB 以内后自行调 `storeLargeResultManaged` 并复用 `formatStoredResultOutput`，
  完全绕开共享层。拒绝理由：句柄不进 `memory.output_handle`，v2 下 blob unlisted，
  fork 读不回（`session_adapter.zig:974-987`）；要补就得给工具结果加
  `output_handle` 字段并改 `execution_memory`，diff 反而更大。
- **备选 B（只抬帽、不动预览）**：永久丢失消失，尾部仍看不见。拒绝理由：不满足 ISSUE-12 目标。
- **备选 C（抬帽加仅在 1.3 失败路径做头尾，成功路径不动）**：不碰 `src/core/session/`，
  但超过 16KiB 的成功结果仍然只有头部。仅当 reviewer 拒绝共享层改动时采用。
- **推荐：主方案（1.1 加 1.2 加 1.3）**。总 diff 最小，落盘与回读全走既有已验证路径，
  头尾收益对所有超阈工具一致（与 pi 行为对齐）。
