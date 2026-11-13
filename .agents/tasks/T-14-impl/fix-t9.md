# T-14-9 收口轮（G1/G2/G4）

分支 fx-pi1，基于 326db8c07。红 commit 见 `git log`（"T-14-9 red"），记录见下。

## G1 — result arena 切分的回归守护

新增 e2e：`a nested write then read back returns the written content`
（tests/e2e/codemode-admission.test.ts）。场景与契约一致：gate 开启 + `edit: allow`，
脚本先 `tools.call("write_file")` 写文件，紧接着 `tools.call("read_file")` 读回；断言
文件存在、磁盘内容等于写入值、读回文本含该值。

红证据（临时注入缺陷）：把 `bridge.zig` 的 `.result_allocator` 改回 `arena`
（单一 arena）重编译后：

    Expected: true
    Received: false
    (fail) a nested write then read back returns the written content [693.99ms]

即 prepared file mutation 与结果共用 arena 时写不成功，测试确实抓住该回归。还原后：

    14 pass, 0 fail

说明：契约写的是「Zig 单测放 bridge/host 同级测试块」，实际选了 review G1 里推荐的
第 1 条（e2e 绿路径），理由是该场景需要真实 tool runtime（Context、worker、权限管线、
临时工作区）才能驱动 bridge.call 的 prepared mutation 路径，在 Zig 测试块内重建该
运行时属于新建测试脚手架而非守护回归本身；e2e 直接对应用户可见行为，且已用缺陷注入
证明其有效。若确需 Zig 级守护（断言两个 allocator 不是同一 owner），建议单独通过把
两处 allocator 选择抽成可测的小函数来实现，而不是在测试里重建运行时。

## G2 — deny 覆盖扩到 edit_file

新增 e2e：`a nested edit_file on the derived face is still denied by admission`。
`permission: { edit: "deny" }` + gate 开启，脚本 `tools.call("edit_file", {path,
old_string, new_string})`；断言文件内容未变且脚本收到 `{"denied":true,"reason":…}`。

该行为在实现侧本就正确（deny 走准入，与 result arena 无关），因此测试一落地即绿：
没有可注入缺陷的等价路径，红证据不适用。属覆盖锁定，非修复。

## G4 — golden 测试改名

`sandbox face keeps the shipped surface whether the gate is off or on` →
`sandbox face locks the shipped four names and the nine-name derived face`，
并在 `closed` 处加一行注释说明默认面查询（`bindings.find("write_file") == null`）
指的是出厂面而非开启面，避免误读。

## 未做（按任务）

G3（surface.md 过程产物）、G5（ISSUE-14 首项勾选）由 conductor 在整合时处理。

## 验收

见回报中的命令行结果。
