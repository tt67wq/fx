# CLAUDE.md

本文件是精简入口。完整规则以根 `AGENTS.md` 为准（就绪门、CI、Zig 0.17 约定、权限），测试分层见 `tests/AGENTS.md`。冲突时听 AGENTS.md。

## 技术栈
- Zig >= 0.17，零外部 Zig 依赖；vendor/quickjs 只给 codemode 沙箱用。
- 测试：Zig 内联单测 + Bun E2E（tmux）+ Bun evals + TLA+ 模型（tests/tla/）。

## 构建与验证
- 构建 `zig build`；全量单测 `zig build test`；格式 `zig fmt src/`；本地综合门 `make check`。
- 聚焦 E2E：`cd tests/e2e && FX_SOUND=0 bun test <file>.test.ts`（macOS 必须关声音，按文件名跑）。
- 验证永远用 `./zig-out/bin/fx`，不用 PATH 上的 fx。宣布完成前必须亲手跑二进制走过改动路径（AGENTS.md 五道门）。

## 结构速查
- `src/main.zig` 组合根；`src/core/` 状态与契约；`src/tools/` 工具实现；`src/builtins/` 命令/工具规格；`src/gateway/` 传输；`src/ui/` 渲染；`src/mcp/` MCP 引擎。
- 四个 CI 强制边界：agents / compactor / indexer / recovery，外部只 import 各自前门文件。
- 一次对话主路径：ui/event_loop → core/app/app_agent_runtime.zig:1217 → core/agent/runtime/orchestrator.zig processAgentPrompt → gateway_step.streamModelCompletion → tooling/tool_runtime.executeToolCallAuthorized → tool_dispatch.dispatchToolCall → tools/*。

## 约定
- 命名：函数 camelCase，变量/文件 snake_case，类型 PascalCase，flag kebab-case。
- allocator 显式传；I/O 走 std.Io 或 core/shared/io.zig；JSON 解析用 shared/json_decode.zig；排序用 shared/sort_utils.zig。
- 单测内联在被测文件；新 E2E 文件要登记 ci-shard-weights.json、pgso/corpus.json（平台分支再加 macos-platform-tests.json）。
- 提交祈使句标题，TDD 红绿分 commit；PR 打 type: 标签；不提交个人路径（check-public-surface.sh）。
- 改用户可见控制先用 fx-cli-shape 技能；写文档用 technical-writer 技能。

## 本 fork 的本地约定（来自 MEMORY.md）
- push 同步双远端 origin（github tt67wq/fx）与 gitlab。
- `.agents/`、`.fx/tmp/` 不入库；问题单在 `issues/`；踩坑记忆在 `MEMORY.md`。
