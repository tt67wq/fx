# ISSUE-23 — codemode script 超时占失败一半：无耗时回显、无部分输出、提示缺失

- **状态**: open
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

- [ ] Timeout 错误信息补齐：实际耗时、生效的上限值与来源（默认值还是 @options）、@options 调整方法
- [ ] 超时回传嵌套命令已产生的部分输出（有帽，标注截断），而不是只列调用状态
- [ ] 复核默认 timeout_ms 对"一条长命令"场景是否偏短，或按嵌套命令预算单独收口
- [ ] 评估轮询等待场景的引导：文档或错误提示建议拆短命令/分次轮询而非单条 sleep 循环

## 处置

- [ ] 设计定稿（超时错误形态 + 部分输出帽 + 与 recovery 模型边界确认）
- [ ] TDD：红测试（超时信息字段、部分输出保留、@options 生效）
- [ ] 文档：codemode 页补超时与 @options 用法