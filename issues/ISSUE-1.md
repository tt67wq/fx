# ISSUE-1 — fx ask 强解包网关 fx_search，精简 provider set 时启动即 panic

- **状态**: open
- **发现于**: T-2 review / a39f4014（worker fx-codex-2）
- **发现时间**: 2026-11-04T11:05:00Z
- **来源**: 审查发现
- **关联 worker / 任务**: fx-codex-2 / T-2
- **严重程度**: low
- **可达性**: 只对 `fx ask`、`fx pr`、`fx issue` 生效。TUI 与 ACP 不触发
- **blocker_kind**: real_defect
- **判据来源**: conductor 自行判断

## 现象

`src/core/cli/cli_ask.zig:712` 写的是 `cfg.provider_set.gateway.fx_search.?`，读的是固定的
`.gateway` 字段，而不是当前选中线路（`select(provider)`）。只要 gateway bundle 的
`fx_search` 为 null，所有 `fx ask` 类命令在构造 web search provider 时 panic：

```
thread ... panic: attempt to use null value
退出码 134 (SIGABRT)
```

编译期完全沉默，因为 `fx_search` 是 `?web_search_provider.Provider`，null 合法。

## 复现

```bash
# 在副本上把 src/builtins/gateway.zig:165 改成 .fx_search = null
zig build
HOME=/tmp/t2home AI_GATEWAY_API_KEY=dummy ./zig-out/bin/fx ask --no-save "hi"
# 退出码 134，输出 panic: attempt to use null value

# 只配自定义线路也崩，因为读的是 .gateway 而不是 select(provider)
# settings.json 只定义一个 openai-chat-completions 线路，FX_PROVIDER=myprov
./zig-out/bin/fx ask --no-save "hi"   # 退出码 134
```

## 根因（若已知）

同一文件 `src/core/cli/cli_ask.zig:1158` 与 `:1172` 正确使用了 `select(provider)`，
只有 `:712` 用了硬解包。当前原生构建总是装配 `builtin_providers.native`
（`src/main.zig:4434`、`:4471`、`:4508`），所以线上不触发。

## 影响范围

`fx ask`、`fx ask --json`、`fx pr` 与 `fx issue`（走 `runPromptCapture`）。
TUI 安全（`src/main.zig:569` 有 `host_profile.web_search` 守卫），
ACP 安全（`src/acp/server.zig:982` 传 optional）。

## 触发前提（两个同时成立才会发生）

1. gateway bundle 的 `fx_search` 变成 null。当前 native 装配恒非 null
   （`src/builtins/gateway.zig:165`），worker-2 的 panic 是在副本上把它改成 null 才复现的。
2. 跑了 `fx ask`、`fx pr` 或 `fx issue`。这三个入口共用 `cli_ask.runPromptWithRunFlags`
   与 `AskContext.init`。

只用 TUI 的用户两条都不成立，这条对他不可达。TUI 走
`src/main.zig:569` 的 `host_profile.web_search` 守卫，ACP 走 `src/acp/server.zig:982`
传可选值。

## 处置

修法是一处删除 `.?`（`web_search_runtime.Config.provider` 本来就是可选字段，
null 是被支持的态，`src/main.zig:569` 与 `src/acp/server.zig:982` 都传 null）：

```zig
// src/core/cli/cli_ask.zig:712
.provider = cfg.provider_set.gateway.fx_search.?,   // 现状
.provider = cfg.provider_set.gateway.fx_search,     // 改成这样，与 ACP 对齐
```

- [ ] 删掉 `.?`，与 `src/acp/server.zig:982` 对齐
- [ ] 加一条单元测试：provider set 的 gateway.fx_search 为 null 时不 panic
- [ ] 验收通过后置为 closed

## 备注

这条与「是否删除 provider 线路」的决策无关，应独立修复。
触发点不是 `fx ask` 独有，`fx pr` 与 `fx issue` 走同一条 `runPromptWithRunFlags` 路径。
