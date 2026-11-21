# T-27-review 评审报告 — codemode 嵌套命令预算 min(requested, remaining)

- 评审者：fx-pi2（未参与实现，作者独立）。完成 T-28-impl 后接本任务。
- 评审对象：fx-pi1 分支 T-27-impl，绿 commit **8b56f4cd4**（红 cdc4b24f7，报告 0fe6c9170），基线 integrate-issue29@0323b5f35。
- 契约：.agents/tasks/T-27-impl/task.md；报告/红证据：同目录 impl-report.md / red-evidence.txt。
- 评审方式：逐行读 diff（4 源文件 + 1 E2E）+ 自跑机械核验 + 基线对照实验（fx-integrate@0323b5f35）。

## Verdict: **changes-requested**（1 条阻塞 + 2 条非阻塞观察）

min(requested, remaining) 语义实现正确，红绿链真实，两条新 E2E 确定性钉住 min 两支，红线全守。
**但本改动在预算边界引入一个约 33–50% 的时序竞争，使既有 23b 覆盖矩阵第三行 E2E
「budget-killed long command leaves its shell snapshot tail in the failure body」由稳定绿转为_flaky_**，
违反验收「codemode-admission.test.ts cli.test.ts 0 fail」。须先消解该竞争或同步更新该旧测试，再批准。

## 一、语义正确性（逐条）

### 1. bridge.zig applyAmbientBudget（remaining 采样）✔
- remaining = budget -| (now − ambient_started)，饱和减法正确；now<=started 时 elapsed=0（时钟回拨保护）；cast 溢出饱和 maxInt。
- 采样时刻在 admission 之前（bridge.zig:128 applyAmbientBudget vs :152 requestPermissionOutcome），权限等待不吃命令预算——符合用户拍板语义。命令实际在等待之后启动，故命令可运行至 deadline+W（W 为权限等待），这是「等待不吃预算」的必然结果，契约已明确接受。
- remaining=0 → command_timeout_ms=0 → ExecutionControl.check elapsed>=0 恒真 → 立即 TimeoutExpired（command_runner.zig:1043）。预算耗尽语义正确，单元测试钉住 0 值。
- command_timeout_started_ms 仍传脚本起点作为标记。注释（52-57）已重写为 remaining 采样 + min，与实现一致。

### 2. tool_runtime.zig:454 orelse 链 ✔
- request.command_timeout_started_ms orelse execution_ctx.command_timeout_started_ms：请求显式带值优先（续传语义不变），bridge 标记不再被请求里的 null 覆盖。
- 全仓核：除 bridge 外无任何调用方设置 ctx.command_timeout_started_ms 或 request.command_timeout_started_ms（recovery 亦无），故直跑/续传不受影响。CodemodeHostState ambient 字段注释（~1382）已同步更新。

### 3. shell.zig callRun ✔（直跑零变化属实）
- 有标记 ∧ command_timeout_ms 非 null → min(requested, remaining)；requested 缺省 → remaining；无标记 → requested orelse ctx.command_timeout_ms（原 requested-wins）。
- diff 仅 1 个 hunk（callRun timeout_ms 块）；tty/interact/stop 路径零触碰。直跑 ctx.command_timeout_started_ms 默认 null → 走原支，零变化。
- 既有默认 30s/5s 预算 E2E（sleep 60 无 requested）仍绿：调用发起≈脚本起点，remaining≈整预算。

### 4. DispatchContext 新字段 ✔
- command_timeout_started_ms: ?i64 = null，默认 null；9 处 DispatchContext 构造点均不受影响；默认值测试（tool_dispatch.zig:1485 一带）未断言该字段，新增不破坏。typedDispatchContext 透传。

## 二、红绿链 ✔
- 红 cdc4b24f7 仅测试改动（bridge.zig 只有 @@ -1402 测试 hunk，applyAmbientBudget 仍旧塞整值；E2E 仅加 remaining 支）。
- 单元红：旧实现塞整值 30_000/1_000，新断言期望 remaining 19_000..20_500 / 耗尽 0 → 红（red-evidence：10022/10025，1 failed）。
- 行为红：remaining 支 E2E 旧实现 elapsed 8.758s（断言 <6 红），复现 issue 探针 8077ms。
- 绿 8b56f4cd4 实现 min；requested 支 E2E 在绿 commit 加入。
- 两条新 E2E 自跑确定性钉住 min 两支：remaining 支 2093/2100ms（≈2000 预算，requested 60000），requested 支 1590ms（≈1500 requested，默认 30s 预算）。断言含 Timeout headline、budget 2000 from @options、TimeoutExpired 摘录（矩阵第三行新表示）、done-after-kill + failure 摘要。

## 三、红线 ✔
- tests/tla/ 零触碰；builtins/tools.zig 零触碰（diff 0 行）。
- admission/permissions/parity_review_free_commands/catalog 零代码触碰（diff 中唯一 admission 字样是注释）。
- 摘录槽代码零改动（nested_output_excerpt/recordNestedCall 不在 diff）。
- 无新 CLI/settings/env；无个人路径（diff grep 空）。
- zig fmt 后提交。

