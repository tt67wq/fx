# ISSUE-42 — 等人/等权限的时间计入 codemode 脚本预算：交互完成后脚本仍被判超时，答案白给

- **状态**: open（待立项）
- **发现时间**: 2026-11-26
- **来源**: 全量 169 个 session 日志分析（11-19 后超预算 1.5 倍以上的失败 12 次：ask_user_question 等待 7 次、权限等待 5 次）
- **关联模块**: src/tools/codemode/host.zig:271（deadline 固定墙钟）、src/tools/codemode/host.zig:693（interruptHandler）、src/tools/codemode/bridge.zig:59（applyAmbientBudget 注释声称 permission wait 不吃命令预算，但脚本 deadline 本身照走）

## 现象

deadline_ms 在 eval 开始时一次性定死（now + timeout_ms），之后任何阻塞等待都计入：

| 样本 | 预算 | 实际 | 阻塞点 |
|---|---|---|---|
| ask_user_question ok, 369118ms | 120000 | 369121 | 用户 6 分钟后回答，答案已返回，脚本仍判 Timeout |
| ask_user_question ok, 275864ms | 120000 | 275867 | 同上 |
| run_command denied, 60011ms | 30000 | 60012 | 权限 review_unavailable 等待 60 秒 |

后果链：嵌套调用**已成功完成**（用户答了 / 权限判了），但 drain 循环发现已过 deadline，整个脚本报 Timeout，text() 没跑、store 写入丢弃、模型只看到 "Last nested output before failure (ask_user_question, ok, ...)"。用户的回答实际上被扔掉，模型往往重新问一遍。

bridge.zig:59 的 applyAmbientBudget 已经把权限等待从**命令**预算里摘出来（采样在 admission 之前），说明"人等的时间不该算机器账"的原则已被接受，只是没贯彻到**脚本** deadline。

## 修法

方向（涉及 deadline 语义，需要评审）：

1. **A 等待暂停计时**：嵌套调用进入"等人"阶段（ask_user_question、权限 prompt/review）时记录起点，返回后把等待时长加回 deadline_ms 与 ambient_started_ms。QuickJS interrupt handler 读的是同一字段，无需改中断逻辑。
2. **B 完成后宽限**：drain 发现超时时，若最后一个嵌套调用刚成功返回（如 <1s），允许脚本继续跑到下一个检查点。实现小但语义含糊，治标。

倾向 A。需要同步考虑：grace_deadline_ms（ISSUE-33 引入）与本改动的叠加顺序；取消（Esc）路径不受影响。

## 处置

- [ ] 方案评审（A/B，倾向 A）
- [ ] 落地 + 单测：模拟慢 ask_user_question 后脚本仍能 text() 收尾（红→绿）
- [ ] tests/tla 若有 recovery 相关模型需核对是否覆盖此语义
- [ ] 观察指标：下轮 session 分析 "overshoot: user-wait/permission-wait" 是否归零

## 性价比排名（2026-11-26）

第 6 / 6。12 次 / 约 8 个 session，频率最低但单次伤害最重（用户答案被扔）。deadline 语义评审 + TLA 核对成本高，单独排期，不建议砍掉。
