# ISSUE-3 — 保留 provider 名的清单需与线路下线同步

- **状态**: closed
- **发现于**: T-2 review / a39f4014（worker fx-codex-2）
- **发现时间**: 2026-11-04T11:05:00Z
- **来源**: 审查发现
- **关联 worker / 任务**: fx-codex-2 / T-2
- **严重程度**: low
- **blocker_kind**: real_defect
- **判据来源**: conductor 自行判断

## 现象

`src/core/config/configured_provider.zig:296` 把 `codex`、`grok`、`gateway`
列为保留名，拒绝把它们注册为自定义线路。

若下线某条线路时忘记同步这份清单，那个名字会从「未知 provider」变成
「用户可以注册的自定义线路名」。两种失败模式的报错完全不同：

- 保留名在册：`FX_PROVIDER=codex` 报未知 provider
- 保留名被删：`FX_PROVIDER=codex` 变成一个用户线路名，报 base_url 缺失之类的另一类错

## 复现

```bash
# 现状：保留名生效
# FX_PROVIDER=codex fx models -> 未知 provider
# 删除 configured_provider.zig:296 的保留名后：
# FX_PROVIDER=codex fx models -> 变成自定义线路，报另一种错
```

## 根因（若已知）

保留名列表与 provider 枚举是两份独立的清单，没有一致性检查。

## 影响范围

provider 线路下线或改名时的配置解析层。

## 处置

- [x] 保留名清单从 `ProviderId` 派生，或加一条测试断言两者一致
- [x] 若下线线路，在同一次改动里同步该清单
- [x] 验收通过后置为 closed

## 备注

这是「删线路」工作里最容易漏改的一处耦合点。

## 结论

codex/grok 下线时清单已核对；决定保留二者作为 configured provider 的退役名/保留名，`configured_provider.zig` 现状即最终态，关闭。
