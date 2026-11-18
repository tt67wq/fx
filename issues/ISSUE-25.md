# ISSUE-25 — codemode 常见误用失败应有针对性提示：顶层 return、沙箱全局缺失、未知工具名

- **状态**: open
- **发现时间**: 2026-11-18
- **来源**: 近 30 天 session 记录分析（~/.fx/sessions/v2/，278 次 codemode 失败中约 80 次属此类）
- **工作量**: 小
- **关联**: ISSUE-20（沙箱原语）、ISSUE-21（通知文案先例）

## 现象

QuickJS 沙箱与模型书写习惯之间的错配产生一批可预测、可提示的失败，报错都是原生引擎文案，模型常在同一 session 内重复踩坑：

| 误用 | 次数 | 现状报错 |
|---|---|---|
| script 顶层写 return | 17 | `SyntaxError: return not in a function` |
| 使用 require / setTimeout / image 等 Node 或宿主全局 | 10 | `ReferenceError: xxx is not defined` |
| 调用不存在的工具名（read_tool_result、list、tools.list） | 13 | `TypeError: unknown codemode tool: xxx` |
| 自建 tools.read_file(...) 假设工具是直接方法 | 7 | `TypeError: not a function` |
| 参数缺 script 字段 | 12 | `codemode requires string field "script"` |
| @options 越界（timeout_ms、max_output_tokens） | 少量 | 报范围但不回显实际传入值 |
| 其余 SyntaxError（截断 script、模板串错） | 23 | 原生文案，无位置上下文 |

## 修法方向（只改提示与报错，不改执行语义）

- [ ] 顶层 return：预扫描识别后给出定向提示（"顶层不允许 return，用 text() 或最后一个表达式作为返回值"），或评估自动包一层 async wrapper 的可行性
- [ ] ReferenceError：报错附一行说明 QuickJS 沙箱无 Node API，tools.call 是工具调用入口；评估提供最小 setTimeout（轮询场景的自然需求，需与权限和超时模型对齐）
- [ ] unknown tool：报错列出可用工具名或给出最接近的模糊匹配建议（对齐 ISSUE-15 目录机制）
- [ ] 缺 script 字段：报错回显实际收到的顶层键名
- [ ] @options 越界：回显实际传入值
- [ ] SyntaxError：尽量附带行号或出错片段

## 处置

- [ ] 各类提示文案定稿（fx-cli-shape 复核）
- [ ] TDD：红测试（每类误用一条断言）
- [ ] 观测：修复后同型失败率下降