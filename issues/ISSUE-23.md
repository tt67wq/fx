# ISSUE-23 — codemode script 超时占失败一半：无耗时回显、无部分输出、提示缺失

- **状态**: closed（2026-11-19）
- **发现时间**: 2026-11-18
- **来源**: 近 30 天 session 记录分析（~/.fx/sessions/v2/，2380 次工具调用，278 次 codemode 失败）
- **工作量**: 中
- **关联**: ISSUE-20（ctx_execute 原语，timeoutMs 语义）、ISSUE-21（预算通知文案先例）、ISSUE-15（目录预算）

## 现象

分析期内 codemode 失败 278 次，其中 Timeout 143 次（约 51%），是最大失败类别。失败 script 的共同形态：

- 绝大多数（可恢复样本 126/148）是 script 内嵌套一条 run_command 跑长命令：服务启动轮询（for 循环 sleep 等端口就绪）、Swift/Vision 编译、npm install -g 等；
- 没有一个超时 script 使用 // @options 抬高 timeout_ms 预算（仅 4 次出现过 options 头且不在超时样本里）；
- 超时错误信息只有裸的 `codemode script failed: Timeout`，不回显已等待时长、不提示 @options 可调、不区分默认上限来源；
- 超时前嵌套命令已产生的部分 stdout/stderr 被丢弃，结果区只保留 "Nested tool calls before failure (not undone)" 状态列表（如 `run_command: ok (31496ms)`），模型无法据此判断卡在哪一步、该拆分还是该等待。

## 差距清单

- [x] Timeout 错误信息补齐：实际耗时、生效的上限值与来源（默认值还是 @options）、@options 调整方法（23a 已落，merge 289303f4c）
- [x] 超时回传嵌套命令已产生的部分输出（有帽，标注截断），而不是只列调用状态（23b 已落：1KiB 摘录槽 + 被杀快照覆盖矩阵）
- [ ] 复核默认 timeout_ms 对"一条长命令"场景是否偏短，或按嵌套命令预算单独收口（23b 数据判定不改默认与上下界，见 plan 问 2；发现 A 预算传递收口另票 ISSUE-28）
- [x] 评估轮询等待场景的引导：文档或错误提示建议拆短命令/分次轮询而非单条 sleep 循环（23b 数据判定走错误提示一行，并入 23a headline，max 120000 + poll 引导）

## 处置

- [ ] 设计定稿（超时错误形态 + 部分输出帽 + 与 recovery 模型边界确认）
- [ ] TDD：红测试（超时信息字段、部分输出保留、@options 生效）
- [ ] 文档：codemode 页补超时与 @options 用法

## Resolution — 23a（2026-11-18）

差距清单第 1 项落地（merge 289303f4c）：Timeout headline 为
`codemode script failed: Timeout after {elapsed}ms (budget {budget}ms, from default|@options); raise it with // @options: {"timeout_ms": N} on the first script line`
验证员真机探针两态实证（default 30002ms / @options 4000ms），ScriptError 控制组不变。非阻塞遗留：“first script line”实为首个非空行措辞、elapsed 比预算高 ~2ms（一次读数粒度）——均已记录不修。其余三项（部分输出保留、长命令预算收口、轮询引导）待 23b 方案轮。

## Resolution — 23b（2026-11-19）

差距清单第 2、4 项落地（T-23b-impl，head 见 .agents/tasks/T-23b-impl/impl-report.md）：
失败体新增 1KiB 摘录槽（最近一次已返回嵌套调用的 model_output 头尾，含被预算杀掉的
shell 快照 output_delta，标题逐字 Last nested output before failure）；Timeout headline
合并轮询引导一行（max 120000 + end the script and poll in a later call）。预算裁决：
默认 30s 与 @options 1000..120000 上下界、clampRunScriptTimeout 均不动（数据不支持改动，
见 plan 问 2）。真机探针三态坐实（逐字摘录 + 头尾哨兵 / 被杀快照 + 尾哨兵 / 发现 A 8077ms），
覆盖矩阵三行全有真机证据。发现 A/B 另开 ISSUE-28/ISSUE-29。


## Resolution — 23b（2026-11-19）

剩余三项全部落地（merge 见 git log）：① 失败体新增摘录节（最近一条已返回嵌套调用的 1KiB 头尾摘录 + 被预算杀掉的嵌套快照 output_delta，QuickJS deadline 只在指令间触发故在飞调用必记录）；② 预算裁决不改（数据在 plan.md）；③ 轮询引导并入 headline。验证员 approve-with-comments，真机探针全过。遗留发现开票：ISSUE-28（ambient 未减 remaining）、ISSUE-29（run_command 兼容后端超时结果无输出）。