## 四、机械核验（自跑，fx-pi1@0fe6c9170）
1. zig build test 全绿：独立 --cache-dir /tmp/t27r-cache 全量重跑，22/22 steps succeeded，10274/10281 passed（7 skipped），主二进制 10017 pass/2 skip/0 fail。
2. zig fmt --check src/ 退 0。
3. check-public-surface.sh 与 agents/compactor/indexer/recovery 四边界各退 0。
4. cli.test.ts：139 pass / 6 skip / 0 fail（稳定）。
5. codemode-admission.test.ts：**不稳定**——见阻塞发现 1。
6. 真机冒烟：FX_BENCH=1 ./zig-out/bin/fx help 退 0、stderr 0 字节。

## 五、发现

### 发现 1（阻塞，changes-requested）：预算边界 timeout/yield 竞争使既有第三行 E2E flaky
- 现象：既有测试「budget-killed long command leaves its shell snapshot tail in the failure body」（默认 30s 预算、无 requested、无限产输出命令）在本改动后约 33–50% 失败。
  - 自跑 tally：T-27 共 6 次 → 2 fail / 4 pass（首次全套 fail、复跑 pass、3 次循环 pass/fail/pass、二次全套 pass）。
  - 基线对照（fx-integrate@0323b5f35 同测试）：4 次全 pass。
  - 失败态：body 的摘录标记为 (run_command, failure, …) + state stopped + error TimeoutExpired；测试 split("(run_command, ok,") 取不到 → TypeError。
  - 成功态：摘录标记 (run_command, ok, …) + state running（yield 快照）。
- 根因：旧实现命令超时 = 整预算 30000，与默认 yield_time 30000 相等，yield 稳定胜出（running/ok）。本改动命令超时 = remaining = 30000 − ε（ε = 脚本起点到嵌套调用发起的 schema 注入/eval 启动耗时），**严格小于** yield 30000。managed execution 的 yield 循环（managed_execution.zig:615，foreground 每 10ms 轮询 elapsed>=yield）与命令 worker 的超时检查（command_runner.zig:1043，elapsed>=timeout）两线程竞争；timeout 阈值提前 ε 使 worker 有时先杀（stopped/failure），有时 yield 先返回（running/ok）→ 非确定。
- 影响：摘录槽代码虽零改动，但预算边界命令的可观测结局由确定 ok-running 变为 ok/failure 竞争，旧第三行测试断言 ok-running 故 flaky。实现报告自述 E2E 167 pass 0 fail 系单次幸免（yield 胜），未复跑暴露。
- 语义评判：新结局 failure-timeout 其实**更符合** ISSUE-28 目标（命令在预算处被杀，而非 yield 一个 running 快照把命令留活到脚本超时之后）；旧 ok-running 恰是 bug 表现。故修复方向正确，但旧测试断言编码了 bug 行为，二者矛盾须消解。
- 要求（任选其一，最小）：
  (a) 更新旧第三行 E2E 以接受新语义（断言 failure-timeout 摘录，或同时接受 ok-running/failure-timeout 两种标记并各自校验尾哨兵），使其不再依赖边界竞争结果；或
  (b) 消解竞争：让预算边界命令的 yield 与 timeout 不再以 ε 之差竞争（例如嵌套命令的 yield_time 取 min(yield, command_timeout)，使 yield 不晚于 timeout，结局确定），并保持直跑零变化。
  无论哪种，须复跑该测试 ≥5 次全绿留证，并在 impl-report 注明竞争根因与处置。

### 发现 2（非阻塞，观察）：compat 路径 effectiveCommandTimeout 与 bridge 新 ambient 语义潜在双重扣减
- effectiveCommandTimeout（tool_runtime.zig:1988，run_command 兼容后端用）按 ambient=整预算 设计：min(requested, ambient −| (now − ambient_started))。bridge 现把 ambient 改为 remaining（已扣一次），并经 454 orelse 保留 started 标记。若带 bridge 标记的调用进入 compat 路径，会再扣 (now − script_start) → 双重扣减。
- 今日不可达：codemode 嵌套 run_command 规范化为注册 shell（callRun 直接用 remaining，不经 effectiveCommandTimeout）；生产注册表无 executor_kind .run_command 工具（T-26 同源结论）。故无实际影响。
- 建议：在 effectiveCommandTimeout 或 bridge 注释标明「ambient 语义已为 remaining，compat 路径若未来接入 bridge 标记须避免双重扣减」，或开票跟踪。不阻塞。

### 发现 3（非阻塞，观察）：权限等待使嵌套命令可超脚本 deadline 达 W
- remaining 在 admission 前采样冻结，命令在等待 W 后启动并运行 remaining，故命令结束 ≈ deadline + W。这是用户拍板「权限等待不吃预算」的必然结果，契约已接受；脚本外层 sandbox deadline 仍约束后续新调用入口（host.zig:1057）。仅记录边界，无需改动。

## 六、结论
changes-requested。语义、红绿、红线、机械核验（除 codemode-admission 稳定性外）均通过。阻塞项唯一：发现 1 的预算边界竞争使既有第三行 E2E flaky（实测 ~33–50%，基线稳定），须消解竞争或同步更新旧测试并复跑留证。发现 2/3 为非阻塞观察，建议注释/开票跟踪。
