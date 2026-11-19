# T-25-review 评审报告 — run_command 超时输出可见性修复

- 评审者：fx-pi2（未参与实现，作者独立）
- 评审对象：fx-pi1 分支 commit **0cf6949e9771ad858954c29de086f5302a8e9c01**（绿），红 commit 6ff98fb4adaec410235d478729ad95d2d601157b，基线 main e9448eaed1a2782e509ccbcaaed37be9586104b6
- 契约：.agents/tasks/T-25-impl/task.md；实现报告：fx-pi1/.agents/tasks/T-25-impl/impl-report.md
- 评审方式：在 fx-pi1 工作树（已 checkout 0cf6949e9，git status 干净）逐行读 diff + 自跑机械核验；未合并进 fx-pi2。

## Verdict: **approve**（附 2 条非阻塞发现 + 1 条观察，见下）

修复正确补上 best_effort 超时路径的句柄提示缺口，与 required 分支逐行对齐，零执行语义变更，红线全部守住。机械核验全绿。两条非阻塞发现均限于今日生产不可达的 backing-null 子路径，不阻塞合并，但建议开票跟踪。

## 一、逐行 diff 核查（3 文件，+120/-6）

### 1. command_replay_store.zig：ensureReplayBacking（+12）
```
pub fn ensureReplayBacking(self, alloc) void {
    if (self.backing != null) return;
    if (self.state != .buffered) return;
    const store = alloc.create(EphemeralStore) catch return;
    store.* = EphemeralStore.init(alloc);
    self.backing = .{ .ephemeral = store };
}
```
- 幂等（backing 非 null 即返回）、仅 .buffered 收养（.unavailable/.streaming/.sealed_file/.retained/.consumed 均 no-op）、alloc 失败静默返回不留半态。✔
- 失败降级链完整：收养后若 createSpool 失败（windows/wasi 返回 EphemeralReplayUnavailable，或 /tmp 不可写）→ materializeInline err → makeUnavailable → retain 返回 .unavailable，与既有 best_effort 一致。✔
- **泄漏核查（发现 1，非阻塞）**：收养的 EphemeralStore 是 arena 上的匿名对象，无人调 deinit。retain→materializeInline→createSpoolWithStem 会在 store.files 映射里留一个 dup 的 stored fd（writer fd 已由 spool.file.deinit 关闭）。成功发布后 orchestrator 置 replay_handed_off=true，**从不**对该 capture 调 releaseRetained/discard（capture 与 store 均 arena 所有，turn 结束 arena.deinit 只回收内存、不关 fd）。因此 backing-null 子路径每超时一次泄漏 1 个 open fd + 1 个 unlinked /tmp 文件，直到进程退出。
  - 清理覆盖核对：abort/discard 经 deleteSpool→store.delete 关 fd（streaming/sealed_file/retained 态）；**releaseRetained 只 free handle 字符串、不关 store fd**（设计如此，运行时级 store 靠会话 deinit 收尾）。收养 store 没有这个收尾人。
  - 影响面：生产不可达（见发现 2 论证），红测试每次跑泄漏 1 fd（测试进程退出即回收）。故非阻塞。
  - 报告偏差节自述「保留文件句柄仅在 discard/abort/releaseRetained 时关闭」**不准确**：releaseRetained 不关 store fd，且成功发布路径三者都不调。建议修正措辞并开票：给收养 store 一个所有者（如 Capture 增 owned_store 标志，在 releaseRetained/discard 时 deinit），或在该子路径改为内联头尾摘录而非句柄。

