# ISSUE-32 — 嵌套工具字符串参数自动包装为对象

- **状态**: closed（2026-11-21）
- **发现时间**: 2026-11-20
- **来源**: 近 40 个 session 记录分析（~/.fx/sessions/v2/，11-19 之后仍有 2 次，且本会话分析过程中模型再次实犯一次）
- **关联模块**: src/tools/codemode/bridge.zig（参数校验点 bridge.zig:432、592 一带）

## 现象

模型在 script 里调 `tools.call("run_command", "ls -la")` 或 `tools.run_command("ls")`，
传字符串而非对象，直接 `InvalidToolArguments: run_command arguments must be a JSON object`。

ISSUE-24 已让报错指明字段/形态，但报错是事后补救：模型看到报错后重试仍是浪费一轮。
模型从写 script 起就打算传一个"命令字符串"，形态天然不匹配 schema。

## 修法

bridge.zig 参数校验处对单字符串参数做 coercion，按工具的主参数名包装：

- `run_command` / `run_script`：`"cmd"` → `{command: "cmd"}`
- `read_file` / `write_file` / `edit_file` / `glob_files`：`"path"` / `"pattern"` → `{path|pattern: s}`
- 多参数工具或字符串无法对应主参数时维持现有报错

风险：coercion 会掩盖模型对 schema 的理解偏差，工具面受 ISSUE-15 目录预算约束，
主参数名要从工具 schema 读，不能硬编码第二份映射。

## 处置

- [x] bridge.zig 校验层 coercion（主参数名取自 schema）
- [x] 无法 coerce 时保留并沿用 ISSUE-24 的字段级报错
- [x] Zig 单测：字符串/对象/非法值三态

## 关闭备注（2026-11-21）

T-32-impl 红 15fbf58c7 → 绿 1e0776143，review approve 87d0ab5ea。bridge.zig canonicalNestedCall 裸字符串按 schema 单一 required string 主参数包装（无第二份硬编码映射）；run_command 走 canonicalRunCommand 同一管线，admission payload 与对象调用逐字相同，权限链无绕过。多 required 工具保留 ISSUE-24 报错；对象字节级透传有指针相等单测。良性观察：vision/web_fetch 实际会被 coerce（评审探针实测无害）。 整合于 integrate-issue29（HEAD deb980a36），PR tt67wq/fx#6。
