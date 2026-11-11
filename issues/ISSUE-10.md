# ISSUE-10 — codemode 脚本级 @options 预算

- **状态**: open
- **发现时间**: 2026-11-10
- **来源**: fx codemode 与 pi 1.5.1 源码对比
- **工作量**: 小

## 现象

超时固定 30s（src/tools/codemode/host.zig:18 default_timeout_ms），text/console
各 64KiB 硬截断（ISSUE-8 闭环项）。编译类脚本无法放宽预算，简单脚本无法收紧，
模型只能接受统一配置。

pi 解析脚本首行注释声明预算：// @options: {"timeout_ms": 60000,
"max_output_tokens": 10000}（tool.js 经 parseCodemodeSource）。

## 修法

decode 解析脚本首行 @options，call() 把生效超时传入 Sandbox Options，输出帽同步
生效，上限仍受宿主硬帽约束。ambient 预算（codemode_tool.zig:61 与 bridge.zig 的
applyAmbientBudget）改用生效超时。工具描述与 README 同步。

## 处置

- [ ] decode 解析并校验 @options 首行
- [ ] 生效超时贯通 Sandbox Options 与 ambient 预算
- [ ] 输出预算生效且不超过宿主硬帽
- [ ] 单测，工具描述与 README 更新
