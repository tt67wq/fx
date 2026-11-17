# T-12-impl 实现报告

任务契约：.agents/tasks/T-12-impl/task-impl.md（conductor 侧）。方案：仓库根 plan.md。
工作树：分支 T-12-impl（基于 origin/main 的 e76c6707a）。

## 提交（红/绿分层）

| 提交 | 层 | 内容 |
| --- | --- | --- |
| 9b79b8bb2 | Red 1.1 | host.zig 捕获帽计数测试（阈值、两流独立、>1MiB、takePartialOutput 带计数） |
| c5176463e | Green 1.1 | host.zig：default_capture_buffer_bytes=1MiB、appendCapped 计数丢弃、Result/PartialOutput 增三字段、eval 复位；effectiveScriptOptions 引新常量 |
| 1a431c636 | Red 1.2 | result_store 五处 @splat 换 distinct 哨兵并断言头尾；新增 omitted 精确计数测试 |
| aef31150a | Green 1.2 | text_utils：omitted_bytes_marker_template、formatOmittedBytesMarker、writeHeadTailOmittedBounded；previewText 头尾各半；codemode shell 改引共享模板；gateway_flow 技能测试改用中段标记 |
| ef94737c4 | Red 1.3 | codemode_tool 失败路径头尾+共享标记、成功路径捕获帽标记测试 |
| a1e67d91f | Green 1.3 | appendFailureOutputHead 走 writeHeadTailOmittedBounded；appendSuccessOutput/formatSuccessBody/call() 串 dropped 计数 |
| 41d1247fd | 其他 | sandbox_tests.zig 沙箱端到端：200KiB text() 全量捕获 + 落盘 + 中段逐字节回读 |
| dbd8f9ffc | 其他 | tools.zig 描述两处 64KiB→1MiB 捕获帽并补回读句；tests/e2e/codemode-output.test.ts；corpus.json verify-codemode-output；ci-shard-weights.json weight 3 |
| （最后提交） | 收尾 | plan.md 个人路径改 /Users/example/；本报告 |

## 与 plan 的偏差

1. plan 第 4 节第 3 条只列了 result_store 五处 @splat 测试；实际还需更新同文件
   "inline cap and stored preview keep complete codepoints"（preview 长度断言
   preview_bytes - 1 改为 ≤ preview_bytes 加头尾断言）。
2. gateway_flow 的 "retains complete skill content" 测试原本断言普通结果不含
   COMPLETE_SKILL_TAIL；头尾预览使其出现在预览尾半，故引入 SKILL-MIDDLE-ONLY
   中段标记：普通结果不得含中段（预览裁掉中段），complete_skill 仍保留全量。
   该语义边界（普通结果不获 complete-skill 地位）保持不变。
3. plan 1.2 说 previewText 调 writeHeadTailBounded；实现为
   writeHeadTailOmittedBounded（text_utils 新增）：writeHeadTailBounded 的标记
   由调用方传入，而 plan 第 4 节第 4 条要求标记数字精确等于被省略字节数，
   该数字依赖保留切分与 UTF-8 边界收缩，故封装为变体，逐字节契约不变。
4. v2 blob 测试的 bytes[3]='
' 为 searchByQuery "2|xxx" 断言所依赖（行切分），
   哨兵因此放在 bytes[8..20] 与 len-20..len-8，保持行号与字节位置断言不变。

## 验收证据

1. zig fmt --check src/ 退 0。
2. 清缓存（rm -rf .zig-cache）zig build test 退 0，全绿（此前缓存内一次
   command_runner 取消测试无输出失败，与本任务无关，复跑通过，其余各次全绿）。
3. 新 e2e：codemode-output.test.ts 两例全过；codemode-admission.test.ts 14 例全过
   （一次运行出现 1 例超时假失败，重跑全绿，与本任务无关）；cli.test.ts 145 例中
   仅 1 例取消类超时假失败，单跑通过；ci-shards.test.ts 全过（corpus/shard 接线校验）。
4. 真实探针：./zig-out/bin/fx（本仓库 zig-out/bin/fx，31.8M，所有 src 改动后构建）
   经 e2e harness 驱动 fx ask：第一轮 300KiB text() 输出，结果含 CODEMODE-HEAD 哨兵、
   CODEMODE-TAIL 哨兵、"...[N bytes omitted]..."、<tool_result_handle> 与
   "Full result is stored outside session JSON. Use read_tool_result" 句子，
   且不含中段哨兵；第二轮 read_tool_result 按 start_byte=151014 读取，
   拿到逐字节相等的 MIDDLE 哨兵。大 return 值（不调 text()）同路径落盘可读。
   进程退 0，stderr 干净（测试断言 stderr 前 400 字符）。
5. check-public-surface.sh 退 0（plan.md 的真实个人路径已改 /Users/example/）；
   check-agents-boundary.sh、check-compactor-boundary.sh、check-indexer-boundary.sh、
   check-recovery-boundary.sh 各退 0。
6. 本报告与全部改动仅用相对路径或 /Users/example/ 路径。

## 红线自检

- 未触碰 src/core/permissions/、准入、src/mcp/、src/core/mcp*/、session schema、依赖。
- JS 契约只增不改：Result 增三字段；Options.output_buffer_bytes 字段名与语义不变；
  text()/console.log 返回值语义不变（阈值移动由 4.1 测试钉住）。
- 落盘仍走 execution_memory 既有路径（本任务未改该文件）；回读提示句仍在
  formatStoredResultOutput，未写进标记。
- 唯一越出 src/tools/codemode/ 的改动是 1.2（共享 session 层 result_store + text_utils
  + tools.zig 描述 + e2e/corpus 接线），均为已批准主方案。
