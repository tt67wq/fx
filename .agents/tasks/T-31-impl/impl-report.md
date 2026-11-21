# T-31-impl 实现报告 — ISSUE-27 P1 描述文案 + 压缩后找回全链

- 分支：T-31-impl（基线 integrate-issue29 HEAD 7275e8a08）
- 红 commit：02c4a912d（描述钉死先改，实测红）；绿 commit：描述+全链测试+哈希重钉
- 零执行语义变更：只动描述字符串、钉死测试、新增测试；read_tool_result.zig 实现逻辑未动。

## 一、描述文案增强（builtins/tools.zig read_tool_result_description）

- 改前：「Read more of a truncated tool result by its handle: pass query to find lines
  containing some text, or start_byte and byte_count for a byte range. To find earlier
  turns and tool calls after context compaction, pass search instead of a handle.」
  （241 字节 / 42 词；未解释 M/T/L 句柄词汇）
- 改后：「Read a truncated tool result by handle: query finds lines with text, or
  start_byte and byte_count a range. After compaction, T12 opens saved tool call 12,
  M12 turn 12, L1 a whole earlier compaction; search needs no handle, spanning all
  saved records.」（250 字节 / 42 词）
- 净字数零增长（42→42，T-29 C4 精神）；字节 +9（M/T/L 词汇本身的信息增量，合理）。
  无 emoji、无 -- 破折号、纯 ASCII。
- 长度钉：现描述原无长度钉，本轮新增 <=250 上限钉并在测试注释注明（250 = T-31 词汇
  版长度，词数持平 42）。

## 二、红绿（TDD）

- 红（02c4a912d）：metadata 测试改钉新关键短语（T12 opens saved tool call 12 / M12
  turn 12 / L1 a whole earlier compaction / search needs no handle / spanning all
  saved records）+ 长度 <=250。zig build test 实测红：
  'builtins.tools.test.built-in read_tool_result owns product metadata schema and
  callbacks' failed（10030/10033，1 failed）。证据 red-evidence.txt。
- 绿：描述改为新文案。连带重钉「built-in model-facing tool contract stays byte exact」
  的 sha256（描述字节变了，哈希必然变；darwin 861c380f…，linux df9fe455…，linux 值
  经临时强制 linux detach_command 实测后还原，方法注明）。zig build test 全绿
  TEST_EXIT=0。

## 三、压缩后找回全链测试（gateway_flow.zig，确定性 fake gateway）

新增 test「compaction recovery reads saved tool call, turn and earlier compaction by
handle and search」：真实 tool_call+tool_result 历史（早/中两轮，各含哨兵），context_window
收紧触发两次自动压缩（早→中，第一次 checkpoint 折成 L1）。随后 5 个 prompt 经
execute_delegate 跑**真实** read_tool_result（dispatchAuthorizedToolCall + 会话 store）：
- prompt2 handle=T1 → 返回含 EARLY-DETAIL-SENTINEL-7421 ✔
- prompt3 search=[哨兵]（无 handle）→ saved_search 输出含哨兵 ✔
- prompt4 handle=L1（整份早期压缩）→ 含哨兵 ✔
- prompt5 handle=M1（保存的 turn）→ 含哨兵 ✔
每支断言工具执行成功（status success）且下一请求体含早期细节哨兵。

**eval 边界声明**：模型自主性（模型自己决定去 read_tool_result）属 eval 领域
（tests/evals，需 API key），本轮不建。本全链测试钉的是**可达性 + 路径正确性**
（gateway 脚本化恢复调用，真实工具执行），非模型自主决策。

## 四、核查项落报告

1. 默认面可达性：已成立。read_tool_result 在 builtins/tools.zig all/registry 16 工具内
   （executor_kind .read_tool_result，:738 .call=read_tool_result_impl.call），无需新增面。
2. search/handle 互斥与词组上限既有测试覆盖：
   - 互斥：read_tool_result.zig:303「refuses search with a handle and points to query」。
   - 词组上限：:621 测试尾部对 [a,b,c,d]（4>max_search_phrases=3）、[]、[" "] 均断言
     decode failure（:670-678）。覆盖充分，无需新增。
3. L 记录读取路径（handle=L1）全链：被新测试 prompt4 覆盖（真实工具读 L1 含哨兵）。
   既有 :621 单元测试覆盖 T12/M3 的 handle+query+search，但未覆盖 L 与压缩后 orchestrator
   全链；新测试补齐 L 支与端到端路径。
4. 系统提示：本轮未动（token 成本）。核查未发现真实缺口——压缩摘要走消息流
   （prompt_context.zig:284 钉死「compacted session context out of instructions」），
   M/T/L 语义现由工具描述承载，checkpoint 文本与描述一致，无需补系统提示。

## 五、验收证据

1. 红 02c4a912d 先于绿；zig build test 全绿 TEST_EXIT=0。
2. zig fmt --check src/ 退 0；check-public-surface.sh 退 0；agents/compactor/indexer/
   recovery 四边界脚本各退 0。
3. 全链测试绿：handle T1 / search / L1 / M1 四支各自断言早期细节哨兵（见三）。
4. FX_BENCH=1 ./zig-out/bin/fx help 退 0、stderr 0 字节。
5. 产物：红/绿 commit + impl-report.md + red-evidence.txt。

## 六、红线自查

- 零执行语义变更：read_tool_result.zig 实现逻辑零触碰；只动描述字符串、钉死测试、新增测试。
- compactor 边界：只经 front door（compactor.recordFile/RecordFileBuffer/max_search_phrases
  公开 API）；check-compactor-boundary 退 0。系统提示未动。
- recovery/tests/tla/admission/permissions/catalog 零触碰；无新 settings/CLI/env。
- 新测试放既有 gateway_flow.zig / tools.zig 测试块；未新建 root e2e 文件。
- 个人路径零入码（隔离 tmpDir）；无 emoji；文案无 -- 破折号。zig fmt 后提交。
