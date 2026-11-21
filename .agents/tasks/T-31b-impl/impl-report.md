# T-31b-impl 实现报告 — ISSUE-31 A 档 SyntaxError 转义泄漏定向提示

- 实现者：fx-pi2。分支 T-31b-impl，基线 integrate-issue29 HEAD 5f4856177。
- 红 commit：2358ea1a2（先于绿）；绿 commit：见 git log（本报告同 commit）。
- 只做 A 档（报错提示）；B 档（入口 unescape 容错）明确不在本轮。

## 设计（最小）

- 接入点：host.zig annotatedExceptionMessage 的 SyntaxError 分支（现有 ISSUE-25 前缀改写处）。
- Host 增 current_script: []const u8 = &.{}（borrowed，eval 期间有效），eval 起点置为 script。
  captureExceptionMessage 把 self.current_script 传入 annotatedExceptionMessage。
- 检测：仅当 base 以 "SyntaxError:" 开头时，std.mem.find(u8, script, "\"")（backslash-quote
  两字节序列）命中即判定转义泄漏。编译已成功的 script 不进此路径，合法字符串字面量内部的 \"
  天然不误报（误报面受限：仅 SyntaxError 已发生且源码含 backslash-quote 时追加提示）。
- 提示文案（英文，纯 ASCII，无 emoji，无 -- 破折号）：
  " JSON escape leak: the script still contains backslash-quote; write " directly instead of
  escaping quotes." 追加在 SyntaxError 尾部（含位置 codemode.js:line:col 时接在位置后）。
  含 "JSON escape" 与 "write " directly" 语义。
- top-level return 分支保持原样（其优先级高于转义提示，既有钉死测试不变）；ReferenceError/
  TypeError 分支零触碰。

## 红绿（TDD）

- 红（2358ea1a2）：bindings_tests.zig 增 3 测试：
  a. codemode syntax error from a JSON escape leak names the fix：issue 典型样本
     host.eval("const o = {command\": \"ls\"};") → SyntaxError，断言尾部含 "JSON escape"
     与 "write " directly"。探针先坐实该样本产 SyntaxError: Unexpected token '\' (codemode.js:1:19)。
  b. codemode plain syntax error without an escape leak gets no escape hint：
     const o = { a: , }; → SyntaxError 无转义 → 断言不含 "JSON escape"（不误报）。
  c. codemode legal escaped string literal compiles without an escape hint：
     text("a\"b") 合法编译 → result.text="a"b"，lastExceptionMessage()==null（扫描 never runs）。
  实测红：zig build test EXIT=1，10032/10037（2 failed：escape-leak 测试无提示 + 无关
  command_runner 超时 flake）。b/c 负例 trivially 绿（钉死不误报边界）。证据 red-evidence.txt。
- 绿：current_script + escape_leak 扫描 + escape_hint 追加。3 测试全绿。
  （绿 commit 顺手修正红测试 a 的 write-directly pin 措辞与 c 的 var result/期望串，
  使其与实现提示精确对齐；红失败原因仍是缺提示。）

## e2e（既有已分类文件，不新建 root e2e）

- codemode-admission.test.ts「codemode script mistake feedback」describe 增
  "a JSON escape leak in the script names the fix"：fake gateway 脚本
  const o = {command\": \"ls\"};（一次解码后残留 backslash-quote）→ fx ask --json --yolo，
  断言 error-text 含 SyntaxError: + JSON escape + write " directly。
- 自跑：单条 913ms 绿；codemode-admission.test.ts 全套 29 pass / 0 fail。

## 验收证据

1. 红先于绿（2358ea1a2 → 绿）；zig build test 全绿：独立 --cache-dir /tmp/t31b-cache 全量重跑，
   22/22 steps succeeded，10029/10031 passed（2 skipped，0 failed）。含修复的测试二进制直接复跑
   3 条 escape 测试 OK（10029 pass/2 skip/0 fail）。首轮绿曾遇 1 例无关 command_runner flake，
   复跑即绿（已注明）。
2. zig fmt --check src/ 退 0；check-public-surface.sh 与 agents/compactor/indexer/recovery 四边界各退 0。
3. 三条单测（命中/不误报/合法转义）+ e2e 提示断言绿。
4. FX_BENCH=1 ./zig-out/bin/fx help 退 0、stderr 0 字节。
5. 产物：红/绿 commit + 本报告 + red-evidence.txt。

## 红线自查

- 零执行语义变更：host.zig diff 仅 current_script 字段 + eval 赋值 + annotation 参数 + 转义扫描/提示；
  编译/执行/预算逻辑零触碰。B 档 unescape 未做。
- bridge.zig 参数校验零触碰（ISSUE-32 下一张票）；描述字符串零触碰（builtins/tools.zig 不在 diff，ISSUE-34 fx-pi1）。
- admission/permissions/catalog/tests/tla 零触碰；无新 settings/CLI/env。
- 个人路径零入码（diff grep 退出 1）；提示纯 ASCII 无 emoji 无 -- 破折号。zig fmt 后提交。
