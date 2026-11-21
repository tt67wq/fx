# T-34-review 评审报告：ISSUE-34 codemode 常见误用前置到工具描述

- 评审者：fx-pi4（作者独立性：实现者 fx-pi1，本评审未复用其工作树）
- 所核 SHA：绿 `73ecd3f59330d9f768492f5ac4668ac3793816ed`、红 `9de4608fd`、产物 `9bbb63daf`、基线 `5f4856177`
- 核验方式：在 `/tmp/t34v` 新建 detached worktree 检出绿 SHA，全部命令我自己跑；红链用同一 worktree 切到红 commit 的 `src/builtins/tools.zig` 后实测复现，随后还原（0 dirty）

## Verdict: APPROVED

契约六项全部为真，逐条证据见下。发现 1 项需要另开票的高优先问题（F-1，非本票违规，因为基线同样越界），2 项建议。最高优先的「压缩语义无损」在字符串层面成立：11 项既有语义逐句对照全部保留。

## 1. 三则坑前置且准确（对 host / bridge / discovery 实现核）

三则短语在描述中的起始字节：`arguments are objects` 135、`Confirm names via searchTools` 208、`No Node.js API` 269，全部排在最前四句内。

| 陈述 | 实现证据 | 结论 |
|---|---|---|
| 工具名先 `searchTools("keyword")` 确认，不要凭记忆拼 | `searchTools` / `describeTool` 是无条件全局（`src/tools/codemode/host.zig:394-403`），discovery 覆盖整个注入 face 而非已列出的子集（`host.zig:1006` 注释）；未知工具名的报错也回指 `use searchTools("…") to discover tools`（`host.zig:1034-1040`） | 真 |
| 没有 Node.js API：不能 import/require fs、process；没有顶层工具函数 | 既有测试 `codemode exposes no host globals` 钉 `typeof std/os/require/process` 均为 `undefined`（`host.zig:1465-1475`）；用户脚本以 `JS_EVAL_TYPE_GLOBAL \| JS_EVAL_FLAG_ASYNC` 求值（`host.zig:252`），全仓无 module loader 接线（`JS_SetModuleLoaderFunc` / `JS_EVAL_TYPE_MODULE` 零命中），vendor 只编 `dtoa.c` `libregexp.c` `libunicode.c` `quickjs.c`（`build.zig:473`）而无 module-loader 单元，故 `import` 无法解析；另有测试把运行时报错文本钉成 `ReferenceError: require is not defined. ` 开头（`bindings_tests.zig:772`），即「无 Node API」这一条本来就有实测覆盖；工具的具名函数只注入到 `tools` 对象上并删掉 native 入口（`host.zig:501-506`、`host.zig:523-529`），顶层不存在任何工具函数 | 真 |
| 参数是对象，例 `tools.call("run_command", {command: "…"})` | `toolsCallCallback` 对 `JS_IsObject(argv[1])` 走 `JS_JSONStringify`（`host.zig:1074-1083`）；`run_command` 确是脚本侧白名单名，`src/tools/codemode/bindings.zig:12-13` 明写它与注册名（`shell`）不同，`bindings.zig:23-27` 列出四个可调用名；`command` 字段与 `bindings_tests.zig:220` 的既有用法一致 | 真，示例可跑 |

补充核：`tools.read_file` 也确在 face 内（`bindings.zig:23-27`），所以第一句的具名形态示例同样成立。描述里两种调用形态并列（`await tools.name({...})` 与 `tools.call("name", {args})`）与实现一致：shim 里具名形态就是转发到 `call`，与 `tools.call` 同源同权，没有「一个能用另一个勉强能用」的落差（`host.zig:501-506`）。

## 2. 压缩语义无损（改前 1173 字节 / 179 词，改后 1172 / 169）

我自己从两个 commit 抽字符串实测，不采信报告数字：`5f4856177` = 1173/179，`73ecd3f59` = 1172/169。逐项对照：

