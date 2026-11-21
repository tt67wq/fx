# T-36-review2 复审报告：ISSUE-36 防护层补齐（上轮 CHANGES-REQUESTED 的消解）

- 评审者：fx-pi4（上轮 changes-requested 原作者，本轮复审自己的三条阻塞项是否被正确消解）
- 所核 SHA：fix 绿 `699e47547`、fix 红 `877ff08ec`、报告更正 `4bc2efaba055aad7aa92c5026af8585dc580b960`、上轮所核 `ec46a6290`、T-36 基线 `7ea4f19da`
- 核验方式：`/tmp/t36r2v` 新建 detached worktree 检出树尖 `4bc2efaba`，全部命令我自己跑；红链在同一 worktree 切到 `877ff08ec` 的 `src/builtins/tools.zig` 实测复现后还原（dirty=0）。先核一条：`git diff 699e47547 4bc2efaba -- src/` 为空，树尖与 fix 绿的源码逐字节相同，报告更正 commit 未夹带代码。

## Verdict: APPROVED

三条阻塞项全部消解，且这轮是逐字节实测过的，不是读声明读出来的。我上轮 F-1 的实质问题（描述在模型侧被截）与防护问题（没有任何东西守着这条线）现在都关闭了：描述 1024 字节整，零截断；两道 guard 都在树内并且都被我实测成「在旧 1172 描述上确实红」。ISSUE-36 四条处置项，现在四条为真。

留两条不阻塞的尾账（见「尾账」节）：报告 `Byte/word comparison` 一行的改前字节数仍是错的（写 251，真值 241），以及钉死测试里的 `else unreachable`。

## 1. 阻塞项 1 消解：帽测试扩面（为真）

绿树尖 `src/builtins/tools.zig:940-951`，我逐字读过：

```zig
test "built-in tool descriptions fit the model-facing description cap" {
    // ... gated_all includes codemode, whose description rides the same cap
    // through the builtins advertisement and the run_script schema
    // injection (ISSUE-36 F-1).
    inline for (gated_all) |tool| {
        try std.testing.expect(tool.description.len <= model_tool_schema.description_max_bytes);
        for (tool.model_schema.input_schema.properties) |property| {
            try std.testing.expect(property.description.len <= model_tool_schema.description_max_bytes);
        }
    }
}
```

- 覆盖面：`inline for (gated_all)`（`:945`），`gated_all = all ++ {codemode}`，描述与 property 描述两层都过，正是我上轮要求的形状。
- 我上轮的核心担忧（「1011 靠人肉维持」）现在不成立：描述若写回 1025 字节，此测试与长度钉双双红。我在红 commit 上实测就是这个效果。
- byte-exact 覆盖面未动：我把基线与树尖的 `test "built-in model-facing tool contract stays byte exact"`（`:904`）测试体做逐字节比较，**完全相同**，仍 `inline for (all)`。哈希不含 codemode 的结论沿用 T-34/T-36 上轮，两个平台钉值未变，我的全绿实测包含该测试通过，所以「无需双平台重钉」成立。这一点做对了：扩面只扩帽测试，没顺手扩哈希覆盖面（那会改哈希、必须重钉）。

## 2. 阻塞项 2 消解：长度钉改常量（为真）

`tools.zig:772-775`：

```zig
// ISSUE-36 F-1: the model-facing cap is 1024 bytes and overlong text
// is cut at 1009, so the whole description must fit; the compressed
// 1024-byte, 144-word wording also stays below 169 words (C4).
try std.testing.expect(codemode_description.len <= model_tool_schema.description_max_bytes);
```

- 钉值改为常量引用，`1172` 魔数已除：全文件 grep `1172|1011` 零命中（剩下的 `[0]` 命中属 `shell_properties` / `subagent_properties` 的既有代码，与 codemode 无关）。
- 注释为真实值：我实测描述 1024 字节 / 144 词，且 144 < 169 成立（C4 不增长约束仍满足）。上轮那条「注释成了错误文档」的问题已修。
- 帽若将来上调，钉自动跟随，这正是我给的修法理由。

## 3. 阻塞项 3 消解：红真的红在两道 guard 上（为真，我实测）

红 commit `877ff08ec` 的做法是把描述**回退成 T-34 的 1172 字节版**、同时让两道 guard 带上修复。我核它回退的串与基线逐字节相同：`git show 877ff08ec` 的 `codemode_description` 与 `7ea4f19da` 的相等（1172/169）。这比造一个假串更诚实：红测的是真实旧状态。

