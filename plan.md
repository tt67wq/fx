# T-20 实现就绪方案 — codemode 多语言执行原语（ISSUE-20）

只读方案，不含实现。工作树基线 `origin/main @ ef1462f6b`，分支 `T-20-plan`。
结论先行：**复用现有 codemode bridge→shell 准入路径**，不新增权限面；
QuickJS 沙箱继续零 spawn，进程树与超时归 shell 运行时；新原语只进派生面。
每条精确到 `文件:行`。

## 锚点（现状）

- 脚本面调用链：JS `tools.call` → `bindings.Backend.call`（`src/tools/codemode/bindings.zig:44-55`，
  注入点，host 只转发 JSON）→ `bridge.call`（`src/tools/codemode/bridge.zig:52-172`）。
- `bridge.call` 已把每个嵌套调用送进完整准入：`tool_admission.requestPermissionOutcome`
  （`bridge.zig:112-117`）+ `tool_runtime.executeToolCallAuthorized`（`bridge.zig:120-131`）。
- 名字规范化：`canonicalNestedCall`（`bridge.zig:182-213`）把脚本名 `run_command` 拼成
  注册工具 `shell` 的 `action:"run"` 调用；这是新原语唯一需要扩展的接缝。
- 白名单只决定"脚本能否点名"：`sandboxFace`/`derivedFace`（`bridge.zig:377-391`），
  shipped 面 4 个名（`bindings.zig:24-29`），派生面 = registry `sandbox_reachable` + run_command。
- 嵌套 shell 超时已现成：`applyAmbientBudget`（`bridge.zig:46-51`）按脚本剩余墙钟封顶，
  停滞命令在预算点被杀；deadline 在 host（`host.zig:225-226`），进程生命周期归 `src/tools/shell/shell.zig`。
- 输出帽与头尾预览现成：`shell.encodeResultJson`（`src/tools/codemode/shell.zig:27-45`），
  脚本侧帽 1MiB（`shell.zig:7`）。
- 命令词形守卫现成：`command_effect.plan`（`src/core/shell_command/command_effect.zig:457`）
  → `planWithGit`（:491）tokenize argv、按管道段判 review/auto；免审命令清单
  `parity_review_free_commands`（:2421）。
- 目录分层：`catalog.tierOf`（`src/tools/codemode/catalog.zig:25-35`）T0=glob/grep/read/run_command 豁免，
  T1=write/edit，T2=其余；预算 16KiB（`src/core/config/context_limits.zig:32`），通知下限 1KiB（`catalog.zig:16`）。

## 问 1 — 权限映射（最重，裁决）

裁决选 (a)：转发到 shell 工具现有路径，不建 (b) 独立 host 准入面。理由：准入已在
`bridge.call`（`bridge.zig:112-131`）跑完，白名单从不决定谁跳过审查（红线），新面会造第二条
执行路径（违反 AGENTS.md「What Not To Do」）。落地：在 `canonicalNestedCall`（`bridge.zig:182-213`）
加分支，把 `run_script{language,code,...}` 规范化为 `shell action:"run"`，`command` 由 fx 拼出固定
argv；解释器 token 只从 `language` 枚举取，绝不信模型文本。
选项注入收口（python `-c`/`-m` 拼接）：code 由 fx 写入临时脚本文件（复用问 3 的 CTX_FILE 机制，host 写文件非起进程），fx 只发
`python3 <fx临时脚本路径>`；模型的任何带 `-` 前缀 token 一律拒。（修正 B1：原稿 stdin 形态不可实现，shell action:run 允许字段无 stdin，shell.zig:80-84；临时脚本文件与 stdin 安全等价：解释器 token 来自枚举、脚本路径 fx 写入，模型文本永远不进 argv。）shell 类语言直接把整条命令交给 shell `action:"run"`，
`command_effect.plan` 词形守卫照常生效。v1 进面语言：`shell` + `python`（node/ts 留 QuickJS 内，
其他运行时走派生面开关）；其余语言留待后续按同规则逐个白名单放行。

## 问 2 — fx-cli-shape 形状

