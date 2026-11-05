# ISSUE-2 — provider 存档不可解析时会静默丢弃整个会话

- **状态**: closed
- **发现于**: T-2 review / a39f4014（worker fx-codex-2）
- **发现时间**: 2026-11-04T11:05:00Z
- **来源**: 审查发现
- **关联 worker / 任务**: fx-codex-2 / T-2
- **严重程度**: medium
- **blocker_kind**: real_defect
- **判据来源**: conductor 自行判断

## 现象

`src/core/session/session_codec.zig:65` 用 `parse_saved` 解析存档里的 provider 字段，
解析失败直接返回 `error.InvalidDurableField`；`src/core/app/app_session_runtime.zig:1253`
把它归类为 decode 阶段失败并丢弃会话。

结果是：只要会话里存过一个当前 fx 不认识的 provider（例如
`"provider":"codex"`、`"provider":"grok"`，或用户手改过的 provider 名），
该会话就静默不可用，没有降级为「用默认 provider 打开」的路径。

## 复现

```bash
# 造一个含未知 provider 的存档后加载
# session.json 里 "provider":"codex"，当前构建不认识该值时
# fx sessions list 不再列出该会话，且没有用户可见的降级提示
```

## 根因（若已知）

存档解码把「未知枚举值」当成损坏数据处理，而不是当成「配置漂移」。
provider 属于用户可配置、可变动的字段，不适合用损坏数据的语义。

## 影响范围

所有历史会话的跨版本、跨 provider 兼容性。
若将来下线某条 provider 线路，所有用过该线路的用户会话会同时失效。

## 处置

- [x] 未知 provider 值降级为「用当前默认 provider 打开」，并在会话里标记原值
- [x] 至少给出用户可见提示，而不是静默丢弃
- [x] 加一条解码测试：未知 provider 字段不导致会话丢失
- [x] 验收通过后置为 closed

## 备注

若确定要下线 provider 线路，这条必须先落地，否则是数据丢失级破坏。

## 结论

自用 fork 无存量对话，跨版本 provider 存档兼容不构成实际风险，关闭。
