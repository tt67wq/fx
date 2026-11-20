# T-30-review — ISSUE-27 P0 压缩前用户侧 nudge 评审

- 评审者：fx-pi1（未参与 T-30-impl 实现，作者独立性成立）
- 所核 commit：红 166f39534ed79c8b969df4f2d58f9e011f338bc0，绿 b79e2f7b7cab1b5c481b6b18098027d04700c406（fx-pi2 分支 T-30-impl，基线 integrate-issue29@f1081e95f）
- verdict：**approve**

## 1. 零 token 成本（最高优先）— 成立

- nudge 文本唯一出口是 deps.push_interactive_notice（SemanticNotice topic=context
  tone=.information）。独立追踪生产链路：app_callbacks.agentPushInteractiveNotice
  (:1306) → app_worker_runtime.pushSemanticNotice (:698) → pushEvent(.semantic_notice)
  → UI 渲染（approval_screen/full_transcript/transcript store）。该事件不进
  request_data.messages、append_messages 投影、系统提示或 checkpoint model_text：
  grep semantic_notice 于 session/record/checkpoint 路径为空，orchestrator 内无
  notice→messages/projection/model_text 的桥接。push_interactive_notice 为 null 的
  宿主（纯 ask）静默跳过（:6378 orelse return）。
- fires-once 测试的零 token 断言遍历 gateway.request_bodies，断言不含 /compact 与
  nudge body。FakeGateway.stream（support.zig:278-288）对**每一次**模型请求（含
  prepared_request_body 续传与重试重建）都 append 实际发送的 payload，故 request_bodies
  覆盖所有模型请求路径，断言真覆盖。re-arms 测试的压缩 summary 请求同样经此记录。

## 2. 阈值与触发条件 — 成立

- nudge_at = at / 4 * 3（先除后乘，整数运算）。at 为 usize 且非 0（:6373 at==0 return），
  无除零；先除后乘避免 at*3 溢出。request*100/at 的 percent 在 request 极大时理论上
  可溢出，但 request 达该量级前早已 due/overflow 被前置条件挡下（wants_compaction/
  overflow_pending return），实际不可达；与既有 window.percentOf 同风格，非本轮新增风险。
- 条件链独立核对：!sent ∧ !wants_compaction ∧ !overflow_pending ∧
  has_new_compactable_context ∧ compact_at 非 null 非 0 ∧ request 非 null ∧
  request >= nudge_at。边界：request 恰等于 nudge_at 触发（>=，与 due 的 >= 一致）；
  compact_at=0 return；usable=null → compactAtTokens 返回 null（window.zig:144）→
  compact_at null return。due() 用 request>=at，nudge 用 request>=at/4*3，nudge 区
  [9600,12800) 与 due 区 [12800,∞) 无缝且不重叠。

## 3. 一次性 + 重新武装完备性 — 成立

- Agent.context_nudge_sent: bool = false（plain value，无分配）。触发置 true（:6384）。
- compactContext 生产调用方独立 grep 恰两处：loop orchestrator:7744（自动/overflow）
  与 app_agent_runtime:1290（手动 /compact）。第三处 orchestrator:6850 在 test 块内。
  两条生产成功路径均复位：loop 在 if(compacted)|outcome| 成功块 :7816（与
  request_token_calibration=null 同处）；app 在 result!=null 分支 :1310。覆盖完整。
- 失败压缩不复位：loop catch 分支与 app result==null（no_op）均不动 flag——合理，
  压缩未成功则上下文未减，nudge 仍应视为已发，避免重复打扰。
- 恢复语义：字段随 Agent 初始化默认 false，恢复重建 Agent 即重新武装，报告自述成立
  （不持久化该位，无跨会话状态需求）。

## 4. 红绿链 — 成立（评审者独立复跑红）

- 独立 git worktree 检出 166f39534 跑 zig build test：三条行为测试实测
  expected 1 found 0 红（fires-once / does-not-repeat / re-arms），与 red-evidence 一致。
- 负例 stays-silent 无实现也绿（0 通知），red-evidence 如实注明「passes trivially ...
  pins the negative case」。零 token 断言在红 commit 的状态：fires-once 测试在红期于
  expectEqual(1, notices) 处先失败，零 token 循环未及执行——但零 token 是结构性保证
  （nudge 只走 interactive 通道），绿后该断言真跑且绿，诚实。
- 红期第 4 个失败 command_runner 超时 flake 与本改动无关，red-evidence 已注明（评审者
  红复跑此次未现该 flake，3 failed 纯 nudge）。绿 b79e2f7b7 四测试全绿。

## 5. compactor 边界 — 成立

- nudge 逻辑全在 orchestrator 宿主侧 maybeNudgeContextPressure，只读 compactor.Size
  （front door compactor.zig:41 = window.Size 的公开别名）的 compact_at_tokens/
  request_tokens 公开字段，未 import compactor 内部文件。diff 唯一新增 @import 是测试
  的 ../agent.zig。check-compactor-boundary.sh 自跑退 0。

## 6. 机械核验（评审者自跑，fx-pi2 checkout）

1. zig build test：主测试二进制完整跑 10025 passed / 2 skipped / 0 failed，四条 nudge
   测试逐条 OK（含 re-arms 3 prompt 全链）。
2. zig fmt --check src/：FMT=0。
3. check-public-surface.sh SURFACE=0；agents/compactor/indexer/recovery 四边界各 0。
4. FX_BENCH=1 ./zig-out/bin/fx help：SMOKE=0，stderr 0 字节。

## 7. 红线核对

- diff 仅 agent.zig(+4 字段)、orchestrator.zig(+41)、app_agent_runtime.zig(+7/-1)、
  gateway_flow.zig(测试) + 文档。window.zig/压缩语义/recovery/tests/tla/admission/
  permissions/catalog 零触碰（name-only grep 计数 0）。
- 无新 settings/CLI/env（比例常量 multiplier=3/divisor=4 写死；FX_AUTO_COMPACT_PERCENT
  为既有 env 仅真机复现用）。文案纯 ASCII 无 emoji 无 -- 破折号（脚本逐字符核验）。
- 无个人路径（真机用隔离临时 HOME）。

## 8. 真机证据复核 — 取舍诚实

- 报告称 tmux+fake gateway 观察到恰一次 nudge（90%，trace sent=false→true、wants=false、
  at=12800、req=11602），与 fixture 阈值算术一致（11602/12800≈90%）。
- re-arm 以单元全链测试为判据、真机 re-arm 受 fake gateway 响应序列与粘贴时序干扰
  （req=5 空续传）不作判据——该取舍诚实且合理。单元 re-arms 测试独立核对真覆盖 3 prompt
  全链：同一 Agent 实例跨三次 processAgentPrompt（t30RunOnAgent），prompt1 nudge 区→
  nudge#1、prompt2 due 区→真 compactContext（gateway2 >=2 请求含 summary）→复位、
  prompt3 nudge 区→nudge#2，断言 notices==2。flag 跨 prompt 持久于同一 Agent，确为全链。

## 备注（非阻塞）

- percent = request*100/at 在极端 request 下的理论溢出被前置 due/overflow 条件挡下，
  实际不可达；若未来条件链调整需留意，建议保持先除后乘风格（非本轮要求）。
- nudge 文案为英文，与仓库现有 notice 文案一致；无 emoji/破折号问题。
