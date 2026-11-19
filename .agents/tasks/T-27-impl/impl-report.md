# T-27-impl 实现报告 — codemode 嵌套命令预算 min(requested, remaining)

- 分支：T-27-impl（基线 integrate-issue29 HEAD 0323b5f35）
- 红 commit：cdc4b24f7（先于绿）；绿 commit：见 git log（本报告同 commit）
- Issue：issues/ISSUE-28.md 发现 A；语义按用户拍板 min(requested, remaining)，
  remaining = 脚本 deadline − 嵌套调用发起时刻（admission 之前采样，权限等待不吃命令预算）。

## 修法（最小，4 个源文件）

1. `src/tools/codemode/bridge.zig` `applyAmbientBudget`：不再塞整预算，改为
   `budget -| (now − ambient_started)`，在每次嵌套调用发起时采样 remaining；
   `command_timeout_started_ms` 仍传脚本起点，作为「脚本预算上下文」标记。
   同步重写 52-57 一带注释（issue 处置项 1 点名处）。
2. `src/core/tooling/tool_runtime.zig:454`：
   `request.command_timeout_started_ms orelse execution_ctx.command_timeout_started_ms`，
   不再用请求里的 null 覆盖 bridge 塞入的标记（请求显式带值时仍优先，续传语义不变）。
   同步更新 CodemodeHostState ambient 字段注释（issue 锚点 1340-1343，现 ~1382）。
3. `src/core/tooling/tool_dispatch.zig`：DispatchContext 增加
   `command_timeout_started_ms: ?i64 = null`（默认 null，既有默认值测试不受影响），
   typedDispatchContext 透传。这是注册 shell 路径能读到标记的唯一通道。
4. `src/tools/shell/shell.zig` `callRun`：startCaptured 的 timeout_ms 改为——
   有 started 标记且有 command_timeout_ms 时取 `min(requested, remaining)`
   （requested 缺省则直接用 remaining）；无标记保持原 requested-wins 直跑语义。
   超时仍由 managed execution 杀整树、仍是工具失败；tty/interact/stop 路径零触碰。

remaining=0 时命令立即 TimeoutExpired（预算耗尽语义）。摘录槽零改动：
TimeoutExpired 快照仍带 output_delta，覆盖矩阵第三行由新 E2E 断言钉住。
builtins/tools.zig 描述文案未动（23b 已修）。

## 红证据（.agents/tasks/T-27-impl/red-evidence.txt）

- 单元：`bridge caps nested commands with the script budget fields` 改为断言
  remaining（脚本 10s 前启动、预算 30s → 期望 19_000..20_500；耗尽情形期望 0）。
  旧实现塞整值 30_000/1_000，zig build test 红（10022/10025，1 failed）。
- 行为：新 E2E「a nested command with a large requested timeout dies at the
  remaining script budget」：@options 2000ms 脚本 + run_command sleep 8
  timeout_ms 60000。旧实现实测 elapsed 8.758s（断言 <6 红），复现 issue 探针 8077ms。

## 绿证据（逐条验收）

1. 红 cdc4b24f7 先于绿；zig build test 全绿。注：绿后首次全套跑报 1 failed
   （输出截断未留名），同一测试二进制随后完整复跑两次均 0 failed
   （10017 passed / 2 skipped），按 flake 处理并在此注明。
2. zig fmt --check src/ 退 0。
3. cd tests/e2e && FX_SOUND=0 bun test codemode-admission.test.ts cli.test.ts：
   167 pass / 6 skip / 0 fail。另跑 codemode-output/cancel：4 pass / 0 fail。
4. check-public-surface.sh 与 agents/compactor/indexer/recovery 四边界脚本各退 0。
5. 真机探针（新 E2E 驱动 ./zig-out/bin/fx 全链路，fake gateway 确定性复现）：
   - min 的 remaining 支：2000ms 脚本 + sleep 8 requested 60000 → 实测 2731ms
     （含启动），断言 1<elapsed<6 绿；失败体含 "(budget 2000ms, from @options)"
     与 '"error":"TimeoutExpired"'（摘录槽第三行）。
   - min 的 requested 支：默认 30s 脚本 + sleep 8 requested 1500 → 实测 1586ms，
     脚本正常完成（done-after-kill），嵌套记为 failure。
   - FX_BENCH=1 ./zig-out/bin/fx 退 0、stderr 0 字节。
6. 产物：红/绿 commit + 本报告 + red-evidence.txt。

## 偏差与边界

- DispatchContext 新增一个默认 null 字段是注册 shell 消费标记的必要通道；
  非 CLI 面/settings/环境变量，属内部契约。
- 直跑（非嵌套）语义零变化：无标记时 requested-wins 原样；既有 30s/5s 预算
  E2E（sleep 60 无 requested）仍绿，因调用发起≈脚本起点，remaining≈整预算。
- tests/tla/ 零触碰；admission/permissions/parity_review_free_commands/catalog
  零触碰；未触及 recovery 边界（无需 blocked）。
- 个人路径零入码；探针环境用隔离临时 HOME。
