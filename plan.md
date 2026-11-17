# T-21-plan 实现方案：codemode 目录预算通知与配置打磨（F2/F4/F5/F6）

依据：`issues/ISSUE-21.md`、`/Users/example/Project/Zig/fx/.agents/tasks/T-15-plan/review-copy.md` §7 非 blocking F2/F4/F5/F6。
实测口径（本工作树，`python3` 按字面量拼接统计）：`discovery.catalog_hint` 404 B；单个 `omitted` 条目序列化 48 到 70 B（`vision` 48，`write_file` 52，`ask_user_question` 59，`acp_delegate_cancel` 61，26 字符 MCP 名 70），均值 58 B；数组自有属性开销 `,"hint":"…"` 10 B、`,"omitted":[…]` 13 B。

F5 与 F2 联动，地板值按 F5 之后的通知体积定，两条一起落。落地顺序建议：F4 → F5（含 Selection 字段）→ F2（地板值与注释、哨兵测试）→ F6（独立）。

## F4 默认值单源（先做，F2 的哨兵测试要用它）

裁决：删 `src/tools/codemode/catalog.zig:15` 的 `pub const default_budget_bytes`，权威留在 `src/core/config/context_limits.zig:32`。理由：`select()` 已经把 budget 当参数收，本身不该拥有默认值；配置默认值由 `--context-limit` 与 settings.json 解析，反向让 config 依赖工具文件会倒置依赖；而尺寸哨兵测试的用途正是看护出厂默认值，只有从配置处读取，上调默认值时哨兵才会跟着动（今天读 catalog 常量等于静默失去保护）。

改动：`catalog.zig:198` 与 `catalog.zig:200` 改用 `context_limits.Name.codemode_catalog_bytes.defaultBytes()`。import 写在 test 块内部（`const context_limits = @import("../../core/config/context_limits.zig");`），catalog.zig 的生产代码面保持零 config 依赖。`src/tools/codemode/codemode_tool.zig:236` 的字面量 `16 * 1024` 同批换成同一来源。

测试：无须新增，`catalog.zig:198` 那条尺寸哨兵本身即回归；`zig build test` 后确认 catalog 两处测试仍绿。

## F5 通知对齐 tool_search 先例（挂在 hint 尾部，单点）

裁决：追加进 `hint` 尾部，不动 `omitted`。`omitted` 是结构化数据，模型按字段遍历，往那里塞文案会把一条通知拆成两处读；hint 已经是唯一的自然语言位。形状照 `src/core/mcp/tool_search.zig:338`（observed / effective / source / `override with --context-limit KEY=BYTES|off`）。

改动 1，`src/tools/codemode/discovery.zig:18` 之后新增模板常量（123 B 模板，渲染后 ≤156 B）：

```zig
pub const catalog_budget_clause =
    " Budget: observed={d} bytes effective={d} bytes source={s}; " ++
    "override with --context-limit codemode_catalog_bytes=BYTES|off.";
```

改动 2，`catalog.zig:47` 的 `Selection` 加 `observed_bytes: usize`，两处返回都取 `selectGroups` 已在 `catalog.zig:65-68` 算好的 `total`。理由：通知里的 observed 必须等于闸口实际比较的那个数，重新求和会在未来分组（MCP group）下与判定口径分叉。

改动 3，`host.zig:99` 旁加 `catalog_source: context_limits.Source = .compiled_default`（带默认值，`bindings_tests.zig:487/504/522/539/621/647` 六处 `host.catalog_budget = …` 不动），host.zig 增加 context_limits import。`codemode_tool.zig:229` 的 `catalogBudgetFor` 改返回 `struct { bytes: ?usize, source: context_limits.Source }`，一次判定同时给出字节与来源，避免两处复制 gate 条件；`codemode_tool.zig:282` 分别赋值两个字段。

改动 4，`host.zig:698` 的 `appendCatalogNotice` 签名加 `alloc`、`budget`、`source`（调用点 `host.zig:620` 传 `selection_arena_state.allocator()`，字节串随 arena 一并释放；`budget` 取 `host.zig:590` 已在作用域的值），`host.zig:740` 处改为先 `alloc.print("{s}" ++ discovery.catalog_budget_clause, .{ selection.observed_bytes, budget, source.label() })`，再与 `discovery.catalog_hint` 拼接成一条字符串注入 `hint`。

测试：扩 `src/tools/codemode/bindings_tests.zig:498` 那条，除现有 `indexOf("searchTools")` 外断言 `budget_schemas`（`bindings_tests.zig:456`，两条合计字节已知）渲染出的完整子串 `observed=<fixture 合计> bytes effective=200 bytes source=compiled default` 与 `indexOf("--context-limit codemode_catalog_bytes=BYTES|off") >= 0`；再把 `host.catalog_source = .command_line` 单断一次标签渲染为 `command line`。`bindings_tests.zig:234-240`（`codemode_tool.zig` 的 gate 测试）补断 `source` 字段随 `--context-limit` 变为 `command_line`。

## F2 通知地板重算