我在 worktree 里实测复现（`git checkout 877ff08ec -- src/builtins/tools.zig && zig build test`）：

- 退 1
- `error: 'builtins.tools.test.codemode description states the nested command budget truthfully' failed without output`
- `error: 'builtins.tools.test.built-in tool descriptions fit the model-facing description cap' failed without output`
- `Build Summary: 20/22 steps succeeded (1 failed); 10030/10034 tests passed (2 skipped, 2 failed)`

与 `red-evidence.txt` 记录的两条测试名、两条计数逐字一致。同时我也确认 `5472dccf2`（上轮那个红）的串是 1172、钉是 `<= 1172`、帽测试是 `all`，所以上轮那个红只红在 F-2 措辞上，与我这轮的结论一致。

上轮错误归因的更正，我认为诚实且与树内证据自洽：`red-evidence.txt` 现在写明「it claimed the cap-test widening and the <=1024 pin were in the red commit, but the edit script aborted before writing the file and only the F-2 pins landed」，`impl-report.md` 的 Correction 1 同口径。这个解释与客观痕迹吻合：`5472dccf2` 是 5 insertions / 0 deletions 单 hunk，确实只有 F-2 两行断言，没有任何扩面或改钉的痕迹。不是狡辩，是可验证的成因说明。

## 4. 描述终态：1024 字节，语义仍逐句无丢失

- 终态 1024 字节 / 144 词，`cappedDescriptionAlloc` 的判据是 `text.len <= description_max_bytes`，等于帽即**不截**，所以「零截断」在字节层面成立。余量为 0 字节，这是采纳我那条可选建议的代价，见尾账 3。
- 与我上轮已判定「无删减」的 1011 版对照，改动是**单一处 13 字节**：`head and tail are kept with omitted byte count` 改回 `text and console keep head and tail with omitted byte count`，即我上轮给的第二个候选（带 `the` 的老措辞 1027 会越界，不带 `the` 的正好 1024）。我用 `b == a.replace(old,new)` 证明其余部分逐字节相同，因此语义无损结论由上轮直接继承，并补回了我点出的主语缺失（两条流各自被截这件事重新可读，实现里 `text_dropped_bytes` 与 `console_dropped_bytes` 确实分开计数）。
- 新偏移全部在帽内（帽 1024，全文 1024）：三则坑 `arguments are objects` 126-192、`Confirm names via searchTools, never from memory` 194-242、`No Node.js API: …` 244-323；`tools.list() may be a budgeted subset` 325-362、`searchTools(query) searches the full surface` 364-408、`describeTool(name) returns one full schema` 410-452；`Defaults: 30s wall clock, 1MiB capture cap` 454-496、`text and console keep head and tail…` 507-566、`read_tool_result reads the full output` 568-606、`First non-empty line` 608-628、`1000..120000 ms hard-capped` 713-740、`4 bytes per token` 749-766、`a declared budget is the script's wall clock` 785-829；以及上轮被截、这轮必须完整的三句：`min(requested, remaining budget) from its own start` 857-908、`Finish with text(your short summary)` 910-946、`top-level return is invalid` 948-975，末句 `Wrapping one call is slower than a direct call` 977-1023。
- ISSUE-23b 的两条反向钉仍满足（`also caps nested run_command`、`capped at it from its own start` 均不在串内），正向钉逐字在串内且被钉死。

## 5. 生效探针：树内无残留（可核部分已核）

探针本身是瞬时的，我无法重跑，能核的是「没留下东西」，四条都过：

- 我实测 `4bc2efaba` 工作树 `git status --short` 空。
- `git diff 699e47547 4bc2efaba -- src/` 空，报告更正未夹带代码。
- 逐个 commit 量描述字节数：`5472dccf2` 1172、`ec46a6290` 1011、`71a444941` 1011、`877ff08ec` 1172、`699e47547` 1024、`4bc2efaba` 1024。历史里不存在 1192 字节的串，即那两句 inert padding 从未进过任何 commit。
- 探针的结论我用更强的方式独立复现了：直接测旧 1172 版（第 3 节），两道 guard 双双红。所以「guard 真的会响」不依赖报告自述。

## 6. F-2 加固：按 name 取（为真），订正部分落地

