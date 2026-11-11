# ISSUE-15 — codemode 工具目录预算与 searchTools 检索

- **状态**: open
- **发现时间**: 2026-11-10
- **来源**: fx codemode 与 pi 1.5.1 源码对比
- **工作量**: 中
- **关联**: 依赖 ISSUE-14

## 现象

tools.list() 全量注入每个工具的 schema JSON。四个工具没有成本问题；ISSUE-14 扩面
后（尤其含 MCP 工具时）成本随工具数线性增长，且 schema 由 bridge.schemas 每次
codemode 调用在 arena 里重建（codemode_tool.zig:68-72）。

pi 的对应行为：inlineBudget（默认 3000 token）按 cost 轮转展示工具目录
（tool.js 的 selectCatalog），脚本内 searchTools（BM25 排序）与 describeTool 补齐
未列出的工具（execute.js 的 createDiscoveryGlobals）。

## 修法

工具数超过阈值才启用预算选择与 searchTools，低于阈值维持全量注入，避免为小工具面
引入检索复杂度。预算与阈值来源随 ISSUE-14 的设置形态一并评审。

## 处置

- [ ] 超阈值启用目录预算选择
- [ ] 沙箱注入 searchTools 与 describeTool
- [ ] 低于阈值维持全量注入
- [ ] 单测：预算下每个 namespace 至少一个代表
