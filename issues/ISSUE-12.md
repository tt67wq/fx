# ISSUE-12 — codemode 输出超限头尾保留并给回读路径

- **状态**: open
- **发现时间**: 2026-11-10
- **来源**: fx codemode 与 pi 1.5.1 源码对比
- **工作量**: 中

## 现象

text() 与 console 超过 64KiB 硬截断后，超出部分直接丢弃且无回读途径。

fx 已有两个先例可循：run_command 的脚本侧结果头尾各半加省略标记
（src/tools/codemode/shell.zig:37）；shell 工具的 full_output_handle 落盘回读机制
（src/tools/shell/shell.zig:1872）。

pi 的对应行为：超限时头尾各半保留，全文写临时文件并在结果附
[Full output: path (read with offset/limit)]（execute.js 的 truncateOutput 与
spillOutput）。

## 修法

text 输出超限改头尾保留，全文按 shell 的句柄机制落盘，结果附 read_tool_result
可用的句柄路径，与 shell 工具的回读方式一致。

## 处置

- [ ] text 输出超限改头尾保留
- [ ] 全文落盘并附句柄路径
- [ ] Zig 单测：超限输出可经句柄回读全文