- 取法由 `properties[0]` 改为遍历后 `if (std.mem.eql(u8, property.name, "script")) break property.description;`（`tools.zig:767-769`），位置索引已除；正反两条断言（对象形态在、`still works` 不在）仍绿。
- 字节数订正：我实测 script 参数描述 **改前 241 字节（29 词）→ 改后 224 字节（27 词）**。报告 Correction 2 已把「改后」订正为 224 ✓，但 `Byte/word comparison` 那行仍写 `251 bytes string-form`，见尾账 1。
- 224 远在 1024 property 帽内，且这轮起该 property 真受帽测试约束（gated_all 里的 property 循环）。

## 7. 机械核验（树尖 `4bc2efaba`，全部我跑）

| 检查 | 结果 |
|---|---|
| `zig fmt --check src/` | 退 0 |
| `zig build test` | 退 0，输出 0 字节（全绿） |
| `zig build` | 退 0 |
| `./scripts/check-public-surface.sh` | 退 0 |
| `check-agents/compactor/indexer/recovery-boundary.sh` | 各退 0 |
| `FX_BENCH=1 ./zig-out/bin/fx help` | 退 0，stderr 0 字节 |

报告提到绿首轮与探针轮各撞一次 `command_runner` flake（"runtime cancellation observed at the timeout deadline stays graceful"）后复跑转绿。我在树尖一次跑就全绿，没遇到该 flake；我的红复现运行里失败数正好是 2，也没混进这条。所以 flake 声明与我观测不冲突，但也未被我复现，按未证实处理。

## 8. 红线

`7ea4f19da..4bc2efaba` 只碰 `src/builtins/tools.zig` 与 `.agents/tasks/T-36-impl/` 两份文档。`model_tool_schema.zig` 零 diff，帽常量仍 `= 1024`（`:4`）；`host.zig` / `bridge.zig` / `discovery.zig` / `catalog.zig` / `tests/tla/` 零触碰。`src/` 改动行纯 ASCII、无 `--`、无个人路径；描述字面量内无 `--`、无非 ASCII。commit author 与全仓惯例一致。

## 尾账（都不阻塞）

1. **报告数字残留一处错**：`impl-report.md` 的 `Byte/word comparison` 仍写 `Script parameter description: 251 bytes string-form -> 224 bytes object-form`。改前真值 241（245 源码字符），251 是我上轮 T-34-review 的测量误差（把属性名 `script` 的 6 字符和未解码的 `\"` 一起算进去了），Correction 2 只把「改后」订正干净，「改前」还挂着我的旧错数。下次顺手把 251 改 241 即可，我在这份复审里已给出可复核的真值与来源。
2. **钉死测试的 `else unreachable`**（`tools.zig:769`）：若 `script` 这个 property 被改名或删掉，for 表达式走到 `else unreachable`，在 safe build 里是 trap 崩溃，而不是带信息的测试失败。断言强度没问题（崩溃也算响），但排查时看不到「哪个不变量破了」。改成显式失败（比如 else 分支给 `std.testing.expect(false)` 或取不到就 fail 并打印属性名）更好读。测试专用代码，不阻塞。
3. **余量归零**：描述现在正好等于帽，1024/1024。这是采纳「主语补回」建议的直接代价，方向我认同（内容比余量重要），但要说明后续任何人往描述里加一个词都会双红，必须同处删一点。两道 guard 现在正好会把这件事显式摊开，我认为可接受；记录于此免得像隐藏约束。
4. **F-3 三条继承措辞**（`raises the budget` 实为可升可降的替换、`1000..120000 ms hard-capped` 实为越界拒绝、`head and tail` 在成功捕获路径只保 head）本轮仍原样保留，未处理也未加论证。按契约不阻塞；第 4 条这轮因主语补回而更可查（现在明确是 text/console 双流各自截），但「头尾都留」对成功路径仍不真，值得并入后续票一并清。

## 我没核 / 风险

- 没跑 CI：本轮是评审文档，不产生代码提交，所以 `AGENTS.md` 就绪清单的「CI for the exact commit」与「驱动一次真实交互」两项未做。树尖全绿不等于 PR CI 绿。
- 「模型在帽内实际读到什么」仍无抓包实测；1024 截断行为、`<=` 判据与三条出网路径都由代码读出（`model_tool_schema.zig:4` 与 `:66-74`、`chat_completions_protocol.zig:570`、`builtins/gateway.zig:301-336`、`bridge.zig:1333`）。
- 语义无损的结论是静态逐句比对（含 `b == a.replace(old,new)` 的单一改动证明），未验证模型理解效果；ISSUE-34 的「同类误用归零」指标仍待后续 session 观测。
- 探针那一轮的运行我无法复现，只核了它没留痕迹；`command_runner` flake 声明同理。
