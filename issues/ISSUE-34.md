# ISSUE-34 — 已知误用（猜工具名/require/裸调函数）在报错提示落地后仍复发，需前置到 codemode 描述

- **状态**: open
- **发现时间**: 2026-11-20
- **来源**: 近 40 个 session 记录分析（~/.fx/sessions/v2/，11-19 之后本类 9 次失败）
- **关联模块**: src/builtins/tools.zig（codemode_description，743 行一带，长度受 1168 字符测试约束）、src/tools/codemode/discovery.zig

## 现象

ISSUE-25 的报错侧提示（did you mean + searchTools 指引、沙箱 ReferenceError 尾巴）已合入，
但模型不先踩坑就不会看到提示，同类失败 11-19 之后仍出现 9 次：

| 次数 | 失败 | 现有提示 |
|---|---|---|
| 4 | unknown codemode tool: run_file / tavily-search / tools.list / read_tool_result | did you mean（事后） |
| 3 | could not load module 'fs' / 'node:fs' | ReferenceError 尾巴（事后） |
| 2 | run_command is not defined / 变量未定义 | ReferenceError 尾巴（事后） |

## 修法

把"常见坑"从报错时前置到 codemode 工具描述（模型写 script 前必读）：

1. 工具名先 searchTools("关键词") 确认，不要凭记忆拼。
2. 没有 Node.js API：不能 import/require fs、process；没有顶层工具函数，一律 tools.call("name", {args})。
3. 参数是对象：tools.call("run_command", {command: "..."})。

描述有 1168 字符硬预算（src/builtins/tools.zig:756 测试钉死），放不下就：
- 压缩现有描述腾额度；或
- 走 ISSUE-15 已落地的目录预算机制，把"常见坑"挂为 describeTool 的补充块，描述里只留一句指引。

## 处置

- [ ] codemode_description 前置常见坑三则（或 describeTool 补充块方案）
- [ ] 字符预算测试同步更新
- [ ] 观察指标：下轮 session 分析中本类失败次数是否归零