| 既有语义 | 改前 | 改后 | 判定 |
|---|---|---|---|
| 默认 30s 预算 | `default 30 second wall-clock budget` | `Default: 30 second wall clock` | 保留 |
| 1MiB 捕获帽 | `1MiB capture cap` | `1MiB capture cap` | 保留 |
| 头尾 + omitted 字节数 | `keep the head and tail with the omitted byte count` | `keep head and tail with the omitted byte count` | 保留 |
| `read_tool_result` 回读 | `full captured output is stored and readable with` | `full output is stored, readable with` | 保留 |
| `@options` 首非空行 | `as its first non-empty line` | `First non-empty line` | 保留，实现为「首个非空行、且只在首行有效」（`codemode_tool.zig:904-918` 与其 `ignores a header past the first non-empty line` 测试） |
| 1000..120000 ms 上界 | 同 | 同 | 逐字保留 |
| 4 bytes per token 钳到帽 | `output cap of 4 bytes per token clamped to the 1MiB capture cap` | `output 4 bytes per token clamped to the 1MiB cap` | 保留（实现见 `codemode_tool.zig:1041-1046`，`@min` 到 `default_capture_buffer_bytes`） |
| declared budget 为脚本 wall clock | `a declared budget is the script's wall clock` | 同 | 逐字保留 |
| min(requested, remaining) 嵌套 | `min(requested, remaining budget) from its own start` | 同 | 逐字保留，且 `also caps nested run_command` / `capped at it from its own start` 两句反向钉未动 |
| `text()` 收尾 | `Finish with text(your short summary)` | 同 | 逐字保留 |
| top-level return 非法 | `top-level return is not valid script syntax` | `top-level return is invalid` | 保留 |
| 单工具包装更慢 | `A script that only wraps one tool call is slower than calling the tool directly` | `Wrapping one tool call is slower than calling it directly` | 保留 |
| `tools.list()` 预算子集 / `searchTools` 全面 / `describeTool` 全 schema | 分散在两句 | 合并为一句 | 保留 |

删掉的三处措辞经核不构成语义损失：`use them to search, read, and run`（无信息量的概括，face 与示例已说明可调用面）、`for introspection`（合并句的 `gives each tool's name, description, and parameters schema` 已表达）、`tools.call(...) still works` 里的「still works」让步语气（新句把两形态并列，与 shim 实现一致，反而更准）。

## 3. 长度钉与 byte-exact 覆盖面（独立核）

- `<= 1172` 新钉成立且零余量（实测正好 1172）。收紧 1 字节配合字数下降 10，符合路线 A 的「不增长」要求。
- byte-exact 契约测试覆盖面我独立读过：`src/builtins/tools.zig:896-931` 的哈希对象只有三样，`inline for (all)` 的每个 `toolGatewaySchemaJson`、`advertisement_order` 的每个名字、以及 `shellProcessOnlySpec()`。`all` 是 16 个工具（`tools.zig:797-815`），里面没有 `codemode`；`codemode` 只出现在 `gated_all = all ++ {codemode}`（`tools.zig:856`）与 `gated_advertisement_order`。报告「codemode 描述变更不影响该哈希，无需双平台重钉」为真，且该测试在我的全绿实测中通过（未改动 `861c380f…` / `df9fe455…` 两个钉值即为证据）。
- 与 T-31 的差别也成立：`read_tool_result` 在 `all` 内所以必须重钉，`codemode` 不在。

## 4. 红绿链（我实测复现，非读报告）

同一 worktree 检出绿 SHA 后 `git checkout 9de4608fd -- src/builtins/tools.zig`（红 commit 的测试 + 基线描述），`zig build test`：

- 退 1，唯一失败 `builtins.tools.test.codemode description states the nested command budget truthfully`
- `Build Summary: 20/22 steps succeeded (1 failed); 10031/10034 tests passed (2 skipped, 1 failed)`，与 `red-evidence.txt` 记录一致

还原到绿 SHA 后 `zig build test`：`22/22 steps succeeded; 10032/10034 tests passed (2 skipped)`，0 failed。红的成因可复算：基线描述 1173 字节越过 1172 帽，且五处新短语在旧串里全部缺席。

## 5. 机械核验（绿 SHA，全部我跑）

| 检查 | 结果 |
|---|---|
| `zig fmt --check src/` | 退 0 |
| `zig build test` | 退 0（10032/10034，2 skipped，0 failed） |
| `zig build` | 退 0 |
| `./scripts/check-public-surface.sh` | 退 0 |
| `check-agents-boundary.sh` / `check-compactor-boundary.sh` / `check-indexer-boundary.sh` / `check-recovery-boundary.sh` | 各退 0 |
| `FX_BENCH=1 ./zig-out/bin/fx help` | 退 0，stderr 0 字节 |

## 6. 红线

