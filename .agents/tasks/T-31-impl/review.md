# T-31-review 评审报告 — read_tool_result 描述增强与压缩后找回全链

- 评审者：fx-pi2（未参与实现，作者独立）。
- 评审对象：fx-pi1 分支 T-31-impl，绿 **f1d8e72d3**（红 02c4a912d，产物 e9d8609df），基线 integrate-issue29@7275e8a08。
- 契约：.agents/tasks/T-31-impl/task.md；报告/红证据：同目录。
- 评审方式：描述逐句对实现锚点 + 双平台哈希独立复算 + 全链测试真实性核 + 自跑机械核验。

## Verdict: **approve**

描述每句为实现真（T/M/L 句柄词汇与 search 跨度逐句核过），词数持平 42/字节 +9/长度钉 <=250 成立，
darwin/linux 双 sha256 独立复算一致（linux 值经临时强制 setsid detach_command 实测，还原干净），
全链测试真跑真实 read_tool_result（dispatchAuthorizedToolCall + 会话 store）四支各钉哨兵，
红绿链真实，零执行语义变更，红线全守，机械核验全绿。

## 一、描述准确性（逐句对实现）✔
新文案：「Read a truncated tool result by handle: query finds lines with text, or start_byte and
byte_count a range. After compaction, T12 opens saved tool call 12, M12 turn 12, L1 a whole earlier
compaction; search needs no handle, spanning all saved records.」
- T12 = saved tool call 12 ✔：records.zig parseId 'T'→.tool（:120），Kind.letter 'T'（:66），
  records.zig:80 注释「T12 is tool call 12」；save 写 compacted-T12.txt。
- M12 = turn 12 ✔：parseId 'M'→.turn（:121），records.zig:80「M12 is turn 12」。
- L1 = a whole earlier compaction ✔：parseId 'L'→.ledger（:122），Kind 注释「An earlier compaction,
  saved whole when the next one folds it」（:59），records.zig:80「L2 is the second compaction, saved…」；
  L1 即首份早期整份压缩。
- search needs no handle ✔：read_tool_result.zig:50-54 search 与 handle 互斥（带 handle 报错指向 query）；
  decodeSearch 无需 handle。
- spanning all saved records ✔：compactor.search（records.zig:247）遍历 store.list 全部记录
  （parseFileName 含 T/M/L + isEarlierArchive result-source-* 档案），纯词匹配+BM25，跨 turns/tool calls/早期压缩。
- query/start_byte/byte_count 语义沿自旧描述，实现未动。
- 词数 42→42 持平（T-29 C4 精神）；字节 241→250（+9，M/T/L 词汇信息增量）；长度钉 <=250 恰好成立；
  纯 ASCII、无 emoji、无 -- 破折号。model-facing description cap 1024（model_tool_schema:4），250 远低。

## 二、byte-exact 哈希重钉（独立复算）✔
- 哈希源：all 工具 description+model_schema.description+gateway schema JSON + advertisement_order +
  shellProcessOnlySpec（含平台相关 detach_command：darwin perl -MPOSIX…/linux setsid…）。描述字节变 → 哈希必变。
- darwin 861c380f…：本机原生跑 byte-exact 测试 OK（自跑确认）。
- linux df9fe455…：评审独立复算——临时把 detach_command 强制为 setsid 变体、darwin 期望值置占位符，
  跑 byte-exact 测试，actual hex = df9fe4554238bd3a9aa0344da6d79372fb6ffd878d23a0a40cd0a1b452d0b4c8，
  与钉死 linux 值逐字一致。方法可信。
- 还原干净：评审复算后还原 tools.zig，git diff f1d8e72d3 -- tools.zig = 0；实现者 diff 中 detach_command
  与基线逐字相同（无临时改动残留）。

## 三、全链测试真实性 ✔
- gateway_flow.zig:4027「compaction recovery reads saved tool call, turn and earlier compaction by
  handle and search」：Recovery.execute 调 tool_dispatch.dispatchAuthorizedToolCall(builtin_tools.registry,
  request.call)，ctx.session_child_capability=真实 SessionChildCapability（initLegacyRoute tmpDir）——
  真实 read_tool_result 解码+校验+执行，非 mock。
- 两次自动压缩确定性构造：early/middle 各 52KB 哨兵输出，context_window=(early_tokens+middle_tokens)*5/4
  收紧 → prompt1 三段 gateway 响应（两 summary + turn reply），expectBodyContains compacted_conversation；
  第一次 checkpoint 折成 L1（prompt4 读 L1 成功坐实 L1 存在）。
- 四支各断言早期哨兵进入下一请求体（expectBodyContains index 1）：
  prompt2 handle=T1 → EARLY-DETAIL-SENTINEL-7421 ✔；
  prompt3 search=[哨兵] 无 handle → 哨兵 + saved_search ✔；
  prompt4 handle=L1 → 哨兵 ✔；
  prompt5 handle=M1 → 哨兵 ✔。
  哨兵入下一请求体隐含工具执行成功（Recovery.execute 映射 failure 状态，失败不会产出哨兵）。
- eval 边界声明诚实：gateway 脚本化恢复调用钉可达性+路径正确性，非模型自主决策（自主性属 tests/evals 需 API key，本轮不建）。报告如实注明。

## 四、红绿链 ✔
- 红 02c4a912d 仅 tools.zig metadata 测试改钉（描述仍旧句「Read more of a truncated tool result by its handle」，
  新关键短语断言 + 长度 <=250）。红证据：zig build test 10030/10033，1 failed
  （built-in read_tool_result owns product metadata schema and callbacks）。先于绿（merge-base 确认）。
- 全链测试在绿 commit 加入；红证据注明其在基线即绿（可达性已成立，钉路径正确性非新行为）——诚实。
- 负例：description 不含 "request."（旧钉保留）；长度钉 <=250 新增（原无长度钉）。

## 五、零语义变更 ✔
- read_tool_result.zig diff 0 行（实现逻辑零触碰）；系统提示文件未动（prompt_context 不在 diff）。
- compactor 只经 front door：compactor.max_search_phrases/RecordFileBuffer/search 均 compactor.zig 公开导出
  （:73/74/85）；gateway_flow 未新增 compactor 内部 import。check-compactor-boundary 退 0。

## 六、机械核验（自跑，fx-pi1@e9d8609df）
1. zig build test 全绿：独立 --cache-dir /tmp/t31r-cache 全量重跑，22/22 steps succeeded，
   10283/10290 passed（7 skipped）；主二进制直接复跑 10026 pass/2 skip/0 fail，
   byte-exact / metadata / 全链恢复三测试 OK。
2. zig fmt --check src/ 退 0。
3. check-public-surface.sh 与 agents/compactor/indexer/recovery 四边界各退 0。
4. FX_BENCH=1 ./zig-out/bin/fx help 退 0、stderr 0 字节。

## 七、红线 ✔
- 无新 settings/CLI/env（diff grep 退出 1）；recovery/tests/tla/admission/permissions/catalog 零触碰
  （diff name-only 仅 tools.zig + gateway_flow.zig）。
- 未新建 root e2e 文件（新测试在既有 gateway_flow.zig / tools.zig 测试块）。
- 无 emoji、无 -- 破折号、纯 ASCII；无个人路径（diff grep 退出 1，测试用隔离 tmpDir）。
- zig fmt 后提交。

## 八、结论
approve。描述逐句为实现真，双平台哈希独立复算一致且还原干净，全链测试真跑真实工具四支钉哨兵，
红绿真实，零语义变更，红线全守，机械核验全绿。无阻塞发现。
