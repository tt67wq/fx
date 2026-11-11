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

- [ ] Host Outcome 增加部分结果通道
- [ ] 失败正文附已执行调用摘要
- [ ] Zig 单测：脚本抛错后结果含已捕获 text 与调用摘要
- [ ] 新增 e2e 文件时登记 scripts/pgso/corpus.json 与 tests/e2e/ci-shard-weights.json
