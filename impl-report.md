# T-24/25-impl 实现报告 — codemode 失败反馈质量

- 分支：`T-24-impl`（自 origin/main `f624f9c28` 切出）
- 权威需求：`issues/ISSUE-24.md`、`issues/ISSUE-25.md`
- 纪律：严格 TDD，红/绿分 commit；红 commit 为 `35f349333`（红证据 `.fx-red-evidence.txt`），绿 commit 为 `3f751188d`。
- 本工作树：`/Users/example/fx`。

## 落地内容

### ISSUE-24（嵌套参数报错指明字段 + ScriptError 正文兜底）

1. **嵌套 tools.call 参数拒绝现在报出字段名。** bridge 在返回 `error.InvalidToolArguments` 前，把一行字段详情写进 `CodemodeHostState.NestedArgumentError`（400 字节定长缓冲，沙箱线程零分配，每次调用开始时清空）；host 经 `Backend.argument_error` 函数指针读出，拼进脚本报错：
   `codemode tool run_command failed: InvalidToolArguments: run_command requires field "command"; received fields: cmd`
   覆盖 `canonicalRunCommand`、`canonicalRunScript`、`resolveRunScriptFile`、`readRunScriptFile` 的全部拒绝点（即嵌套 call 路径那部分；约 43 处中的其余站点不在脚本侧 tools.call 路径上，未动）。多字段回显按字典序排序，消息确定。
2. **ScriptError 空正文兜底。** `scriptErrorHeadline`：引擎正文缺失或为空时回传
   `codemode script failed: ScriptError: no engine message (stage: compile|runtime)`。
   stage 由 host 记录：`JS_Eval` 同步异常 = compile，promise 拒绝 = runtime。
3. codemode 工具自身入参（缺 script 字段）保持原契约文案，仅追加回显（见 ISSUE-25 第 5 条）。

### ISSUE-25（七类误用定向提示；只改提示，零语义变更）

1. **顶层 return**：`SyntaxError: return not in a function` 后附位置与定向提示
   `(codemode.js:2:1). top-level return is not allowed; use text() or make the last expression the result`。
2. **ReferenceError**（`X is not defined`）附一行沙箱说明：no Node.js APIs (require, setTimeout, process)；工具入口 tools.call / tools.<name>。
3. **unknown tool**：`tools.call` 的未知名改走既有 `throwUnknownTool`（复用 discovery.zig 的 did-you-mean + searchTools 指引，对齐 ISSUE-15，与 describeTool 同一文案机制）。
4. **`tools.xxx(...)` 直调假设**：引擎只报裸 `TypeError: not a function`（不带被调用名），提示统一给出正确形态 `tools.call("name", args)` 并指向 `tools.list()`（见偏差 2）。
5. **缺 script 字段**：报错回显实际收到的顶层键名（排序）：`...requires string field "script"; received top-level keys: code, language`；空对象报 `received no top-level keys`。
6. **@options 越界**：回显实际传入值：`... must be greater than 0. (received timeout_ms: 999)`；负数与 `max_output_tokens: 0` 同样回显。
7. **SyntaxError 位置**：从异常 `stack` 属性提取 `codemode.js:行:列` 附在正文后（QuickJS 能给，已给）。

### 未触碰（红线自检）

- admission / permissions / shell_command / mcp：零改动。nested 调用仍在 canonicalize 之后进入完全相同的 admission 管线；拒绝点只加文案，错误值、返回值、时序不变。
- catalog 分层与预算、工具执行路径、CLI 面、settings 键、环境变量：零新增零改动。
- 文案均在测试中逐字钉住（`expectEqualStrings` / e2e `toContain` 完整句）。

## 验收证据（逐条）

