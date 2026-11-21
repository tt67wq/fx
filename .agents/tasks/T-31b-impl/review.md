# T-31b-review — ISSUE-31 A 档 SyntaxError 转义泄漏定向提示评审

- 评审者：fx-pi1（未参与 T-31b-impl 实现，作者独立性成立）
- 所核 commit：红 2358ea1a27079f233affd273d3034e4c683cbc15，绿 e4b177d36c33196da1e250ae314dc12cd1a57cce（fx-pi2 分支 T-31b-impl，基线 5f4856177）
- verdict：**approve**（1 条非阻塞观察：检测边界的已知误报面，措辞诚实，可接受）

## 1. 检测边界（最高优先）— 论断部分成立，误报面可接受

- 「编译成功的 script 不进此路径」成立：escape_leak 扫描在 annotatedExceptionMessage
  的 SyntaxError 分支内，编译成功无 SyntaxError，扫描 never runs（负例 c 实测绿）。
- **但「合法字符串字面量内 \" 不误报」不完全成立**：评审者独立构造探针
  `text("a\"b"); const o = { a: , };`（合法转义字符串 + 另有语法错），实测输出：
  「SyntaxError: unexpected token in expression: ',' (codemode.js:1:30). JSON escape
  leak: the script still contains backslash-quote; write " directly...」——合法字面量
  内的 \" 触发了提示（误报）。根因：扫描是源码级 std.mem.find(script, "\\\"")，
  不区分 code-token 级与字符串字面量内的 backslash-quote。
- **可接受性结论**：提示措辞是「the script still contains backslash-quote; write "
  directly」——陈述「检测到残留转义」这一事实（源码确实含该序列），而非断言「这就是
  失败原因」。措辞诚实，未误导因果；且仅在 SyntaxError 已发生时追加，失败本身另有
  引擎消息与位置。误报面受限（编译失败 ∧ 源码含 backslash-quote），对模型是温和的
  额外线索而非错误诊断。故可接受，非阻塞。建议后续若做 B 档或精化，可考虑 token 级
  扫描排除字符串字面量内部，但本轮 A 档最小提示不必扩。

## 2. current_script 生命周期 — 成立

- Host.current_script: []const u8 = &.{}（borrowed），eval 起点 :248 置为 script。
  captureExceptionMessage 的两个调用点（takeExceptionError :554 编译失败、eval :282
  运行期拒绝）都在 eval 调用栈内，script 借用在 eval 期间有效，无悬空。
- eval 结束后 current_script 仍指向旧 script，但下次 eval 起点重置；lastExceptionMessage
  读的是已 copy 到 host allocator 的 last_script_error（annotatedExceptionMessage 产物），
  不再解引用 current_script，故 eval 外读取安全。
- 并发/重入：Sandbox 在专用线程驱动单个 Host（sandbox.zig:9-13），eval 串行（一次一个
  request slot），无并发 eval；current_script 单线程读写，安全。

## 3. 提示文案与优先级 — 成立

- top-level return 分支（return not in a function）在 escape_leak 判定后、escape_hint
  追加前 return，优先级保持（既有钉死测试不变）。ReferenceError/TypeError 分支零触碰。
- 文案含 "JSON escape" 与 "write " directly" 语义；纯 ASCII、无 emoji、无 -- 破折号
  （脚本逐字符核验 added 行 nonascii=[] dashes=[]）。

## 4. 红绿链 — 成立（评审者独立复跑红）

- 独立 git worktree 检出 2358ea1a2 跑 zig build test：escape-leak 测试实测红
  （failed without output，缺提示），与 red-evidence 一致。b/c 负例 trivially 绿，
  red-evidence 如实注明「pass trivially (negative cases)... pin the no-false-positive
  boundary」。
- 绿 commit 顺手修正红测试 a 的 write-directly pin（write \\\" → write \"）与 c 的
  var result/期望串，使其与实现提示精确对齐——impl-report 如实声明「绿 commit 顺手
  修正红测试措辞...红失败原因仍是缺提示」。诚实。
- 绿 e4b177d36 三测试全绿（评审者自跑主二进制 10029 pass/2 skip/0 fail，三条 escape
  测试逐条 OK）。

## 5. e2e — 成立

- 新增断言在既有已分类文件 codemode-admission.test.ts（corpus.json 含 1 条），
  「codemode script mistake feedback」describe 内增 1 测试；--diff-filter=A 无新建
  root e2e 文件。评审者自跑该单条 76ms 绿。

## 6. 机械核验（评审者自跑，fx-pi2 checkout）

1. zig build test：TEST_EXIT=0（command_runner 超时 flake 本轮未现；红复跑亦未现）。
2. zig fmt --check src/：FMT=0。
3. check-public-surface.sh SURFACE=0；agents/compactor/indexer/recovery 四边界各 0。
4. FX_BENCH=1 ./zig-out/bin/fx help：SMOKE=0，stderr 0 字节。

## 7. 红线核对

- diff 仅 host.zig(+17/-3)、bindings_tests.zig(测试)、codemode-admission.test.ts(+29)、
  文档。B 档 unescape 未做；bridge.zig 零触碰；描述字符串（builtins/tools.zig）零触碰；
  admission/permissions/catalog/tests/tla 零触碰（name-only 唯一匹配是 e2e 测试文件名
  含 admission 字样，非 admission 逻辑）。无新 settings/CLI/env；无个人路径。

## 备注（非阻塞）

- 检测边界的字符串字面量内误报（见 1）措辞诚实、面受限，可接受；若后续精化可做
  token 级扫描，但非本轮 A 档要求。
- 评审探针为临时添加、运行后已 git checkout 还原，fx-pi2 工作树干净（git status 空）。
