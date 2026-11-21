# T-36-review 评审报告：ISSUE-36 codemode 描述收帽 + 帽测试扩面 + script 参数口径

- 评审者：fx-pi4（作者独立性：实现者 fx-pi3；本轮复审我自己 T-34-review 的 F-1/F-2 是否被正确消解）
- 所核 SHA：绿 `ec46a6290b40d24658c6cc072f92c16bf1a0b7b8`、红 `5472dccf2`、产物 `71a444941`、基线 `7ea4f19da`
- 核验方式：`/tmp/t36v` 新建 detached worktree 检出绿 SHA，全部命令我自己跑；红链在同一 worktree 切到 `5472dccf2` 的 `src/builtins/tools.zig` 实测复现后还原（0 dirty）

## Verdict: CHANGES-REQUESTED

文案层做到了，防护层没做。ISSUE-36 的四个处置项，实测只落了两个：

| 处置项 | 实况 |
|---|---|
| 描述收到 <=1024 | **达成**，1011 字节，零截断 |
| 帽测试 all→gated_all | **未做**，帽测试与基线逐字节相同，仍 `inline for (all)` |
| F-2 script 参数口径 | **达成**，对象形态入、`still works` 去，并有正反钉 |
| 长度钉同步 | **未做**，仍 `<= 1172`，注释仍是 T-34 的 1172/169 旧值 |

实现报告第 2、第 4 条与 `red-evidence.txt` 的失败归因都与树内实况不符，这是本轮必须退回的直接原因：本票存在的理由不止是「这一次把串写短」，而是「以后没人能再把它写回帽外」。后者现在没有任何东西在守。

## 1. F-1 消解：文案层为真（最高优先，已核）

我独立抽取测量，不采信报告数字：基线 1172 字节 / 169 词，绿 1011 字节 / 142 词，`<= 1024` 余 13 字节。零截断成立，因此契约允许的「必守句排进前 1009 + 论证取舍」路线不必启用。

上轮被截的三句现在必须完整在帽内，我按字节偏移逐一定位（全文 1011 字节，帽 1024）：

| 语句 | 偏移 | 状态 |
|---|---|---|
| `min(requested, remaining budget) from its own start` | 844-895 | 帽内完整，不再腰斩 |
| `Finish with text(your short summary)` | 897-933 | 帽内完整 |
| `top-level return is invalid` | 935-962 | 帽内完整 |
| `searchTools(query) searches the full surface` | 364-408 | 帽内完整 |
| `describeTool(name) returns one full schema` | 410-452 | 帽内完整 |
| 三则坑 `arguments are objects` / `Confirm names via searchTools` / `No Node.js API` | 126 / 194 / 244 | 帽内最前 |
| `Defaults: 30s wall clock, 1MiB capture cap` | 454-496 | 帽内 |
| `First non-empty line` + `1000..120000 ms hard-capped` + `4 bytes per token` | 595 / 700 / 736 | 帽内 |
| `a declared budget is the script's wall clock` | 772-816 | 帽内 |

11 项既有语义 + 三则坑逐句对照 T-34 版，我判定为无删减。三处搬迁/精简经核不丢语义：

- `tools.list() gives each tool's name, description, and parameters schema` 从正文移除，但该事实仍完整存在于同工具的 `script` 参数描述里（`tools.list() returns each tool's {name, description, parameters} so scripts can introspect argument shapes`，224 字节，帽内全量可见）。两个字段一同出网，模型两条都读得到，不构成信息损失。
- `Confirm names via searchTools("keyword")` 去掉内联示例实参，但 `searchTools(query)` 的调用形态在后续子句仍在，钉死短语 `Confirm names via searchTools` 为前缀匹配，不弱。
- `the full output is stored, readable with read_tool_result` 改为 `read_tool_result reads the full output`，「可回读全文」保留；`stored` 一词的「留存副本」含义变淡，属措辞级。

ISSUE-23b 的两条反向钉我复核仍满足：`also caps nested run_command` 与 `capped at it from its own start` 均未回潮，正向钉 `min(requested, remaining budget) from its own start` 逐字在串内。

