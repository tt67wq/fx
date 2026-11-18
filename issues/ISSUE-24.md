# ISSUE-24 — codemode 嵌套工具参数错误不指明字段，部分失败丢失错误正文

- **状态**: open
- **发现时间**: 2026-11-18
- **来源**: 近 30 天 session 记录分析（~/.fx/sessions/v2/）
- **工作量**: 小
- **关联**: ISSUE-15（目录预算）、ISSUE-21（F5 通知文案先例）

## 现象

两类错误信息质量问题：

1. **嵌套工具参数校验报错不指明错在哪个字段。** 36 次 `codemode tool run_command failed: InvalidToolArguments` 全部是同一个键名错：script 里写了 `cmd` 或 `argv`，契约要求 `command`。模型收到的报错没有任何字段提示，只能靠猜重试，同类错误跨 session 反复出现。同期 398 次成功调用用的都是 `command`，说明契约本身清晰，缺的是反馈。
2. **部分失败丢失错误正文。** 约 7 条失败 preview 只剩裸的 `codemode script failed: ScriptError`，message 为空，模型失去自愈依据。

## 修法方向

- [ ] 嵌套工具参数校验失败时，错误信息列出未知字段名与期望字段名（对齐 Zig 侧既有 JSON 解析报错形态）
- [ ] 排查 ScriptError 正文丢失路径：错误 message 为空时至少回传错误类型与发生阶段（编译/执行/嵌套调用）
- [ ] 补测试：cmd 误用应报出 "未知字段 cmd，应为 command" 一类明确提示

## 处置

- [ ] 错误信息形态定稿（含 fx-cli-shape 复核：这是模型可见反馈，非新控制面）
- [ ] TDD：红测试（误用键名报错内容、空 message 兜底）
- [ ] 验证：同类误用在一轮内自愈，不再跨轮重复