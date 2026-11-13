# ISSUE-11 — codemode 嵌套调用记录进工具结果

- **状态**: closed
- **发现时间**: 2026-11-10
- **来源**: fx codemode 与 pi 1.5.1 源码对比
- **工作量**: 中
- **关联**: 与 ISSUE-9 共用失败摘要呈现

## 现象

bridge.zig 已有 call_sequence 计数与 codemode-nested-{d} 调用 id，但模型可见结果
不含嵌套调用记录。脚本调了哪些工具、成败如何，模型无法审计。

pi 的对应行为：NestedCallRecorder（dist/core/nested-tool-calls.js）把每次嵌套调用
的名称、状态、耗时、错误预览记入结果的 nestedCalls 字段。限额：256 条、参数 8KiB
每条、总量 32KiB、错误 500 字符，超限标记 incomplete。

## 修法

CodemodeHostState 记录每次嵌套调用的摘要（名称、状态、耗时），成功与失败都附在
结果尾部，与 ISSUE-9 的失败摘要共用同一呈现。摘要体量控制在固定限额内，超限标记
不完整而不是静默截断。

## 处置

- [x] CodemodeHostState 记录嵌套调用摘要
- [x] 成功结果头部附摘要（评审 F1：尾部会被外部化藏掉）；失败结果尾部附摘要（ISSUE-9 已有，duration 并入）
- [x] 限额与 incomplete 标记（沿用 ISSUE-9 的 32 条 + overflow）
- [x] Zig 单测：多调用脚本的结果含完整摘要（含 outcome 映射、时钟钳制、OOM 降级、外部化可见性）
