# ISSUE-22 — codemode 输出保留后续打磨（T-12 验证 C1-C3）

- **状态**: closed
- **发现时间**: 2026-11-17
- **来源**: T-12-impl 独立验证（verify.md @ T-12-verify e32e75dff）非 blocking comments
- **工作量**: 小
- **关联**: ISSUE-12（已关闭，主体已合并 main a8921136c）

## 现象

ISSUE-12 主体验证通过，验证员留下三条非阻塞打磨项：

1. **C1**：`@options max_output_tokens` 声明天花板仍是 16,384 token（=64KiB，host.zig:34），而默认捕获帽已抬到 1MiB——声明预算的脚本反而比不声明的拿得更少；`tools.zig` 描述 'clamped to the 1MiB capture cap' 言过其实。修法二选一：天花板上调到 262,144，或改描述措辞（也可两者都做）。
2. **C2**：失败路径的 dropped 计数已随 PartialOutput 传输但未展示——超时且同时命中捕获帽时，失败正文不呈现被丢字节数（也没有句柄）。修法：失败正文按流追加共享 omitted 标记，或收窄 host.zig 注释到字段实际用途。
3. **C3**：`formatOmittedBytesMarker` 的 `catch unreachable`——44 字节文档化下界对 48 字节调用缓冲是安全的，但把契约违约变成 panic 而非错误传播。可改为返回错误或加 comptime 断言钉死下界。

## 修法

三条都是小改，一个 PR 收掉。C1 需先裁决方向（天花板值 vs 描述措辞）；C2/C3 修法已明确。

## 处置

（待完成）

## 处置

已亲改并合入 main：C1 两项都做（max_options_output_tokens 16_384→262_144 匹配 1MiB 捕获帽 + tools.zig 描述校准）；C2 失败正文按流追加共享 omitted 标记（无 drop 时逐字节不变）；C3 新增 omitted_bytes_marker_max_len=44 常量 + comptime 实渲断言钉死下界，catch unreachable 注释改为被断言保护。验收：fmt/build test/e2e 161 pass 全绿；真机探针两例（声明 262144 token 无 capture drop、超帽失败体精确标出 8192）。