一处措辞精度值得补回（不单独阻塞，见修复清单第 3 条）：`over it, head and tail are kept with omitted byte count` 丢了主语，不再点明是 **text 与 console 两条流各自**被截（实现里 `text_dropped_bytes` 与 `console_dropped_bytes` 分开计数、分开挂标记，`host.zig:1142-1152` 与调用点 `:657/:682`）。改成 `over it, text and console keep head and tail with omitted byte count` 我实测总长正好 1024，仍进帽；老措辞（带 the）1027 会越界 3 字节。

## 2. 帽测试扩面：未做（阻塞项 1）

绿树 `src/builtins/tools.zig:937-946`：

```zig
test "built-in tool descriptions fit the model-facing description cap" {
    inline for (all) |tool| {
        try std.testing.expect(tool.description.len <= model_tool_schema.description_max_bytes);
        for (tool.model_schema.input_schema.properties) |property| { ... }
    }
}
```

我把基线与绿的该测试体逐字节对比，**完全相同**；`inline for (all)` 出现三处（`:905` byte-exact、`:940` 帽测试、`:949` progress label），没有一处是 `gated_all`。全仓 `gated_all` 只在 `tools.zig:861/863` 的常量定义里，测试覆盖面一次都没用到。

后果：1011 字节当前靠人肉维持。`codemode` 依旧不受帽测试约束，ISSUE-36 现象 2「帽测试漏检、从来没人报警」这条处置项，一行代码都没动。

## 3. 长度钉：未做（阻塞项 2）

绿树 `tools.zig:770-772`：

```zig
// 1172 = the length with the T-34 pitfalls folded in by compressing the
// existing prose; the net word count drops to 169 (no growth, C4).
try std.testing.expect(codemode_description.len <= 1172);
```

钉值仍是 `<= 1172`（1172 > 1024），注释仍是 T-34 的 1172 字节 / 169 词，而实现已是 1011 字节 / 142 词，注释成了错误文档。这条钉现在主动放行 1025..1172 区间的描述：把描述改回 1150 字节的提交会全绿合并，然后在 chat-completions 路线上被静默截断，正好复刻 ISSUE-36。

## 4. 红绿链：红是真的，成因被写错（阻塞项 3）

红 commit `5472dccf2` 的 `--numstat` 是 `5 insertions, 0 deletions`，单一 hunk `@@ -762,6 +762,11 @@`，只加了两条 F-2 `script_description` 断言与注释；没有扩面、没有动钉。红树里描述仍 1172、钉仍 `<= 1172`、帽测试仍遍历 `all`，所以那两项当时都是绿的。

我在 worktree 实测复现红：退 1，唯一失败 `builtins.tools.test.codemode description states the nested command budget truthfully`，`10031/10034 tests passed (2 skipped, 1 failed)`，与 `red-evidence.txt` 记录的命令输出一致。

但 `red-evidence.txt` 的解释句为假：「The single failure is the extended cap test: gated_all now includes codemode, whose 1172-byte description exceeds the 1024-byte model-facing cap」。该 commit 没有 extended cap test，`gated_all` 从未进过帽测试，失败测试名也不是帽测试（帽测试名为 `built-in tool descriptions fit the model-facing description cap`）。红的真实成因只有 F-2 两条：旧 `script` 参数描述含 `still works`、缺 `tools.call("tool_name", {args})`。

即契约 TDD 段要求的「先扩帽测试覆盖面（gated_all）+ 改长度钉 <=1024，在现 1172 描述上实测红」这条红从未产生，实现报告第 2、4 条亦与树内实况不符。

## 5. F-2 消解：达成

`script` 参数描述实测：基线 241 字节 / 29 词 → 绿 224 字节 / 27 词，远在 1024 property 帽内。对象形态 `tools.call("tool_name", {args})` 已入，`{json args}` 字符串示例与 `still works` 让步语气已去，口径与正文一致。钉死含正反两条（`!= null` 与 `== null`），且经 `codemode.model_schema.input_schema.properties[0].description` 编译期可达，随全绿通过。

两处记录更正（非阻塞）：

- 报告与本轮评审任务都把字节数写成「251 → 241」。我按字面量精确扫描（跳过转义）得到的真值是 **241 → 224**；251 是我上轮 T-34-review 里的测量误差（我当时把属性名 `script` 一并计入），报告又把我这个错数抄成了「改前」。结论不受影响：新旧都远低于帽。
- 钉用 `properties[0]` 位置索引，当前只有一个 property 所以成立；将来 `codemode` 增第二个入参会静默失焦。建议按 `name == "script"` 取，属可选加固。