裁决：`catalog.zig:11` 的 `catalog_notice_floor_bytes` 从 512 改为 **1024**，并改掉过度承诺的注释。计算依据（F5 之后的通知体积，全部取上界）：渲染后的 hint ≤ 404 + 156 = 560 B，加自有属性开销 10 B = 570 B；`omitted` 数组壳 13 B；预期最大 omitted 条目 6 条 × 最坏 70 B = 420 B；合计 1003 B ≤ 1024，余 21 B（按 58 B 均值则余 93 B）。取 6 条的理由：今天 9 项面里 4 项 tier 零豁免，物理上最多只可能省略 5 条，6 已经比当前面上界多一条，够第一批 MCP group 进来时不必再动这个常量。地板从 512 涨到 1024 = 默认预算的 6.25%，`entries_budget` 由 15872 变 15360；当前面整体不超预算，因此今天零行为变化。

`catalog.zig:78-79` 注释改成陈述事实，不再承诺保证：地板是在放置条目**之前**预留的通知空间，覆盖 hint 与最多 6 条 omitted；更长的省略列表会让返回总量超出预算，届时的处置是给 `omitted` 设上限（先例 `src/core/skills/skill_runtime.zig:18` 的 `catalog_notice_name_count = 8` 加 `+K more`），而不是继续抬高地板。`catalog.zig:10` 那句引用 host.zig `options_output_floor_bytes` 的类比保留。

同步改注释里的算术（数值变了，测试结论不变）：`catalog.zig:382`（700 预算下地板由剩 188 B 变为饱和到 0，仍只留 tier 零）与 `catalog.zig:396-397`（1000 预算下 entries 预算由 488 变为 0；648 B 的中间项依旧「放不下但整预算放得下」，`oversized` 口径的判别力保持）。`catalog.zig:270`、`catalog.zig:294` 等按常量算术的测试自动跟随。

关于「通知本身不受预算度量」：不需要改。通知必达不是地板给的，是构造给的：`host.zig:698-746` 在选择之后无条件挂上 `omitted` 与 `hint`，全程不读预算也不截断。若把通知纳入度量，恰好造出 F2 最怕的失效形态（目录被裁了而告诉模型怎么找回的那句话也被裁了），而且通知长度依赖省略条数，度量会形成回环。地板的职责只是让「列出的条目 + 通知」在预期情形下仍落在用户配的预算内，1024 已经把这件事做到当前面之上再加一批 MCP group。残留的超出（省略超过 6 条）由条目字节主导、量级为每条 58 B，按上面注释陈述处理。

测试：新增一条地板哨兵，放在 `catalog.zig` 测试区。用 `catalog_budget_clause` 模板代入两个 12 位数字与最长来源标签 `workspace settings`（`context_limits.zig:51-58` 里最长者）渲染出 hint 上界，断言 `catalog_notice_floor_bytes >= 10 + rendered_hint.len + 13 + 6 * 70`。它把 F2 与 F5 钉在一起：以后再往 hint 或 clause 里加句子，这条测试先红，而不是悄悄吃掉地板。

## F6 limit 报错拆两条

现状 `src/tools/codemode/host.zig:764`：非整数、小于 1、大于 65536 三种情况共用 `searchTools limit must be a positive integer`，对 `limit: 100000` 是错的（100000 正是正整数）。

裁决：新增 `pub const max_search_limit: usize = 65536;` 到 `src/tools/codemode/discovery.zig:9` 的 `default_search_limit` 旁边（与 `max_describe_candidates` 同族），host 的检查与消息都引用它，数字只写一处。`host.zig:764-767` 拆成两条，顺序是先形状后上限：

```zig
if (!std.math.isFinite(as_float) or as_float != @trunc(as_float) or as_float < 1.0) {
    c.JS_FreeValue(context, limit_value);
    return c.JS_ThrowTypeError(context, "searchTools limit must be a positive integer");
}
if (as_float > discovery.max_search_limit) {
    c.JS_FreeValue(context, limit_value);
    return c.JS_ThrowTypeError(context, "searchTools limit must not exceed %d",
        @as(c_int, @intCast(discovery.max_search_limit)));
}
```

显式补 `isFinite` 是给 `Infinity` 用的：今天它被 `> 65536.0` 抓住，拆条之后会落到「不超过 65536」这条错文案上；补了 `isFinite` 它就归「必须为正整数」。`%d` 传 `c_int` 而非 `usize`，QuickJS 按 `int` 取参，别把 64 位值塞进变参。精确文案字面：`searchTools limit must be a positive integer` 与 `searchTools limit must not exceed 65536`。

测试：`src/tools/codemode/bindings_tests.zig:551` 那条 probe 只 push `e.name`，拆文案后两条消息仍是同一个 `TypeError`，必须新增一条断言 `e.message` 的测试（不要改老的，形状覆盖留在那里）：`limit: 0`、`limit: 100000`、`limit: 65536`、`limit: Infinity`、`limit: -1`，期望依次为 `must be a positive integer`、`must not exceed 65536`、`ok`（边界 65536 保持放行，与现检查一致）、`must be a positive integer`、`must be a positive integer`。

## 验收

`zig fmt src/`、`zig build test`（重点 `catalog.zig`、`bindings_tests.zig`、`codemode_tool.zig` 三处测试），再 `./zig-out/bin/fx` 跑一次真实 codemode 调用：默认 16 KiB 下面不触发预算，`tools.list()` 返回值应与今天逐字节一致（F5/F2 只改触发路径），`searchTools("q", {limit: 100000})` 抛出新文案。无用户可见的 CLI 面变化，`--help` 不动（`command_specs.zig` 那条断言本就不枚举预算键名）；`fx.sh/docs` 的 context limits 页若已有 `codemode_catalog_bytes` 段落，需配套说明通知里的 override 用法，按 AGENTS 的 Docs 章节由有权限的人提。