1. `zig fmt --check src/` → 退 0。
2. `zig build test` → 退 0（10009+ pass，0 fail；绿后复跑 BUILD=0）。红 commit 阶段实测红：13 条新增测试全部断言失败（7 bindings_tests、3 bridge、3 codemode_tool），既有测试全过；绿阶段验证轮同样出现该已知 `command_runner` flake 一次（"runtime cancellation observed at the timeout deadline stays graceful" failed without output），复跑一次通过（TEST=0），符合契约备注；红轮证据记录于 `.fx-red-evidence.txt`。
3. `cd tests/e2e && FX_SOUND=0 bun test codemode-admission.test.ts cli.test.ts` → 168 pass / 0 fail（E2E=0）。新增 3 条 e2e 断言并入 `codemode-admission.test.ts`（describe "codemode script mistake feedback"），未新建文件，corpus 分类沿用。
4. `bash scripts/check-public-surface.sh` → 退 0；四边界脚本（compactor/indexer/recovery/agents）全部退 0。
5. 真机探针（`./zig-out/bin/fx ask --json` + fake gateway，逐字新文案）：
   - 顶层 return → `codemode script failed: ScriptError: SyntaxError: return not in a function (codemode.js:2:1). top-level return is not allowed; use text() or make the last expression the result`
   - cmd 误用 → `codemode tool run_command failed: InvalidToolArguments: run_command requires field "command"; received fields: cmd`
   - unknown tool → `unknown codemode tool: read_tool_result. did you mean: read_file, ...? use searchTools("read_tool_result") to discover tools`
   - 另覆盖 require 误用、`throw ''`（`no engine message (stage: runtime)`）、裸语法错（带位置）、@options 越界回显、缺 script 回显键名、`tools.fetch({})`（call 形态提示），共 9 例全部命中钉住文案。
6. 产物：红 commit `35f349333` + `.fx-red-evidence.txt` + 本报告（绿 commit 随后）。

## 偏差逐条声明

1. **顶层 return 采用"引擎信息识别 + 定向提示"，而非文本预扫描。** 契约预留了"预扫描误报率高"的报告通道：可靠的文本预扫描需要完整 JS 词法器（字符串/模板插值/注释/正则字面量中的 `return` 都会让轻量扫描误报，例如 `/return/g`），误报会把合法脚本拒之门外——这本身就是执行语义伤害。引擎解析器给出确定无误的信号（`return not in a function`），再附加同一句定向提示，效果等价且零误报；位置信息也顺带来自引擎。自动 wrapper 未做（契约已否决）。
2. **`tools.read_file` 直调提示使用泛化名。** QuickJS 对缺失方法只报裸 `TypeError: not a function`，不含被调用名，无法还原契约例句里的具体 `read_file`；提示统一给出 `tools.call("name", args)` 正确形态并指向 `tools.list()`。附带事实说明：白名单内工具其实存在 `tools.<name>(args)` 方法（shim 注入），触发该 TypeError 的是不在当前 face 上的名字，因此提示同时覆盖"查 list"这一修正路径。
3. **最小 setTimeout 未提供。** ISSUE-25 第 2 条中"评估提供最小 setTimeout"属于执行语义扩展（事件循环/超时模型），与本轮"零语义变更"红线冲突，维持 ReferenceError 定向提示；留待单独立项。
4. **空正文兜底的阶段只区分 compile/runtime。** 嵌套调用失败必然携带具体文案（本轮改动后更详细），不会落入空正文分支，故无 "nested call" 第三阶段；契约要求"至少回传错误类型与阶段"已满足。
5. **措辞与契约例句的对应。** 契约例句 `unknown field cmd, expected command` 为示意；实现按"实际缺/错的是什么 + 期望的是什么"直陈（`run_command requires field "command"; received fields: cmd`），信息量相同、与 Zig 侧既有 JSON 报错形态一致，风格对齐 tool_search 通知的"一行说明 + 修正方法"。
6. **红 commit 含惰性类型声明**（Backend.argument_error 字段、NestedArgumentError、ErrorStage、error_out 参数等，行为全部未接线），使 13 条红测试以断言失败呈现而非编译失败，证据可读性更好；红 commit 自身零行为变更（全量既有测试通过佐证）。
7. **`tools.call` unknown tool 文案复用既有 `throwUnknownTool`**，未新写文案机制；其列出全部候选（最多 5 个、按接近度排序）是既有 describeTool 面行为，保持原样。

## Docs

fx.sh/docs 的 codemode 页若展示了上述任一原文案（如裸 `InvalidToolArguments`、`unknown codemode tool` 无建议形态），需要同步：

- `codemode` 工具页"失败反馈"部分：补充七类误用提示示例与嵌套参数详情形态。
- 本仓库无 docs 目录改动；`--help` 与 command specs 无需变更（无新控制面）。

## 复审 follow-up notes

（留待 t39 review 轮填写。）