冲突先讲（SKILL.md「Stop and ask」/「Core rules」）：pi 名 `ctx_execute` 破坏 fx 脚本面既有约定
（`run_command`/`read_file`/`glob_files`/`grep_files` 都是 `动词_名词` snake_case，`bindings.zig:24-29`）。
故不照抄 pi 名，合规形状用 **`run_script`**；若 conductor 坚持对齐 pi 属破例，需维护者批准，单列。
参数名一律 snake_case（JSON/设置面规则），不沿用 pi 的 camelCase：`language` / `code` / `file` /
`intent` / `timeout_ms`。`timeout_ms` 复用 host 既有区间 `1000..120000`（`host.zig:30-32`），不进顶层 flag/env。
输出字段沿用 `shell.encodeResultJson` 形态（`shell.zig:12-32`）：`exit_code` / `output` / `truncated`；
新增只增不改：索引回读用 handle 字段（配 `read_tool_result`，`builtins/tools.zig:171`）。
脚本面绑定名与注册工具名不同属既有约定（host.zig `toolsListCallback` 注释，:604-611），不视为 drift。

## 问 3 — 沙箱边界（spawn/kill/超时归属）

QuickJS host 不得起进程（沿用 `host.zig` 无 spawn 现状）。新原语继续经 `bindings.Backend`
注入回调（`bindings.zig:44-55`）；`codemode_tool.call` 已在 :311 `setToolBackend(bridge.backend(state))`。
签名不变：`call(ctx, allocator, tool, args_json)`。归属：**fx shell 运行时**（`src/tools/shell/shell.zig`）
拥有 spawn 与进程树 kill；超时复用 `applyAmbientBudget`（`bridge.zig:46-51`）+ host deadline
（`host.zig:225-226`），取消复用 `state.cancelled()`（`bridge.zig:156`）。
大文件注入 `CTX_FILE`：由 host/bridge 写临时文件（非进程，允许），把路径塞进 spawn 的
`env`，内容不进模型上下文；`file` 参数即被指向该路径。

## 问 4 — 目录预算

新原语只在派生面出现（门 `experimental.codemode_derived_surface`，`src/core/config/settings_keys.zig:121`），
不进 shipped 4 面，故对默认预算零压力。派生面开启时进 `tools.list()`：`tierOf` 应归 **T2**
（`catalog.zig:25-35`），不豁免——T0 语义是"今日既有行为不可丢"，新原语不属此类。
字节评估：schema 含 `language` 枚举 + 四参数描述约 300-500B，相对 16KiB（`context_limits.zig:32`）
可忽略，且远在通知下限 1KiB 之上余量内；触发选择时按 AlwaysLoaded 级联即可，无需改 selector。

## 问 5 — TLA / recovery

不动 `tests/tla/recovery/Recovery.tla`。recovery 只建模单条模型请求（`src/core/recovery/recovery.zig:1-16`，
NeverGivesUp/Heals）；`timeout_ms` 只把一次子进程调用变成工具结果失败，不产生请求级重试，
因此不在 recovery 模型范围。超时杀树与取消是执行生命周期，归 shell 运行时，早于本方案已在
recovery 之外。回归以确定性测试落点：`bindings_tests.zig` / `sandbox_tests.zig`（语言声明、
超时杀树、输出帽、文件注入四类红测试），非 TLA。

## 红线合规

不碰 `src/core/permissions/`（复用 `bridge.call` 既有准入，问 1 已证不需新增）。不改
`parity_review_free_commands`（新原语命令由 `language` 固定 argv 生成，免审与否仍由
`command_effect.plan` 判定）。`src/mcp/` 零触碰。QuickJS 沙箱零 spawn。

## 落地顺序（TDD，供实现票）

1. 红测试：`run_script{language:"python",code}` 规范化为 `shell action:"run"` 且 argv 为 `python3 <fx临时脚本路径>`、code 经 fx 写入的临时文件（非 stdin，见 B1 修正）；
   带 `-` 前缀模型 token 被拒。2. 扩 `canonicalNestedCall`（`bridge.zig:182-213`）+ 语言白名单常量。
3. `CTX_FILE` 临时文件注入 + env 透传。4. `sandbox_reachable`/派生面 + catalog T2 接入。
5. 输出帽/handle 复用 `shell.encodeResultJson`。6. `--help` 与 fx.sh/docs codemode 页。
