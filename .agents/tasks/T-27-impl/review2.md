# T-27-review2 复审报告 — 竞争消解（阻塞发现 1 处置）

- 评审者：fx-pi2（上轮 changes-requested 原作者，复审自己的发现是否被正确消解）。
- 评审对象：fx-pi1 分支 T-27-impl，fix 绿 **dc8600d6f**（红 ac740b2d5，报告 cd18c27f2），基于上轮所核 8b56f4cd4。
- 上轮评审：fx-pi2 分支 T-28-impl 的 .agents/tasks/T-27-impl/review.md（54d4203f1）。
- 复审方式：只核增量（8b56f4cd4 → dc8600d6f / cd18c27f2），上轮已 approve 部分不重复；自跑机械核验 + 第三行 E2E 复跑 6 次。

## Verdict: **approve**

阻塞发现 1 已正确消解：yield_waits_for_timeout 标志使预算边界命令结局确定为 stopped/TimeoutExpired，
竞争消失（第三行 E2E 自跑 6 次全绿，上轮 ~33–50% flake）。直跑零变化、tty/interact/stop 零触碰、
红线全守、机械核验全绿。发现 2 注释准确。min(yield, remaining) 钳制移除的简化成立。

## 一、发现 1 消解 ✔

### 机制
- StartCapturedInput 增 yield_waits_for_timeout: bool = false（managed_execution.zig:41）。
- yield 循环（:617 一带）：timeout_at_yield = 标志 ∧ timeout_ms 非 null ∧ timeout <= yield_time；
  break 条件追加 !timeout_at_yield。标志成立且 timeout<=yield 时，foreground 不按 yield 返回 running，
  继续轮询直到 worker 超时杀置 terminal（循环顶 isTerminal break）或 cancel → prepareSnapshot 返回
  stopped/TimeoutExpired。结局确定，竞争消解。
- callRun（shell.zig:694）：yield_waits_for_timeout = (ctx.command_timeout_started_ms != null)，
  仅 codemode 嵌套标记置位；直跑标记 null → false。

### 直跑零变化 ✔
- 标志默认 false 时 timeout_at_yield 恒 false，!false=true，break 条件与旧版逐字节等价。
  既有 yield 测试（captured managed execution yields one handle…，默认 false）仍绿。
- diff 仅 callRun 一处置位；tty/interact/stop 不经该 captured yield 循环，零触碰。

### 边界情形核 ✔
- timeout=0（预算耗尽）：0<=yield → 等待，worker 立即杀（elapsed>=0）→ stopped/TimeoutExpired，与耗尽语义一致。
- timeout>yield（长预算脚本首调用 remaining≈120000>30000）：timeout_at_yield=false → 按 yield 返回 running（命令尚未到预算），与旧行为一致，非边界无回归。
- yield_hold held（mcp bridge）：held=true 本就不 break，等待 worker 杀，结局同确定 failure，无新问题。
- 循环终止性：terminal（worker 杀）或 cancel 必达其一，timeout<=yield 时 worker 必在 timeout 杀 → 不死循环。

### min(yield, remaining) 钳制移除的简化 ✔
- 初版钳制 yield=min(yield,remaining) 会使 yield<=timeout 恒成立 → yield 先返回 running（与 flag 的 failure 结局相反）。
  实现者改用 flag 让 timeout 确定胜出（failure-timeout，符合 ISSUE-28 杀于预算的目标），钳制对结局冗余遂移除。
  等待条件 timeout<=yield 已覆盖边界，timeout>yield 走原 yield，无需钳制。简化成立，改动面更小。
  注：上轮选项 b 举例 min(yield,timeout) 是让 yield 确定胜（running）；实现者选 timeout 确定胜（failure），
  二者皆消解竞争，failure 更贴合 ISSUE-28 目标且与红 E2E 新断言一致，仲裁选项 b 已认可。

## 二、红绿链 ✔
- 红 ac740b2d5 仅第三行 E2E 断言更新（+8/-2：failure 标记 + state stopped + TimeoutExpired + 尾哨兵），
  不含 fix（managed_execution 无 yield_waits_for_timeout，grep 0）。先于绿 dc8600d6f（merge-base 确认）。
- 红证据 red-evidence-fix.txt：在 8b56f4cd4（无 fix）上复跑 6 次 → 2 fail/4 pass（~33%），
  失败体 (run_command, ok, 30002ms)+state running，坐实竞争，与上轮 tally 一致。
- 新单元竞争钉死：managed_execution「a timeout at or before the yield waits for the kill instead of
  racing a running snapshot」（timeout==yield==300，标志 true，断言非 running + TimeoutExpired）。自跑 OK。
- 绿后第三行 E2E 自跑 6 次全绿（tally：pass×6，30808/30170/30152/30167/30170/30163ms）。

## 三、发现 2 注释 ✔
- effectiveCommandTimeout 上方（tool_runtime.zig:1988）：标明 bridge ambient 已为 remaining（嵌套调用起点采样），
  compat 路径若带 bridge 标记须避免再减脚本 elapsed（双重扣减）；今日注册 shell 消费标记、不达此 fn。
- 核实准确：applyAmbientBudget 确塞 remaining；effectiveCommandTimeout 确再减 (now−ambient_started)；
  callRun 不调 effectiveCommandTimeout（grep 退出 1）。注释与实现一致。

## 四、机械核验（自跑，fx-pi1@cd18c27f2）
1. zig build test 全绿：独立 --cache-dir /tmp/t27r2-cache 全量重跑，22/22 steps succeeded，
   10275/10282 passed（7 skipped）；主二进制直接复跑 10018 pass/2 skip/0 fail，单元竞争钉死 OK。
2. 第三行 E2E 复跑 6 次全绿（见上 tally）。
3. codemode-admission.test.ts + cli.test.ts 全套：167 pass / 6 skip / 0 fail。
   min 两支仍绿：remaining 支 2125ms、requested 支 1637ms。
4. zig fmt --check src/ 退 0；check-public-surface.sh 退 0；agents/compactor/indexer/recovery 四边界各退 0。
5. 真机冒烟：FX_BENCH=1 ./zig-out/bin/fx help 退 0、stderr 0 字节。

## 五、红线 ✔
- tests/tla/ 零触碰（diff name-only 计数 0）；admission/permissions/parity_review_free_commands/catalog 零代码触碰。
- 摘录槽代码零改动（nested_output_excerpt/recordNestedCall 不在 src diff）；第三行 E2E 仅断言更新。
- 无新 CLI/settings/env；个人路径零入码（git grep T-27/T-28 任务文档与 fix 源文件退出 1）。
- 报告 commit cd18c27f2 自称 scrub 一处 personal-path literal：核 .agents/tasks/T-28-impl/review.md:71
  已改为「diff grep 个人 home 前缀为空」，不含个人 home 前缀字面量；check-public-surface 退 0。干净。
- zig fmt 后提交。

## 六、结论
approve。阻塞发现 1 的竞争由 yield_waits_for_timeout 标志确定性消解（结局 stopped/TimeoutExpired），
直跑逐字节不变、非边界嵌套无回归、钳制移除简化成立；红绿链真实（红 6 次 2 fail 留证、绿 6 次全绿）；
发现 2 注释准确；机械核验与红线全过。上轮两条非阻塞观察：发现 2 已补注释闭环，发现 3（权限等待 W 使
命令可超 deadline 达 W）为用户拍板语义的必然结果，无需改动。T-27 全链（8b56f4cd4 + dc8600d6f）可批准。
