# ISSUE-14 — codemode 工具面从硬编码改为可配置

- **状态**: open
- **发现时间**: 2026-11-10
- **来源**: fx codemode 与 pi 1.5.1 源码对比
- **工作量**: 中
- **关联**: ISSUE-15 依赖本项

## 现象

src/tools/codemode/bindings.zig:23 写死四个工具（glob_files、grep_files、
read_file、run_command），扩面要改代码发布。

pi 的对应行为：可调用面动态来自 active direct 与 codemode/deferred 工具
（getCodemodeCallableTools），MCP 工具可达，无需改包。

## 修法

白名单来源改为 profile 设置，或按 registry 类别推导。设置形态过 fx-cli-shape
技能评审后再定名。准入不放松：每个嵌套调用仍逐次走 bridge.zig 准入，新工具面
只扩大「脚本可点名谁」，不扩大「谁免审」。

## 处置

- [ ] 与 fx-cli-shape 技能核对设置形态与命名
- [ ] 白名单来源改为配置或 registry 推导
- [ ] 嵌套准入覆盖新工具面
- [ ] 单测：关闭 gate 时工具面与现状一致