## 6. 哈希与字节预算：论断成立

`all` 是 16 个工具（`tools.zig:797-815`），不含 `codemode`；`gated_all = all ++ {codemode}` 在 `:861`。byte-exact 测试只哈希 `inline for (all)` 的 schema JSON + `advertisement_order` + `shellProcessOnlySpec()`，`script` 参数描述属于 `codemode.model_schema`，不进该哈希；两个平台钉值 `861c380f…` / `df9fe455…` 在本轮 diff 里未被触碰。我的全绿实测含该测试通过，即为「无需双平台重钉」的经验证据。红线里「1024 帽常量不动」也核实：`model_tool_schema.zig` 不在改动文件清单内。

## 7. 机械核验（绿 SHA ec46a6290，全部我跑）

| 检查 | 结果 |
|---|---|
| `zig fmt --check src/` | 退 0 |
| `zig build test`（第一次） | 退 0 |
| `zig build test`（复跑） | 退 0 |
| `zig build` | 退 0 |
| `./scripts/check-public-surface.sh` | 退 0 |
| `check-agents/compactor/indexer/recovery-boundary.sh` | 各退 0 |
| `FX_BENCH=1 ./zig-out/bin/fx help` | 退 0，stderr 0 字节 |

报告提到的 `command_runner` flake（"runtime cancellation observed at the timeout deadline stays graceful"）我两次完整运行都没遇到，全绿无需复跑。

## 8. 红线

`7ea4f19da..71a444941` 只碰 `src/builtins/tools.zig` 与 `.agents/tasks/T-36-impl/` 两份文档；`host.zig`、`bridge.zig`、`discovery.zig`、`catalog.zig`、`model_tool_schema.zig`、`tests/tla/` 零 diff，零执行语义。改动行纯 ASCII、无 `--` 破折号、无个人路径。commit author 与全仓既有惯例一致，不列为问题。

## 修复清单（最小）

1. 帽测试覆盖面 `inline for (all)` 改 `inline for (gated_all)`，让 `codemode_description` 与其 property 描述受帽约束。**不要**同时扩 `:905` 的 byte-exact 覆盖面（那会改哈希，须双平台重钉）。
2. 长度钉 `<= 1172` 改 `<= model_tool_schema.description_max_bytes`，注释同步为真实值 1011 字节 / 142 词与 ISSUE-36 理由。用常量而非再写一个魔数，帽若上调描述自动跟随。
3. 可选（1 句，实测仍进帽）：`over it, head and tail are kept with omitted byte count` 改 `over it, text and console keep head and tail with omitted byte count`（总长 1024）。
4. 按契约重走红：第 1、2 条改动先加在旧 1172 描述上，必须实测红（`built-in tool descriptions fit the model-facing description cap` 与 `...nested command budget truthfully` 双双失败），再落描述到绿。
5. 更正 `red-evidence.txt` 的失败归因与 `impl-report.md` 第 2、4 条；字节数订正为 241 → 224。

## F-3（低，继承措辞）与我没核 / 风险

F-3 三条本轮原样保留（`raises the budget` 实为替换可升可降、`1000..120000 ms hard-capped` 实为越界拒绝、`head and tail` 在成功路径只保 head），未顺手处理亦未加论证。按契约不阻塞，记录在案；若第 3 条改动顺带把主语补回，「头尾」那条至少对 text/console 与 `run_command` 桥接两种情形不再混为一谈。

- 没跑 CI：本票是评审文档，不产生代码提交；AGENTS.md 就绪清单的「CI on exact commit」与「驱动一次真实交互」两项未做。
- 「描述 1011 进帽后模型实际看到什么」没有线上抓包实测，1024 帽与截断行为仍由代码路径核出（`model_tool_schema.zig:4/:66-74`、`chat_completions_protocol.zig:570`、`builtins/gateway.zig:301-336`、`bridge.zig:1333`）。
- F-1 的语义保全清单是逐句静态对照，未验证模型理解；ISSUE-34 的「同类误用归零」指标仍待后续 session 观测。
