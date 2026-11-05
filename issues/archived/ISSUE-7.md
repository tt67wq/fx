# ISSUE-7 — 下线 provider 线路是破坏性变更，且 vercel_protocol.zig 属共享基础设施

- **状态**: closed
- **发现于**: T-2 review / a39f4014（worker fx-codex-2）
- **发现时间**: 2026-11-04T11:05:00Z
- **来源**: 审查发现
- **关联 worker / 任务**: fx-codex-2 / T-2
- **严重程度**: medium
- **blocker_kind**: needs_user
- **判据来源**: conductor 自行判断
- **关闭时间**: 2026-11-04（提交 1983cd19「Remove the ChatGPT Codex and xAI Grok provider lines」）

## 现象

如果将来真的下线 codex 或 grok 线路，改动远不止删两个模块文件：

1. **对外契约是破坏性的**。`sdk/package.json:69` 与 `:73` 已发布 `./chatgpt` 与
   `./grok` 两个 subpath export，删除等于删掉已发布的包入口，对下游是破坏性变更，
   需要版本号与迁移说明，不是内部重构。

2. **真正的阻塞在类型层**。`ProviderId`（`src/core/config/model_provider.zig:6`）带
   `.codex` 与 `.grok` 两个变体，`src/core/gateway/provider_set.zig:64` 的
   `Set.select` 是穷尽 switch。删掉枚举变体实测产生 9 处编译错误，跨鉴权、配置、
   CLI、provider 四层。静态统计 `.codex` 命中 62 个源文件、`.grok` 命中 42 个。

3. **vercel_protocol.zig 不是 vercel 线路的私有文件**。它被自定义线路
   （`src/gateway/chat_completions.zig:13`、`:308`）、SDK 宿主链
   （`src/gateway/host_stream_provider.zig:5`、`:74`）和失败诊断
   （`src/gateway/vercel_failure_diagnostics.zig:96`）共用。
   把「删 vercel 线路」等同于「删这个文件」是范围判断错误。

## 复现

```bash
# 副本上分别试三种删法，记录编译与运行结果
# A. 只删 src/gateway/vercel_protocol.zig -> 编译失败
# B. 删 ProviderId 的 codex/grok 变体 -> 9 处编译错误（跨 4 层）
# C. 删 host_openai_codex.zig / host_xai_grok.zig -> SDK 入口 FileNotFound
```

## 根因（若已知）

线路选择是穷尽 switch 加联合类型，删除线路必然波及类型层；
对外 subpath export 让删除变成公共 API 变更。

## 影响范围

任何下线线路的改动。

## 处置

- [x] 先决定是否下线（needs_user）——用户决定：分叉自用，不再同步上游，做硬删除，
      不留弃用 shim 与警告窗口，不做上游 PR 与 fx.sh 文档同步
- [x] 若下线：先写迁移与降级路径（见 ISSUE-2），再改类型层
- [x] 若下线：同步 sdk/package.json 的 exports 与版本号，给出迁移说明
      ——删掉 `./chatgpt` 与 `./grok` subpath export，删掉对应类型与凭据助手
- [x] 若只是重构：把 `expandPendingToolReviewMessages` 从 `vercel_protocol.zig`
      抽到共享文件，解开自定义线路与 vercel 线路的耦合
      ——`vercel_protocol.zig` 保留，自定义线路继续复用它
- [x] 验收通过后置为 closed

## 备注

关于「本地只用 magpie 自定义 provider」这个前提：运行时保留自定义线路足够，
但仓库里三条原生线不该顺手删掉，原因就在上面 1 到 3 条。

实际处置以本次硬删除为准：上面第 1 条的破坏性变更风险由「分叉自用、不再同步上游」
的前提承担，第 2 条的类型层波及已在提交 1983cd19 中处理完毕。
