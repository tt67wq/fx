# ISSUE-13 — codemode store()/load() 跨调用状态

- **状态**: open
- **发现时间**: 2026-11-10
- **来源**: fx codemode 与 pi 1.5.1 源码对比
- **工作量**: 大

## 现象

脚本之间没有任何状态，多步任务每次重查。沙箱每次调用新建（codemode_tool.zig:74），
JS 侧变量天然不跨调用。

pi 的对应行为：store(key, value) 与 load(key) 保存 JSON 值，写入以 codemode-store
自定义会话条目持久，恢复时按分支重放（execute.js 的 readCodemodeStore）。

## 修法

会话日志新增 Kind 承载 store 写入，不用新 SetKey。T-6 报告第 5 节已判定：新 SetKey
让老 fx 读日志整体 Corrupt，新 Kind 才兼容（未知 kind 按 1366-1370 跳过）；
.agents/tasks/T-6/codemode_store_corrupt_test.zig 已钉死该行为。

沙箱注入 store 与 load 绑定，写入先缓冲在 Host，脚本成功后落会话；失败脚本的写入
不落盘，与 pi 的成功才 appendEntry 一致。

## 处置

- [ ] 会话 schema 新增 store 写入 Kind
- [ ] 沙箱注入 store 与 load 绑定
- [ ] 脚本成功才落盘
- [ ] 先跑 T-6 兼容测试，再验证老日志可 resume
- [ ] Zig 单测与 e2e 登记
