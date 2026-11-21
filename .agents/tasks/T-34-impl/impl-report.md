# T-34-impl 实现报告 — ISSUE-34 codemode 常见误用前置到工具描述

- 分支：T-34-impl（基线 integrate-issue29 HEAD 5f4856177）
- 红 commit：9de4608fd（钉死测试先改，实测红）；绿 commit：描述落地
- 零执行语义变更：只动 codemode_description 字符串与钉死测试；host/bridge 逻辑零触碰。

## 路线选择：A（压缩现有描述腾额度）

选 A 而非 B：三则坑共 ~36 词，通过压缩现有描述的冗余措辞（合并 tools.list()/searchTools/
describeTool 两句、精简预算与收尾句）即可在**不增长净字数**的前提下塞入，无需动目录预算
机制（B 会触及 discovery/catalog 语义，红线禁动）。A 更最小、零机制风险。

## 字符预算前后对照

| 项 | 改前 | 改后 | 约束 |
|---|---|---|---|
| 字节长度 | 1173 | 1172 | <=1172（收紧 1） |
| 净字数 | 179 | 169 | 不增长（C4），实际降 10 |
| 长度钉 | <=1173（T-29） | <=1172 | 测试注释注明新上限与理由 |

三则坑全部前置到描述（模型写 script 前必读）：
1. 「Confirm names via searchTools("keyword"), never from memory.」（猜工具名）
2. 「No Node.js API: no import/require of fs or process, no top-level tool functions.」（require fs / 裸调函数）
3. 「arguments are objects, e.g. tools.call("run_command", {command: "..."}).」（参数是对象）

压缩手法（语义无损）：合并调用形式两句为一句并顺带植入坑3；tools.list() 与 searchTools/
describeTool 合并为一句；「The script runs on a default 30 second wall-clock budget」→
「Default: 30 second wall clock」；「top-level return is not valid script syntax」→
「top-level return is invalid」；「A script that only wraps one tool call is slower than
calling the tool directly」→「Wrapping one tool call is slower than calling it directly」。
所有既有语义（预算/捕获帽/@options/min 嵌套/头尾省略/read_tool_result 回读）保留。

## 红绿（TDD）

- 红（9de4608fd）：budget 测试增钉三则关键短语（Confirm names via searchTools / never from
  memory / No Node.js API... / arguments are objects / tools.call("run_command", {command:
  "..."})）+ 长度 <=1172。zig build test 实测红：
  'builtins.tools.test.codemode description states the nested command budget truthfully'
  failed（10031/10034，1 failed）。证据 red-evidence.txt。
- 绿：codemode_description 改为压缩+三则版（1172 字节 / 169 词）。zig build test 全绿。

## byte-exact 哈希核查（无需重钉）

codemode **不在** `all` 注册表（16 工具）内，仅经 `gated_all = all ++ {codemode}` 在 gate
开时追加。byte-exact 契约测试只哈希 `all` + advertisement_order + shellProcessOnlySpec，
不含 codemode，故 codemode_description 变更**不影响**该哈希——双平台哈希维持 T-31 值
（darwin 861c380f… / linux df9fe455…），实测 byte-exact 测试绿，无需重钉。
（T-31 重钉是因为 read_tool_result 在 all 内；本轮 codemode 不在，情形不同。）

## 验收证据

1. 红 9de4608fd 先于绿；zig build test 全绿（最新主二进制 10026 passed / 2 skipped /
   0 failed；codemode description / byte-exact / read_tool_result metadata 三测试逐条 OK）。
2. zig fmt --check src/ 退 0；check-public-surface.sh 退 0；agents/compactor/indexer/
   recovery 四边界脚本各退 0。
3. 三则关键短语钉死测试绿；长度/字数预算对照表见上。
4. FX_BENCH=1 ./zig-out/bin/fx help 退 0、stderr 0 字节。
5. 产物：红/绿 commit + impl-report.md + red-evidence.txt。

## 红线自查

- 零执行语义变更：host/bridge 逻辑零触碰（ISSUE-31/32 未碰）；只动描述字符串与钉死测试。
- compactor/admission/permissions/catalog 语义零触碰；无新 settings/CLI/env；tests/tla/ 零触碰。
- 无 emoji；文案无 -- 破折号；纯 ASCII；个人路径零入码。zig fmt 后提交。
- 观察指标（ISSUE-34 处置项3）：下轮 session 分析中本类失败次数是否归零，属后续观察，非本轮代码。
