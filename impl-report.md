# T-15-impl 实现报告 — ISSUE-15：codemode 工具目录预算 + searchTools/describeTool

工作树：/Users/admin/Project/Zig/fx-pi3，分支 T-15-impl（基于 origin/main 2e9d2ef9f）。

## 提交

- 红：9dfc58331 "Red: T-15 failing tests for codemode catalog budget and searchTools/describeTool discovery"（26 个测试失败，红已验证：catalog 选择器骨架、discovery 骨架、host 测试全部失败于未实现行为）。
- 绿：见下方 commit（实现 + 少量红测试期望修正，理由见"偏差"）。

## 实现范围（对照任务书逐条）

### 1. 预算配置
- src/core/config/context_limits.zig 新增 codemode_catalog_bytes，默认 16 KiB，接入 Name 枚举、defaultBytes、Values、Overrides。免费获得 --context-limit codemode_catalog_bytes=BYTES|off 与 settings JSON 解析（既有 parseOverride/parseJsonObject 走 Name.parse，无新代码）。
- 未放 experimental（switches-only），未放裸常量。验证：./zig-out/bin/fx --context-limit codemode_catalog_bytes=123 ... status 退 0；=off 退 0；=notanumber 报 invalid global launch option: InvalidContextLimitValue。

### 2. 预算度量与触发（三重门）
- 门1 结构：codemode_tool.call 通过 catalogBudgetFor(derived_surface, limits) 只在 derived_surface 时向 host 注入 budget；4 项面永不进入预算路径（单测 "catalog budget gate opens only on the derived surface with a non-off limit"）。
- 门2 字节：整面 schema_json 字节合计 > 预算才触发（catalog.select 内判定，total <= budget 时返回 triggered=false 与全量 indexes）。
- 门3 配置：off 时 normalBytes()=null，budget 不注入，永不触发。
- 度量单位 = schema_json 字节和，无 token 估算。整项进出，无截断。
- 尺寸哨兵测试锁住"今天不触发"：真实 9 项 derived 面 schema 字节合计 < 16 KiB（测试 "catalog keeps the real nine-item derived face whole under the default budget"），并将该断言与 triggered=false、9 项全量绑定。

### 3. 选择算法
- 新文件 src/tools/codemode/catalog.zig（与 bindings/bridge 同目录：选择器消费 bindings.ToolSchema，被 host.zig 消费，放 codemode 内聚）。纯函数、零跨调用状态；接口 selectGroups(alloc, groups: []const Group, budget) 为未来 MCP 分组留位，v1 select() 包一个组。
- 分层：T0 = glob_files/grep_files/read_file/run_command（豁免：必内联、不占条目预算）；T1 = write_file/edit_file；T2 = 其余（web_fetch/ask_user_question/vision 及未来动态工具）。
- 层内按 face 顺序；首个装不下的非豁免项触发级联，其后所有非豁免项进 omitted（照抄 AlwaysLoaded 累计语义，不跳大塞小）。listed 与 omitted 输出均保持 face 顺序。
- 装配顺序：先预留 catalog_notice_floor_bytes = 512（omitted 清单 + hint），条目预算 = budget - 512（饱和减法）。
- codemode_description 头部静态文本不在预算路径内（预算只作用于 tools.list() 返回）。

### 4. tools.list() 返回形状
- 触发时：数组追加自有属性 omitted（[{name, bytes, oversized}]）与 hint（字符串）。测试断言对 for..of / map / 下标 / JSON.parse(JSON.stringify()) 不可见，length 不变。
- 未触发时：不添加任何自有属性，条目构建代码与原实现同形（重构为 buildListEntry/appendListEntry，字段与顺序逐字节一致）；budget 为 null 时连选择器都不进入。

### 5. searchTools / describeTool
- 新文件 src/tools/codemode/discovery.zig（纯函数，无 IO 无时钟，allocator 显式传入）。约 340 行含单测。
- 语料 = name + description + 参数名与参数描述（std.json.parseFromSliceLeaky 解析 schema_json；解析失败的条目仍按名字可搜）。
- 索引随注入构建一次：Host.setToolSchemas 内 build；eval 内复用。索引字符串借用 schema 生命周期（schema_json 归 codemode_tool 的 schema arena，host 先于 arena 释放，顺序已核对：sandbox.deinit 先于 schema_arena.deinit）。
- searchTools(query, opts?) 返回 [{name, description}]；limit 默认 8；0/负数/非整数/非数字抛 TypeError（JS 侧校验，Zig 侧另有 1..65536 上限防荒谬分配）。
- describeTool(name) 返回与 tools.list 元素同形状（复用同一 buildListEntry，JSON.stringify 逐字段相等测试）；未知名抛 TypeError，消息含 did-you-mean 候选（不超过 5 个，Levenshtein 距离按归一化名比较，平局保 face 顺序）并提示 searchTools。
- 评分：名字 3 > 参数名 2 > 描述 1（参数描述计入描述域）；整名命中（归一化比较）置顶；平局保 face 顺序；非字母数字折叠为单个 _（mcp__x__y 与 mcp_x_y 互通）。无 BM25、无 opts.namespace。

### 6. 只读红线
- host.tool_schemas 保持全量 face；预算筛选只出现在 toolsListCallback 返回。describeTool/searchTools 按全量 tool_schemas 查找与索引，目录外工具可发现可描述（测试覆盖）。
- __codemode_whitelist、installCallShim、bridge.call 准入一律未动。测试断言调用 searchTools/describeTool 前后 Object.keys(tools) 与 whitelist JSON 深比较不变。
- bridge.schemas() 无缓存。
- searchTools 返回对象纯度：改写返回值不影响后续调用（测试断言）。