### 2. execution_memory.zig：finalizeCommandReplay + retainBestEffortReplay（+45/-6）
- timed_out 判别（发现 3 观察）：`prepared.memory.command_process_presentation == .timed_out`。来源可靠：command_result_mapping.timeoutFailure:121、commandProcessPresentation（tool_runtime:2378，foreground.timed_out）、shell.publishSnapshotMetadata:1548（error_name==TimeoutExpired）。applyToolResultMemory:1225 在 finalize 之前拷贝（orchestrator:11716→11720 顺序正确）。其余 presentation（exit_code/signal/output_capture_failed）不匹配。无其它路径误置 .timed_out。✔
- ensureReplayBacking 仅在 timed_out 时调，required 分支提前 return 不受影响。✔
- 7 处 best_effort retainCommandReplay 调用点全部改为 retainBestEffortReplay（基线 7 处：1268/1271/1287/1290/1303/1306/1315 → 绿 7 处 helper + helper 内部 1 处原函数）。无遗漏。✔
- helper 与 required 逐行对齐：retain→取 .available descriptor→appendModelHandleNotice→stored_output_bytes=model_output.len。required 用 try 传播错误，helper 用 catch return 静默降级——符合 best_effort 契约。✔
- notice 追加失败（OOM/InvalidReplayHandle）时 command_output_replay 仍 .available 但 stored_output_bytes 未同步：轻微不一致，但属静默降级语义，可接受。✔
- eql(captured,ordinary) discard 优化对超时无误伤：stub 首行 timeout=true / 失败 JSON 首行 { 均非 validForegroundStatus（command_output_content:516）→ canonicalizeForegroundResult 返回 null → 走 retainBestEffortReplay；且 stub 不含已捕获字节，captured 非空时不可能 equal。✔
- 预算：required 在 prepare 阶段预留 notice_reserve（:977），best_effort 超时用满预算后追加 notice（≤261 字节）。但超时 model_output 恒为小 stub/失败 JSON（~250 字节，远小于 min_configured 1024），不会越界。✔

### 3. tool_runtime.zig：红测试（+69，红 commit 已含）
- 配置 interactive=true、无 capability、无 ephemeral、command_timeout_ms=1000、profile=user → commandReplayPolicy(user,false,true,null)=best_effort，initCommandReplayCapture create(arena,limit,null) backing=null。确实驱动 ensureReplayBacking 子路径。✔
- 断言：status=failure、model_output 含 timeout=true、capture.hasOutput、finalize 后 command_output_replay=.available、model_output 含 descriptor.handle 与 read_tool_result。钉死「句柄提示可见」契约。✔
- 测试只断言句柄出现在输出，不断言可读——与披露的 backing-null 限制一致。✔
- 对照测试保持绿：no-save terminal exec publishes one readable ephemeral replay、run_command timeout returns model-visible failure（自跑确认 OK）。✔

## 二、机械核验（评审者自跑，fx-pi1 工作树 @0cf6949e9）

1. **zig build test 全绿**：为排除实现者缓存，用独立 --cache-dir /tmp/t25r-cache 全量重编译重跑：22/22 steps succeeded，**10274/10281 tests passed（7 skipped）**，主测试二进制 10017 pass/2 skip/0 failed（约 361s）。另直接运行主测试二进制复核关键三条：
   - core.tooling.tool_runtime.test.no-save timeout command surfaces captured output to the model ... **OK**
   - ...no-save terminal exec publishes one readable ephemeral replay ... **OK**
   - ...run_command timeout returns model-visible failure ... **OK**
2. **zig fmt --check src/**：退 0。
3. **bash scripts/check-public-surface.sh**：退 0。
4. **四边界脚本**：check-agents-boundary / check-compactor-boundary / check-indexer-boundary / check-recovery-boundary 各退 0。
5. **真机冒烟**：FX_BENCH=1 ./zig-out/bin/fx 退 0、stderr 0 字节；fx --version 退 0；tmux 交互启动首帧正常（v0.0.16）、会话存活、/exit 退出、stderr 0 字节、无 abort。
6. 红绿顺序：红 6ff98fb4a（仅 tool_runtime.zig +69 测试）先于绿 0cf6949e9（仅 execution_memory.zig + command_replay_store.zig）。红证据 red-evidence.txt 在 fx 主树任务目录，指明失败测试名与场景。✔

## 三、红线核对

- commandReplayPolicy 决策表未动（diff 中 0 处涉及）。✔
- 零执行语义变更：超时仍杀整树、仍工具失败；改动只在 finalize 呈现层与 capture backing 收养。✔
- admission/permissions/catalog 零触碰（diff 仅 3 文件，无相关改动）。✔
- tests/tla/ 零触碰（diff --name-only 无 tests/tla）。✔
- 无新 CLI 面/settings 键/环境变量（新增行无 getenv/flag/settings）。✔
- 无个人路径（diff  grep 个人目录、team_id、slug 均空）。✔
- zig fmt 后提交（fmt --check 退 0）。✔

## 四、发现汇总

**发现 1（非阻塞，建议开票）**：收养 EphemeralStore 的 retained fd 无所有者收尾，backing-null 超时子路径每命令泄漏 1 fd + 1 unlinked /tmp 文件至进程退出；报告「releaseRetained 关闭句柄」措辞不准确。今日生产不可达、测试进程退出即回收，故不阻塞。修法建议：Capture 增 owned_store 标志并在 releaseRetained/discard 时 deinit 收养 store，或该子路径改内联头尾摘录。

**发现 2（非阻塞，论证记录）**：backing-null best_effort 子路径生产不可达——app_agent_runtime:417-423 与 cli_ask:1934 保证 capability 或 ephemeral 至少其一非 null，ensureReplayBacking 在生产恒 no-op。且生产 shell 走 managed_execution（entry 自持 capture），result.command_replay_capture 恒 null，finalizeCommandReplay 在生产本就是 no-op（与 T-26 核查同源）。本修复在契约层正确、测试覆盖到位，但「活缺口」表述宜收敛为「toolRunCommand 路径（测试/wasi/兼容后端）的契约缺口」。不阻塞。

**观察 3**：timed_out 判别可靠，无误入路径（详见一.2）。

## 五、结论

approve。修复最小、对齐 required 先例、红线全守、机械核验全绿。发现 1/2 限于今日生产不可达子路径，建议合并后开票跟踪收养 store 的所有权收尾，不要求本轮返工。
