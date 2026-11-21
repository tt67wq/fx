# ISSUE-35 — codemode run_script 的 python3 解释器硬编码，需可配置（待立项）

- **状态**: closed（2026-11-21）
- **发现时间**: 2026-11-21
- **来源**: 用户反馈：codemode 跑 Python 用的是系统默认 /usr/bin/python3，希望能指定解释器（如 venv/conda）
- **关联模块**: src/tools/codemode/bridge.zig（canonicalRunScript）、src/core/config/、src/core/tooling/tool_runtime.zig

## 现象

run_script(language=python) 的命令由 bridge 固定生成：

- src/tools/codemode/bridge.zig:519-521 硬编码 `python3 <fx 临时脚本>` token；
- 命令交给 shell 工具 action=run，按该 shell 环境的 PATH 解析 python3，并非直接 exec /usr/bin/python3；
- 用户环境里 /usr/bin/python3 排 PATH 最前时，venv/conda 的解释器永远轮不到，装了第三方包的 Python 用不上。

今天已有的零代码缓解：调整 shell 环境 PATH，或让模型改用 run_command 显式写解释器路径。两者都不持久、不针对 codemode。

## 方案（按 fx-cli-shape 决策序）

推荐机制：持久 profile 设置 `experimental.codemode_python`。

| 项 | 选择 | 依据 |
|---|---|---|
| 机制 | setting，非 flag/env | 决策序第 5 条：应持久的偏好用 setting |
| 名字 | experimental.codemode_python | codemode 仍是实验特性；实验规则：只用 experimental.<name>，不加 flag 和 env |
| 作用域 | 仅 profile（~/.fx/settings.json），支持 workspaces 覆盖 | 解释器路径决定执行什么程序，绝不进 .fx.json（不可信仓库文件） |
| 单次覆盖 | fx ask --config experimental.codemode_python=/path | 现成 --config 通道，无需新 flag |
| 取值 | 绝对路径或 PATH 上的命令名，默认 python3 | 与现有行为兼容 |

备选（更小但不合规或更弱）：调 PATH（零代码，影响面大）；FX_CODEMODE_PYTHON（违反实验不加 env 的规则）；顶层稳定键 codemode_python（codemode 未毕业就多一个将来要废弃的名字）。

## 改动清单（约 8 个文件，仿 codemode_derived_surface 接线）

| 文件 | 改什么 |
|---|---|
| src/core/config/settings_keys.zig | Key 加 child_kinds 元数据 + codemode_python 子键（string） |
| src/core/config/settings_schema.zig | switches 分支按 child kind 输出 string/boolean |
| src/core/config/config_runtime.zig | Settings 字段、experimental 解析、mergeSettings、deinit（仿 review_model） |
| src/core/tooling/tool_runtime.zig | Context 加 codemode_python 字段 |
| src/main.zig、src/core/cli/cli_ask.zig | 读合并设置并缓存，注入 Context（各仿 codemodeDerivedSurface） |
| src/core/app/app_agent_runtime.zig | ctx 构造处透传 |
| src/tools/codemode/bridge.zig | RunScriptEnv 加 interpreter；519-521 行改用 quoteShellPath(env.interpreter) |
| tests/e2e/codemode-admission.test.ts | 新用例：自定义解释器后 stdout 来自它（文件已分类 verify，corpus 不动） |

## 风险与安全边界

- 权限链不变：命令仍走 shell 工具 admission 与 auto 审查。
- 解释器 token 来自用户配置而非模型文本，模型依旧无法注入 argv（bridge.zig:417 守卫保留）。
- 必须复用 quoteShellPath：含空格路径要正确单引号转义，否则破坏固定 argv 形状。
- 值校验：非空、无 NUL、不以 - 开头（防被当作选项）；允许命令名交给 PATH。
- python 不在 parity_review_free_commands 内，无 shell parity 义务。
- fx config set 不支持 experimental 键（files_only），用户直接编辑 settings.json，与 experimental.codemode 现状一致。

## 需要维护者确认

1. experimental 组目前是纯 switches（全 boolean），加 string 子键需要 child_kinds 形状扩展，是否接受。
2. 命名 codemode_python 是否符合预期（或等 codemode 毕业时一并定稳定键）。

## 文档义务

- settings schema 变更后同步 fx.sh 的 schemas/settings.json 副本；
- 手册页在私有仓库，PR 描述加 Docs 段说明受影响页面。

## 处置

- [x] 维护者立项并确认上面两点
- [x] 按改动清单实现 + Zig 单测（解析/merge/quoteShellPath 路径）
- [x] e2e：codemode-admission.test.ts 自定义解释器用例
- [x] 构建二进制实测 run_script 走自定义解释器（AGENTS.md 就绪门槛）

## 验证状态

可行性分析基于本地代码阅读（行号见上），未实际编译或运行改动；上一轮的试验性编辑已全部还原，git diff -- src/ 为空。

## 关闭备注（2026-11-21）

T-35-impl 红 8f3d4b2b6 → 绿 c8371df37，review APPROVE（fx-pi2 独立核验安全边界/作用域/8 文件接线/红绿/真机证据）。experimental.codemode_python profile-only（workspaces 覆盖），默认 python3 兼容现状；值校验非空/无 NUL/不以 - 开头；quoteShellPath 覆盖 plain 与 CTX_FILE 两种 argv 形状；模型无法注入 interpreter（normalization 拒绝未知字段，钉死测试）；权限链不变。.fx.json 项目层不解析（测试钉死）。真机空格路径解释器双哨兵 + 默认行为不变。已知限制：--config 单次覆盖不可用（experimental.* files_only 现状一致，用户编辑 settings.json）。绿期发现并修复 main.zig/cli_ask.zig 悬垂指针（dup before deinit）。Docs 跟进：fx.sh schemas/settings.json 副本与手册页需上游 PR 同步。已合并 main（cc54d166c），合并树全量测试绿，双远端已推。
