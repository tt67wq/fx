# ISSUE-26 — README 与手册的功能描述落后于实现（codemode 线五轮合并未同步文档）

- **状态**: open
- **发现时间**: 2026-11-18
- **来源**: 用户指出"项目功能和 readme 文档功能差距已经不小了"；逐条核对 README.md codemode 节
- **工作量**: 中
- **关联**: ISSUE-11/12/14/15/20/21/23a（均已合入，文档未跟上）

## 现状

README.md 的 codemode 节（7-23 行）停在 ISSUE-14 之前的状态，多条陈述在实验门开启时已不成立：

1. **工具面列表过时**："whitelisted built-in tool: glob_files, grep_files, read_file, run_command. Everything else is invisible" —— 派生面开启时实际是九件套（+write_file/edit_file/web_fetch/ask_user_question/vision），且 run_command 经 registeredName 映射 shell；"Everything else is invisible" 在 gate 下为假。
2. **无 `experimental.codemode_derived_surface` 键**：派生面开关（profile-only，默认关）没有任何记载。
3. **无 run_script 原语**：ISSUE-20 落地的多语言执行原语（shell+python，CTX_FILE，argv 安全形态）缺失。
4. **无目录预算与发现接口**：ISSUE-15 的 `context_limits.codemode_catalog_bytes`（16KiB 默认、omitted/hint、T0/T1/T2 分层）、`searchTools`/`describeTool`（评分、did-you-mean、limit 语义）缺失。
5. **无输出超限语义**：ISSUE-12 的 1MiB 捕获帽、头尾保留 + omitted 标记、`read_tool_result` 回读；ISSUE-21/22 的 262_144 max_options_output_tokens、失败体 capture 标记。
6. **无超时反馈语义**：23a 的 Timeout headline（elapsed/budget/source/@options 提示）。
7. **store()/load() 缺失**（ISSUE-13 未做，README 若列工具面时需注意别把未实现写成已有）。

另有 builtins/tools.zig:743-744 一处代码注释与实现不符（23b 方案发现：预算封顶嵌套命令的说法），可随文档轮一并修正。

## 差距清单

- [ ] README codemode 节重写：派生面九件套 + gate 两态行为、run_script、目录预算与 searchTools/describeTool、输出帽与 read_tool_result、超时 headline
- [ ] `--help` 输出核对：experimental 组描述（settings_keys.zig:121）、--context-limit 键列表与实际一致
- [ ] 手册（fx.sh/docs，私有仓库）：codemode 页、权限页（T-17 的 dash 数据词 Docs 承诺）、MCP 页（T-18 遗留一句话）——能推私有仓库则配套 PR，否则按 CONTRIBUTING 在 PR 描述加 Docs 节
- [ ] builtins/tools.zig:743-744 注释修正（随文档轮）

## 处置

- [ ] 范围定稿（README vs --help vs 手册各自边界；AGENTS.md 红线：README 只在陈述为假时改）
- [ ] 文档轮 impl（纯文档+注释，零代码语义）
- [ ] 逐条核对清单（上面 7 项每项一个核对断言）
