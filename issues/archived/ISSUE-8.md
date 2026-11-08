# ISSUE-8: codemode 阶段 2 CR 发现（外部核验 2026-11-07）

> 进度：已关闭（2026-11-08）。四项全部闭环，归档至 issues/archived/。

来源：用户送审的阶段 2 CR 报告返工意见。四条整改进阶段 3，1-2 在接真实工具链（3.2/3.3）前必须完成。

## 1. text/console 缓冲无硬上限（缺陷，安全相关）

host.zig 的 text_buf 与 console_buf 走宿主 allocator 增长（appendValue appendSlice），
不经 JS runtime 分配器：JS_SetMemoryLimit 64MB 管不到。脚本循环 text(大字符串) 时
JS 堆临时 cstring 用后即释，64MB 帽挡不住宿主侧累积，超时窗内可撑爆 fx 进程内存。

修法：缓冲设硬上限，语义对齐既有 max_tool_result_bytes。归属 3.2（token 经济）前落地。

## 2. e2e 覆盖与命名不符（报告失实）

codemode-cancel.test.ts 驱动的是假 shell 脚本的泛化 worker 取消路径，文件头注释自承
不依赖 codemode 工具桥，对 sandbox.zig 零覆盖。改名或加注释，真实沙箱取消 e2e 排进 3.3。

## 3. 取消源叙述修正

T-11 起 sandbox 用自己的 cancel_flag（sandbox.zig 注释写明接回 worker_cancel_requested
原子是阶段 3 的活），当前是第二取消源。3.3 验收项：接回同一原子。

## 4. deinit 最坏阻塞一个超时周期

shutdown 后直接 join，不进行中 eval 的兜底依赖 30s deadline 中断。不挂死但最坏阻塞
一个超时周期。注释写明即可。

## 关闭记录（2026-11-08）

1. 缓冲硬上限：T-15（1802eabc），text/console 各 64KiB，超出截断并置 truncated。
2. 真实沙箱取消 e2e：T-11 补 codemode-cancel 真实桥路径，T-17/T-18 扩展（Escape 停无尽脚本、取消后如实回报）。文件头注释同步修正，命名与覆盖一致。
3. 取消源归一：T-17（4f2c7dda），Sandbox 自有 cancel_flag 废弃，取消接 worker_cancel_requested 同一原子，cancel 不再误报 Timeout。
4. deinit 阻塞说明：sandbox.zig deinit 注释写明最坏等待一个超时周期（默认 30s）。

验证：zig build test 全量 rc=0；codemode e2e 6/6（admission 4 + cancel 2）。
