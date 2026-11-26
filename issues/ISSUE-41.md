# ISSUE-41 — 超时提示推荐 shell interact 轮询，但嵌套 run_command 只收 action=run，指引一条被堵死的路

- **状态**: open（待立项）
- **发现时间**: 2026-11-26
- **来源**: 全量 169 个 session 日志分析（该提示出现 32 次 / 17 个 session；随后嵌套 interact 被拒 15 次 / 9 个 session，最新 2026-11-26）
- **关联模块**: src/tools/codemode/codemode_tool.zig:482,497,509（超时文案）、src/tools/codemode/bridge.zig:671（canonicalRunCommand 拒绝非 run action）

## 现象

codemode 超时报错文案：

```
for a wait or a long command, end the script and poll in a later call
(shell interact on the running session) instead of sleeping in a loop
```

模型照做，在下一个 codemode 脚本里写 `tools.call("run_command", {action:"interact", session_id:"shell-N", ...})`，得到：

```
InvalidToolArguments: run_command field "action" must be "run"; received "interact"
```

两条路都堵死后模型只剩 sleep 轮询（烧预算，见 ISSUE-42）或 perl setsid 脱管 + 文件落盘（复杂且易丢进程）。ISSUE-33 修过 "@options 上限与提示自相矛盾"，这是同族问题的新实例：**提示推荐的能力在嵌套面不存在**。

歧义点：文案说 "in a later call" 可以解读为"下一轮顶层 shell 工具调用"（interact 在顶层合法），但模型高频解读为"下一个 codemode 脚本"，17 个 session 的复发率说明文案不足以消歧。

## 修法

1. **A 改文案**（最小）：明确 "end this script; in the NEXT turn call the shell tool with action=interact (not available inside codemode)"。一行改动 + 文案钉死测试同步（codemode_tool.zig:576 一带）。
2. **B 放开只读 interact**：嵌套面允许 action=interact 且 chars 为空（纯读屏），写入仍拒。收益是脚本内可轮询，但扩嵌套权限面，需要评审。

倾向 A 先行；B 与 ISSUE-42 的等待语义一起评审。

## 处置

- [ ] 决策 A/B（倾向 A）
- [ ] 文案改动 + 钉死测试更新
- [ ] 观察指标：下轮 session 分析嵌套 interact 被拒次数是否归零

## 性价比排名（2026-11-26）

第 2 / 6。15 次被拒 / 9 个 session；A 方案一行文案 + 钉死测试，零风险。仅次于 ISSUE-40。