### 7. 文案（只写一处）
- src/builtins/tools.zig codemode_description 追加一句："tools.list() may be a budgeted subset; searchTools(query) finds tools across the full surface; describeTool(name) returns one full schema."。追加后描述 1007 字节 < description_max_bytes 1024，不触发截断。
- hint 常量 discovery.catalog_hint 指向真实签名 searchTools(query)（可选 {limit: N}，默认 8）与 describeTool(name)，说明排序口径（name > parameter > description）与未知名报错行为。

## 验收证据（逐条）

- zig fmt --check src/ 退 0：fmt 了 discovery.zig 后 --check 退 0。
- zig build test 清 .zig-cache 后跑：9959 个单测，首次清缓存跑出现 1 个既有 flaky 失败（见下），重跑 0 失败；后续运行退 0 无输出。
- e2e：cd tests/e2e && FX_SOUND=0 bun test codemode-admission.test.ts cli.test.ts → 153 pass / 6 skip / 0 fail（首跑 cli 1 例 flaky 失败，单跑与合跑复跑均过，见下）。
- scripts/check-public-surface.sh 退 0。
- scripts/check-agents-boundary.sh、check-compactor-boundary.sh、check-indexer-boundary.sh、check-recovery-boundary.sh 均退 0。
- 双面行为：gate 关时 catalog_budget=null，toolsListCallback 走原路径、无新自有属性（host 测试 + 既有 bindings_tests 全过）；gate 开时尺寸哨兵断言 9 项面 < 16 KiB → 全量注入 triggered=false，searchTools/describeTool 无条件注入可调用（host 级测试）。
- 不碰 src/mcp/、tests/tla/：git diff 确认未改动；边界脚本退 0。
- 本地真实交互：已运行新构建的 ./zig-out/bin/fx：--version、help、--context-limit codemode_catalog_bytes=123 与 =off 解析接受、非法值拒绝。e2e codemode-admission.test.ts 通过 tmux 驱动同一二进制走真实 codemode 准入路径。gate 开 + 真实模型回合需要 API key，本地无法驱动，该路径由 host 级单测覆盖（预算触发、目录外可发现可调用、whitelist 只读）。

### 既有 flaky（非本变更引入）

- core.execution.command_runner.test "runtime cancellation observed at the timeout deadline stays graceful"：本轮两次全量跑中各失败一次，重跑即过；位于 src/core/execution/，本变更未触碰该目录。
- cli "fx ask binds an explicitly invoked skill into the prompt"：两文件合跑首跑失败，单独跑与合跑复跑均过。
两者均为时序敏感用例，与本改动面（codemode host/catalog/discovery/context_limits/描述文本）无代码交集。

## 实现偏差（对照两提案）

1. T0 不占条目预算：提案 A 未明说。T0 豁免解释为"必内联且不计入 entries_budget"；若计入，T0 字节会挤压 T1/T2，与豁免语义冲突。已在 catalog.zig 注释写明。
2. 级联为跨层全局：任务书说"层内某项装不下则该层后续项全部进 omitted"，同时要求照抄 AlwaysLoaded.add 的累计语义；AlwaysLoaded 是全局级联，取全局（首个不 fit 后所有后续非豁免项 omitted），T0 豁免不受级联影响。提案 A 测试 5（预算只够 T0 时 T1/T2 全 omitted）两种读法一致。
3. oversized 口径：单项 bytes 大于整个配置预算（而非 entries_budget）时标 oversized，即"即使满预算也装不下"。
4. 零分条目不返回：searchTools 只返回 score > 0 的条目；否则 limit 截断会被无关工具占满，且返回语义应为匹配结果。
5. Index 内存归属：提案 B 建议索引"借用 schema arena 生命周期"。实现中 Index 结构与 token 数组由 host.allocator 持有（内部 arena 归 Index，Host.deinit 释放），语料字符串仍借用 schema_json（schema arena）。释放顺序已核对，行为等价，所有权更简单。
6. searchTools limit 上限 65536：规格未定义上限；不加上限会让脚本请求巨型结果数组撑爆输出预算。与既有 max_options_output_tokens 封顶风格一致。
7. 红测试期望修正：green 阶段修正红提交中 4 处错误期望（tokenize 连续分隔符产出 4 词而非 3；评分顺序名 3 > 参数 2 > 描述 1，红测试写反了 name/param 优先级；两个 catalog 测试的预算算术不满足 total > budget 触发条件；QuickJS 数组 getOwnPropertyNames 含下标，改用过滤断言）。均为测试本身的错误，非设计变更。
8. 未做（按任务书明确排除）：schemas() 缓存、T3/MCP 轮转、opts.namespace、BM25、experimental 配置形态。

## 覆盖清单（新增测试）

- catalog.zig：tier 分类、9 项真实面尺寸哨兵 + 不触发、total == budget 不触发、total-1 触发、T0 豁免 + 级联、oversized、notice floor、确定性。
- discovery.zig：tokenize、归一化折叠、评分三档排序、整名置顶、平局 face 序、目录外工具可搜、limit 截断、suggest 最近候选与不超过 5 上限。
- codemode_tool.zig：预算门（derived/off/null）。
- bindings_tests.zig（host 层）：两全局注入且 tools/whitelist 只读、未触发无自有属性、触发时 omitted/hint 且迭代不可见、map/下标/JSON 往返不可见、目录外可搜可描述、返回纯度、参数校验、默认 limit 8、describeTool 同形、未知名 TypeError 含候选与 searchTools 提示。
