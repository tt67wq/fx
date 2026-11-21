# T-30-impl 实现报告 — ISSUE-27 P0 压缩前用户侧 nudge（零 token 成本）

- 实现者：fx-pi2。分支 T-30-impl，基线 integrate-issue29 HEAD f1081e95f。
- 红 commit：166f39534（先于绿）；绿 commit：见 git log（本报告同 commit）。
- 用户拍板决策点 1：nudge 只提示用户，不进模型上下文，零 token 成本。

## 设计选择

1. 阈值：nudge_at = compact_at_tokens * 3 / 4（写死常量 context_nudge_threshold_multiplier=3 /
   divisor=4，不新增 settings 键/CLI 面/环境变量）。compact_at_tokens 来自既有
   compactionSize → compactor.Size.of(capabilities, auto_compact_percent)。
   例：usable 16000、percent 80 → compact_at 12800、nudge_at 9600。
2. 触发点：orchestrator processQueuedPromptLoop 在 size 计算与 wants_compaction
   判定之后、压缩分支之前调用 maybeNudgeContextPressure（orchestrator.zig:7672）。
   条件：!context_nudge_sent ∧ !wants_compaction ∧ !overflow_pending ∧
   has_new_compactable_context ∧ compact_at_tokens 非 null 非 0 ∧
   request_tokens >= nudge_at。已 due / overflow / 无新可压缩 context 不发（直接走压缩/恢复）。
3. 通道：deps.push_interactive_notice（SemanticNotice topic="context" tone=.information）。
   严禁进 request_data.messages / append_messages / 系统提示——nudge 文本只经 interactive
   通道渲染给用户，零模型 token。push_interactive_notice 为 null 的宿主（如纯 ask）静默跳过。
4. 一次性 + 重新武装：Agent 增 context_nudge_sent: bool = false（plain value state，无分配）。
   触发后置 true。两条压缩成功路径复位：
   - 自动/overflow：loop compacted 成功块（orchestrator.zig:7816，agent.request_token_calibration=null 旁）。
   - 手动 /compact：app_agent_runtime.zig:1310（compactWithActivity result != null 分支）。
   二者覆盖 compactContext 的全部生产调用方（loop 7705 + app 1290），手动/自动/overflow 均重新武装。
5. 文案（英文，无 emoji，无 -- 破折号）：
   "Context is at {N}% of the auto-compact threshold. Run /compact to summarize older turns
   before the automatic compaction." N = request_tokens*100/compact_at_tokens（占自动压缩阈值百分比）。
6. 会话恢复语义：context_nudge_sent 是 Agent 的 plain value 字段，默认 false。会话恢复重建
   Agent 时该字段随 Agent 初始化默认 false（重新武装）——恢复后的会话首次爬升阈值会再次提示，
   合理（恢复即新的武装周期）。不持久化该位（无跨会话状态需求）。

## 红绿（TDD）

- 红（166f39534）：gateway_flow.zig 增 4 测试 + t30 夹具（fixture model usable 16000、
  compact_at 12800、nudge_at 9600；history block 36000 chars≈9179 tokens 低于 nudge、
  40000≈10179 nudge 区、52000≈13179 due）。先实测红：
  - stays silent below three quarters：0 通知（负例，无实现也绿，钉死下方静默）。
  - fires once crossing three quarters with /compact guidance：红 expected 1 found 0。
  - does not repeat while staying above the threshold：红 expected 1 found 0。
  - re-arms after a successful compaction：红 expected 1 found 0。
  zig build test EXIT=1，10027/10033（4 failed，其中 3 为 nudge 红、1 为无关 command_runner
  超时 flake）。证据 red-evidence.txt。
- 绿：maybeNudgeContextPressure + Agent.context_nudge_sent + 两处重新武装。4 测试全绿。
  零 token 成本断言：fires-once 测试遍历 gateway.request_bodies，断言不含 "/compact" 与 nudge body。

## 验收证据

1. 红先于绿（166f39534 → 绿）；zig build test 全绿：独立 --cache-dir /tmp/t30-cache2 全量重跑，
   22/22 steps succeeded，10025/10027 passed（2 skipped，0 failed）。主二进制直接复跑
   4 条 nudge 测试 OK（10025 pass/2 skip/0 fail）。
2. zig fmt --check src/ 退 0；check-public-surface.sh 退 0；四边界脚本（尤其 compactor）各退 0。
3. 零 token 成本测试绿（nudge 不进模型消息流，request_bodies 不含 nudge 文本）。
4. 真机验证（tmux + fake gateway，隔离 HOME，FX_AUTO_COMPACT_PERCENT=80，模型 context_window
   32000/max_tokens 16000）：粘贴 24000 字符消息（request≈11602 tokens，nudge 区），pane 出现
   "i context: Context is at 90% of the auto-compact threshold. Run /compact to summarize older
   turns before the automatic compaction."，恰一次（NUDGE_COUNT=1）；trace 坐实
   sent=false→true、wants=false、at=12800、req=11602。/compact 后重新武装由单元 re-arms 测试
   确定性钉死（3 prompt 全链：nudge#1 → 压缩 → nudge#2，共 2 条）。真机 /compact 后再粘贴的
   re-arm 观察受 fake gateway 响应序列与粘贴时序干扰（req=5 的空续传），不作为 re-arm 判据；
   re-arm 以单元全链测试为准。FX_BENCH=1 ./zig-out/bin/fx help 退 0、stderr 0 字节。
5. 产物：红/绿 commit + 本报告 + red-evidence.txt。

## 红线自查

- compactor 边界：只经 compactor.zig front door 与既有 compactionSize/Size API；nudge 逻辑在
  orchestrator 宿主侧，未 import compactor 内部文件，未改 compactor 内部。check-compactor-boundary 退 0。
- 不动 window.zig 选择逻辑、压缩语义、recovery/tests/tla；admission/permissions/catalog 零触碰。
- 不新增 settings 键/CLI 面/环境变量（比例常量写死；FX_AUTO_COMPACT_PERCENT 为既有 env，仅真机复现用）。
- 个人路径零入码（隔离临时 HOME）；无 emoji；文案无 -- 破折号。
- zig fmt 后提交。diff 仅 agent.zig（+4 字段）、orchestrator.zig（+41 nudge fn+触发+重新武装）、
  app_agent_runtime.zig（+7/-1 手动重新武装）、gateway_flow.zig（测试）。
