# ISSUE-6 — libfx 宿主侧的自定义线路没有权限自动复核

- **状态**: open
- **发现于**: T-1 review / defe3086（worker fx-codex-1）
- **发现时间**: 2026-11-04T11:05:00Z
- **来源**: 审查发现
- **关联 worker / 任务**: fx-codex-1 / T-1
- **严重程度**: medium
- **blocker_kind**: real_defect
- **判据来源**: conductor 自行判断

## 现象

`src/gateway/host_chat_completions.zig:47` 的 bundle 只填 `agent_stream` 与
`model_catalog`，缺 `cli_model_catalog` 与 `permission_reviewer`；
CLI 侧的 `src/gateway/chat_completions.zig:25` 四项都填。

于是 libfx（N-API、WASM）宿主上的自定义线路没有权限自动复核，
`src/core/subagent/agent_adapter.zig:157` 拿到 null 后退回 `Classifier.disabled()`。

## 复现

```bash
# 在 libfx 宿主（Node/WASM）里用自定义线路跑一个需要复核的工具动作
# 观察走的是 disabled classifier，而不是配置的 reviewer
```

## 根因（若已知）

CLI 与 libfx 两条装配路径各写了一份 bundle 字段清单，没有共享来源。

## 影响范围

libfx SDK 集成方的权限自动复核能力。

## 处置

- [ ] 确认这是有意的不对称还是漏项
- [ ] 若为漏项，补齐 host 侧 bundle，并加一条对照测试
- [ ] 验收通过后置为 closed

## 备注

若为有意设计（例如宿主侧权限策略不同），请在代码里写明原因，避免下次再被当成 bug。