`5f4856177..9bbb63daf` 只改两处：`src/builtins/tools.zig`（描述 1 行 + 钉测试 11 增 3 删）与 `.agents/tasks/T-34-impl/` 两份报告。`host.zig` / `bridge.zig` / `discovery.zig` / `catalog.zig` / `bindings.zig` 零 diff，ISSUE-31/32 未碰。新增行纯 ASCII、无 `--` 破折号、无个人路径；两份报告里个人路径计数 0。既有断言只增不减：ISSUE-23b 的三处正反钉原样留在测试里。

## 发现

### F-1（高，建议另开 ISSUE-35；不阻塞本票）模型侧描述帽是 1024 字节，1172 的串在传输时被截

`model_tool_schema.description_max_bytes = 1024`（`src/core/tooling/model_tool_schema.zig:4`），超出即保留前 1009 字节加 `... [truncated]`（`model_tool_schema.zig:66-74`）。三条出网路径都过它：chat-completions 的 `tools` 数组（`src/gateway/chat_completions_protocol.zig:570`）、builtins 的 advertisement（`src/builtins/gateway.zig:301-336` 经 `writeBuiltinFunctionSchema` 到 `cappedDescriptionAlloc`）、以及 codemode bridge 自己注入的 `run_script` schema（`src/tools/codemode/bridge.zig:1333`）。仓里那条「描述必须放进模型帽」的测试只遍历 `all`（`tools.zig:932-936`，注释写明「Chat-completions requests cut longer descriptions short」），`codemode` 因在 `gated_all` 而漏检，所以 1173 / 1172 从来没人报警。

后果不是「本票没做到」，而是截断点位移。三则坑都排在 1009 之前，模型确实读得到，本票目标达成。但按 1009 切：

- 基线被切掉的是 `…slower than calling the tool directly` 的残尾和整句 `tools.list() may be a budgeted subset; searchTools(query) finds tools across the full surface; describeTool(name) returns one full schema`
- 改后被切掉的是 `min(requested, remaining budget) from its own start` 的后半（可见部分停在 `gets min(requested,`）、`Finish with text(your short summary); top-level return is invalid`、`Wrapping one tool call is slower than calling it directly`

也就是说，在 chat-completions 路线上，三句命令式指引加一个子句从「能到达模型」变成「到不了」。其中 `Finish with text(...)` 与 `top-level return is invalid` 正是模型写脚本前最该看到的收尾规则，ISSUE-23b 特意钉的嵌套预算真相句也被腰斩。

建议：把 `codemode_description` 收到 1024 以内（或与 F-1 同票把必守句排进前 1009 字节），并把 `tools.zig:932` 的帽测试覆盖面从 `all` 扩到 `gated_all`，让这条线以后自动兜住。

### F-2（中）`script` 参数描述仍是改前口径

`tools.zig:778` 的参数描述（251 字节，完整可见）写着 `tools.call("tool_name", "{json args}") still works`。两种形态实现上都收（对象走 `JS_JSONStringify`，字符串直接当 JSON），所以不算假话，但它和正文里新加的「arguments are objects」并列时，把模型往字符串形态带回一格。建议同票改成对象形态示例，并顺手去掉 `still works` 的旧让步语气。

### F-3（低，均为逐字继承的既有措辞，非本轮引入）

- `raises the budget`（基线 `declares a bigger budget`）：`effectiveScriptOptions` 是**替换**而非只升（`codemode_tool.zig:1035-1040`），声明 `timeout_ms: 1000` 会把 30000 降成 1000；输出帽同理带 1KiB 下限（`codemode_tool.zig:1044`）
- `timeout 1000..120000 ms hard-capped`：实现是越界直接拒（`error.OutOfRange`，`codemode_tool.zig:951-957`），不是钳到边界
- `keep head and tail`：成功路径的 `appendCapped` 只保 head 并计 dropped（`host.zig:1142-1152`，调用点 `host.zig:657/682`），失败体才头尾都留（`codemode_tool.zig:597-616` 的测试）；`run_command` 的桥接帽是头尾都留（`src/tools/codemode/shell.zig` 的 `encodeResultJson`）。三处都继承自基线，本票一字未改。

## 我没核 / 风险

- 没跑 CI：本票只交评审文档，不产生代码提交，因此 `AGENTS.md` 就绪清单里的「CI on the exact commit」和「驱动一次真实交互」两项未做。绿 SHA 的本地全绿不等于 PR CI 绿。
- F-1 的 1024 截断由代码路径核出（帽常量 + 三条出网写入点），没有抓包实测某次真实请求的 body 长度。
- ISSUE-34 处置项 3（下轮 session 里同类误用是否归零）无法在本轮观测，属后续指标。
