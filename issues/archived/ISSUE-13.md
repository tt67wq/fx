# ISSUE-13 — codemode store()/load() 跨调用状态

- **状态**: done（2026-11-24 落地关单归档）
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

- [x] 会话 schema 新增 store 写入 Kind
- [x] 沙箱注入 store 与 load 绑定
- [x] 脚本成功才落盘
- [x] 先跑 T-6 兼容测试，再验证老日志可 resume
- [x] Zig 单测与 e2e 登记

## 落地备注（2026-11-24，T-13）

T-13-impl 红 c901311fe（编译红，新 API 面）→ 绿 e8f0b7791（13 文件 +1145/-7），review PASS（fx-pi2 独立复核，数据安全裁定通过，无阻塞项）。落地：schema 新 Kind codemode_store（Body 持 opaque raw JSON {set,delete}，老 fx 未知 kind 跳过不 Corrupt，T-6 丢失测试等价重建：hand-frame 未知 kind + resume last_seq 推进）；fold.State.codemode_store 折叠 map（delete 先于 set，malformed 跳过，快照 encode/decode 携带，老快照无字段 decode 安全落 null）；fold 属性测试扩 randomEvent 覆盖新字段（ResumeEqualsFullReplay/SnapshotsAreIgnorable）；StoreLog vtable 挂 SessionChildCapability，interactive/ask/subagent 三路由零新 plumbing 携带，落盘走既有 private write() 单一写路径；store.zig 沙箱缓冲态（256KiB 值帽/1MiB 总帽/delete 释放配额/last-write-wins），host.zig 注入 store/load beside text/console；成功才落盘（ScriptError/Timeout/Cancelled/空 writes 四路钉死），无能力时写入静默丢弃（pi :428 语义）；append 失败显式工具报错。pi 1.5.1 语义 16 行对齐表，三处保守偏差（字节计数比 UTF-16 严/hint 无 image()/append 失败报错）。description 1024→1023 字节：加 store/load 措辞，删两句纯指导语（wall clock 语义由 Defaults+headline 承载），保留短语钉死。TLA 判断：TurnLifecycle HostKinds 抽象集语义不变（codemode_store 走 set 路径），无需同步 spec，评审认可。真机四验（失败不落/成功一行/同会话 load/新进程 --resume 还原）实现者与评审者各自亲跑。启动预算 40 次均值对比 base ±1ms 噪声内。e2e 33 pass 含跨调用+resume 用例。已合并 main（57986b1db），双远端已推。评审尾账（minor）：pi key TypeError 文案未能独立定位（fx 文案自洽有钉，风险低）；值帽字节计数对非 ASCII 更严属有意保守。
