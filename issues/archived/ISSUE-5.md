# ISSUE-5 — 自定义线路的 model_metadata 契约缺口，且未声明窗口就不主动压缩

- **状态**: closed
- **发现于**: T-1 review / defe3086（worker fx-codex-1）
- **发现时间**: 2026-11-04T11:05:00Z
- **来源**: 审查发现
- **关联 worker / 任务**: fx-codex-1 / T-1
- **严重程度**: medium
- **blocker_kind**: contract_ambiguous
- **判据来源**: conductor 自行判断

## 现象

两个相关缺口：

1. 声明式元数据字段太少。`src/core/config/configured_provider.zig:43` 只允许
   `context_window`、`max_output_tokens`、`supports_tool_use`、`supports_vision`，
   而目录投影会读 `has_reasoning`、`supports_fast_mode`、`has_explicit_caching`
   （`src/core/gateway/model_catalog_metadata.zig:10`），这些永远为空。
   本地模型明明支持推理或缓存也无法声明，reasoning、fast、ultrafast 一律不可用
   （`src/core/config/model_capabilities.zig:276`、`:295`）。

2. 未声明 `context_window` 时上下文自动压缩阈值失效。`compactAtTokens` 返回 null
   （`src/core/compactor/window.zig:144`），`due()` 永远 false
   （`src/core/compactor/window.zig:129`），只在服务端回 overflow 时被动压缩
   （`src/core/compactor/window.zig:136`）。长会话会一直撞服务端拒绝才压缩。

## 复现

```bash
# 自定义线路的 model_metadata 不写 context_window
# 跑一个长会话，观察压缩只在服务端拒绝后发生
```

## 根因（若已知）

元数据 schema 是为「声明模型是什么」设计的，但当前只覆盖到「能不能带图、能不能用工具」。
缓存、推理、窗口这几个 fx 自己要用的维度没有入口。

## 影响范围

本地网关（magpie 一类）自建 provider 的用户。缺 context_window 时是长会话体验问题；
缺 caching/reasoning 字段时是能力声明问题。

## 处置

- [x] 给 model_metadata 补 `context_window` 之外的常用维度，或明确写文档说明必须声明
      （2026-11-06 已实现：新增 `supports_fast_mode`、`supports_explicit_caching`、
      `supports_implicit_caching`、`reasoning_efforts`；reasoning 力度列表非空即隐含
      支持推理。手册文档更新仍待补。）
- [x] 未声明 context_window 时给出可发现提示，而不是静默不压缩
      （2026-11-06 已实现：会话启动时一次性警告（models 域通知），
      `fx doctor` 新增 models 检查项，文本与 JSON 同一 snapshot。）
- [x] 验收通过后置为 closed（2026-11-06 验收：build、全量单测、configured-providers e2e 55 pass、doctor 文本与 JSON、TUI 启动一次性警告均通过）

## 备注

schema 扩张要过 `fx-cli-shape` 技能：新增字段是用户可见的配置面变更。
