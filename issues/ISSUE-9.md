# ISSUE-9 — codemode 失败结果丢弃部分输出与已执行调用

- **状态**: open
- **发现时间**: 2026-11-10
- **来源**: fx codemode 与 pi 1.5.1 源码对比
- **工作量**: 小
- **关联**: 与 ISSUE-11 共用失败摘要呈现，宜同批实现

## 现象

src/tools/codemode/codemode_tool.zig:85-103 的 ScriptError 与 Timeout 分支只返回
异常消息。Host 的 text_buf 与 console_buf 已捕获的内容、脚本失败前已生效的嵌套
调用全部丢弃，模型看不到失败前完成了什么，只能盲重试。

pi 的对应行为：execute.js 的 formatError 保留部分输出，formatCallSummary 追加
"Tool calls made before the failure (they are not undone): read_file (ok), ..."，
失败结果仍是完整可读的。

## 修法

Host 失败路径也产出部分 Result：text/console 已捕获内容加错误消息，Outcome 增加
部分结果通道。失败仍走 failure disposition，正文追加嵌套调用摘要（摘要部分见
ISSUE-11）。

## 处置

- [x] Host 失败路径产出部分输出（takePartialOutput 访问器）
- [x] 失败正文附已执行调用摘要与部分输出
- [x] Zig 单测四支：访问器、formatter 两形态、截断与 overflow、空形态逐字节相同
- [x] e2e 用例加进已分类的 codemode-admission.test.ts（文件级分类免登记；评审 F-2 修正：不新增 e2e 文件）

## 实施方案（2026-11-11 评审通过）

核心改动只在失败分支：失败结果多带两类信息（已捕获的部分输出、嵌套调用摘要），
准入管线、取消契约、成功路径全部不动。无部分输出且无嵌套调用时，失败正文与
改前逐字节相同。

四个文件分工：

- codemode/host.zig：takePartialOutput 访问器，toOwnedSlice 转移 text_buf 与
  console_buf 所有权并清空缓冲。appendCapped 的 64KiB 是第一道上限；4KiB 裁剪
  属展示层，放 formatter 不放这里。
- tooling/tool_runtime.zig：CodemodeHostState 加 32 槽调用摘要（name 用静态
  白名单名，无分配）与 overflow 位，栈上自动清零；索引复用 call_sequence。
- codemode/bridge.zig：只在嵌套调用出口记终态 ok/denied/failure；error.Cancelled
  出口记 cancelled。准入前不记。
- codemode/codemode_tool.zig：formatFailureBody 组装失败正文；text/console
  分块并标注来源；函数内分配失败时 OOM 降级回一行错误，失败报告本身永不失败。

## 评审结论（2026-11-11，全采纳）

- F-1：4KiB 是展示层二次裁剪，64KiB 是第一道上限，最坏增量约 8KiB 加摘要。
- F-2：不做新 e2e 文件，用例加进 codemode-admission.test.ts（console.log 后
  throw，几秒完成），替代手工触发。
- F-3：text 与 console 分块标注来源，不合并单一 Partial output 块。
- F-4：formatFailureBody 内 OOM 降级回一行错误。
- F-5：只在出口记终态，第四出口 error.Cancelled 记 cancelled；索引复用
  call_sequence。
- F-6：摘要槽沙箱线程写、eval 返回后读，与 lastExceptionMessage 同一静止语义；
  take 用 toOwnedSlice 防双 free；空形态逐字节相同的不变量进单测显式断言。

验证：四支单测（访问器、formatter 两形态、overflow、空形态逐字节相同）加一支
e2e；真二进制开 experimental.codemode 跑失败脚本；CI 过 Build & Test 与
macOS arm64。

实现：见工作区变更（host 访问器、state 32 槽摘要、bridge 出口记状态、formatFailureBody）。
