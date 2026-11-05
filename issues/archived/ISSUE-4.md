# ISSUE-4 — web_search 在非网关线路上仍被广告，每次调用必失败

- **状态**: closed
- **发现于**: T-1 review / defe3086（worker fx-codex-1）
- **发现时间**: 2026-11-04T11:05:00Z
- **来源**: 审查发现
- **关联 worker / 任务**: fx-codex-1 / T-1
- **严重程度**: medium
- **blocker_kind**: real_defect
- **判据来源**: conductor 自行判断

## 现象

自定义 openai-chat-completions 线路的 `fx_search` capability 为 false，
执行期后端被置空（`src/core/app/app_agent_runtime.zig:243`、
`src/core/cli/cli_ask.zig:1119`、`src/core/subagent/agent_adapter.zig:198`），
但工具名 `web_search` 始终留在广告集里（`src/builtins/tools.zig:833`）。

模型因此每轮都可能花一次工具调用，只拿到失败文案：
`"web_search is unavailable: no local runtime with a configured Gateway transport policy is installed`
（`src/core/tooling/tool_dispatch.zig:992`、`src/tools/web/search.zig:124`）。

## 复现

```bash
# 只配自定义线路跑一轮对话，观察工具调用里出现 web_search 且必然失败
FX_PROVIDER=myprov fx ask --no-save "查一下今天的新闻"
```

## 根因（若已知）

capability 开关只影响执行期后端，没有像 vision 那样在广告层过滤。
vision 有对等处理：`src/core/tooling/tool_runtime.zig:364` 的 `providerDisablesTool`
会拒绝并返回 "Unsupported tool: vision"，web_search 没有。

## 影响范围

所有非网关线路的自定义 provider。每轮浪费一次工具往返，并让模型拿到看似可用
实则恒失败的工具。

## 处置

- [x] 在广告层按 capability 过滤 web_search，或补齐 `providerDisablesTool` 对等处理
- [x] 加一条测试：非网关线路的工具广告集里没有 web_search
- [x] 验收通过后置为 closed

## 备注

与 ISSUE-1 是不同问题：ISSUE-1 是崩溃，这一项是每轮白花一次工具调用。

## 结论

已按 `providerDisablesTool` 对等方案修复（提交 d1b98069）：web_search 在
`!capabilities.fx_search` 时于 validate/availability 两入口立即拒绝，返回
`Unsupported tool: web_search`，不再打到执行后端拿 Gateway transport 错误。
广告层过滤未做（与 vision 行为一致：广告但快速拒绝）。

验证：`zig build test` 全绿；新增单测覆盖两条路径；假网关端到端确认
自定义线路工具结果为 `Unsupported tool: web_search`，gateway 线路不受影响；
web-search 相关 e2e（fake gateway + permission progress）20 项全过。
