# ISSUE-27 — 模型自主的上下文压缩：nudge 提示 + 模型可调用的 compress 工具（参考 billion-context 原理）

- **状态**: open（P0/P1 已落地，P3 论证关单，P2 待决策）
- **发现时间**: 2026-11-18
- **来源**: 调研 https://github.com/ranxianglei/billion-context 后评估移植可行性，与 fx 现有 compactor 逐点对照
- **工作量**: P0 小 / P1 中 / P2 大 / P3 待论证（见分阶段计划）
- **关联模块**: src/core/compactor/（压缩核心）、src/core/agent/runtime/orchestrator.zig（触发点）、src/builtins/tools.zig + src/tools/session/read_tool_result.zig（模型侧工具）、src/core/permissions/（权限）

## 背景：billion-context 是什么、原理是什么

billion-context（MIT，npm 包名同）是一个 agent 与模型 API 之间的上下文压缩代理，支持 25+ 客户端。核心做法：

1. **注入四个上下文管理工具**：compress（把一段消息范围折叠成摘要）、decompress（展开已折叠范围）、search_context（搜索已折叠摘要）、acp_status（上下文用量概览）。
2. **模型驱动**：何时压、压哪段，由模型自己通过工具调用决定；不是宿主在固定阈值硬截断。摘要文本由模型写，压缩库（acp-kernel）只编排状态：何时、何范围、块状态、代际合并、还原、搜索。库本身永不调用模型。
3. **可逆 + 增量**：折叠按小区间进行，已折叠块不删除（无 GC），可随时展开；多级 LSM 式分层（tier1/2/3，young→old 晋升合并）。
4. **前缀缓存友好**：折叠保持发往 provider 的请求前缀稳定，宣称 96–99% prefix-cache 命中率。

仓库结构参考：/tmp/onboarding/billion-context（本地克隆，含 starter CLAUDE.md）；其 kernel/DESIGN.md 是压缩核心的权威契约，值得读。

## fx 现状详解（接手前必读）

fx 已有自己的压缩器 src/core/compactor/，与 billion-context 是同构设计（模型写摘要、宿主编排、存储由调用方注入），但触发方式与可逆性不同。

### 模块分工（src/core/compactor/）

- compactor.zig：front door。唯一对外入口是 compact(alloc, Request) 返回 ?Result。模块边界受 scripts/check-compactor-boundary.sh 保护：外部只能 import compactor.zig，compactor 内部只 import 共享基础件与模型配置；模型调用方（ModelCaller）、记录存储（records.Store）、会话的消息投影（append_messages）全部由调用方注入。
- window.zig：选哪段压。最新若干 turns 原样保留（max_kept_turns=4，kept_percent=40），其余旧 turns 压掉；带 token 估算与 provider 计数校正（Size.correction）。
- summarize.zig：构造摘要请求。保留每条 user 消息与最终回复原文，给每个 turn（M1, M2, ...）和 tool call（T1, T2, ...）一个句柄。
- ledger.zig / model.zig：向会话的模型（最低 reasoning，带 fallback 模型）请求摘要并读回。
- lint.zig：把摘要里的每条记录与实际保存的 turns/tool calls 核对，确认不了的打标记（billion-context 没有这个校验，fx 更强）。
- records.zig：M/T/L 记录存盘（vtable 注入，存于会话的 tool-results 目录，文件名 compacted-M12.txt / compacted-T12.txt / compacted-L1.txt）+ 搜索。搜索是纯词匹配 + BM25（罕见词权重高、词序邻近加分），入口 compactor.search()。
- checkpoint.zig：压缩点的持久格式；settings.zig：阈值设置（auto_compact_percent，默认 compactor.default_percent）。

### 触发路径（都在 src/core/agent/runtime/orchestrator.zig）

压缩只有宿主触发，三个入口最终都走 compactContext（orchestrator.zig:6366 一带）：
1. 自动：auto_compact_percent 阈值（默认字段 src/core/agent/runtime/config.zig:43）
2. 手动：/compact 斜杠命令
3. 恢复：provider 拒绝 overflow 后的恢复路径

产物：checkpoint（替换旧 turns 进入会话历史）+ 模型在 checkpoint 位置读到的摘要文本（model_text，内含 M/T 句柄引用）+ retained_history。

### 模型侧已有的能力（重要，修正早期判断）

src/builtins/tools.zig 的 read_tool_result（实现 src/tools/session/read_tool_result.zig）已是模型可见工具：
- handle="T12"（或 M12 等）+ 可选 start_byte/byte_count 或 query：读回压缩保存的记录内容。
- search=[最多 compactor.max_search_phrases 个词组]：搜索所有压缩保存的 turns、tool calls、早期压缩（L 记录），无需 handle。

即 decompress / search_context 在 fx 里已基本存在。语义差别：billion-context 把原文塞回消息流，fx 以工具结果形式返回给模型当前 turn——对模型的使用目的基本等价。

## 差距分析（修正后）

真正缺的只有三点：

1. **compress 不由模型主导**：模型不能自己决定"现在把 M3–M15 压掉"。只能等宿主到阈值一次性压掉一大块（window.zig 的选择逻辑对模型不可见、不可控）。这是 billion-context 的核心增量。
2. **没有 growth-based nudge**：阈值是硬触发（到 percent 才压）。此前没有"上下文已长到 X%，建议压缩"的渐进提示，模型和用户都只能在快爆时才感知。
3. **前缀缓存不在设计目标内**：fx 压缩一次替换大块前缀全变。是否值得做增量小步折叠（保 provider cache），取决于"数周不中断单 session"的真实需求强度——多数 fx session 到不了那个量级，需先论证。

不需要重做的：模型写摘要（已有）、记录存储与搜索（已有）、多代层级（L 记录已让后一次压缩折叠前次摘要，两层够用）、lint 校验（fx 独有）。

## 分阶段计划

### P0 · 压缩前 nudge 提示（小）— 已落地（2026-11-20）

- 目标：上下文达到阈值前（如 auto_compact_percent 的 70~80% 处）注入一次提示，告知模型与用户"对话已长，可 /compact"。
- 动哪：compactor/settings.zig + window.zig（判断点）；注入方式需先定（决策点 1）。
- 验收：长会话中阈值前能看到提示；不压时不产生额外 token 开销（一次提示文本可控）。

### P1 · 让模型用好已有检索能力（中）— 已落地（2026-11-21）

- 目标：确认 read_tool_result 的 search/handle 路径在默认模型面上的可达性与描述清晰度；必要时调描述文案让模型知道"压缩后可用 T12 句柄找回细节"；补齐读 L 记录（早期整份摘要）的语义。
- 动哪：src/builtins/tools.zig（read_tool_result 描述）、src/tools/session/read_tool_result.zig（按需）、可能涉及模型系统提示中关于压缩行为的说明。
- 验收：构造"压缩后追问早期细节"的场景，模型能自主用 read_tool_result 找回；e2e 可测。

### P2 · 模型可调用的 compress 工具（大，本 issue 核心）

- 目标：模型可指定范围（句柄区间或消息区间）请求折叠；宿主执行实际压缩（复用 compactor front door 的 summarize/lint/records 管线），折叠结果以 checkpoint 形式落盘。
- 难点：
  - 范围语法与边界保护：system 指令、工具定义、最近 N turns 不可折；保留 user 消息与最终回复的语义（summarize.zig 现有行为）在"模型选范围"下是否仍成立需要设计。
  - 与 window.zig 的关系：模型选的范围与阈值触发的窗口选择可能冲突，需要优先级规则（决策点 2）。
  - guardrails：防模型过勤调用（每次压缩都是一次模型请求，有成本）与过懒；参考 billion-context 的 nudge 频率控制。
  - 权限：新工具必须接入 src/core/permissions/permissions.zig；压缩是会话状态变更，是否 requires_approval 需要产品判断（决策点 3）。
- 验收：模型在长会话中自主压缩且 lint 通过；auto 阈值兜底仍工作；压缩后 read_tool_result 可找回。

### P3 · 前缀缓存亲和 / 增量小步折叠（已论证关单，2026-11-23）

- 先做真实数据论证（决策点 4）：fx 有无月级单 session 场景？provider cache TTL 下收益多少？论证不过就关单不做。

## 设计决策点（开工前先定）

1. nudge 注入面：注入到模型系统侧（模型可见、有 token 成本）还是只提示用户（零成本但模型不知道）？
2. 模型选范围 vs window.zig 自动窗口：冲突时谁赢，还是模型工具只在阈值前可用？
3. compress 工具的权限类别：模型自发压缩要不要用户确认？（压缩不可逆地改变会话历史形态，但记录文件保留了原文）
4. P3 是否立项：需要月级 session 的真实需求证据。

## fx 项目纪律清单（每阶段都要遵守）

- compactor 只经 front door（compactor.zig）交互；scripts/check-compactor-boundary.sh 在 CI 强制。
- 新工具契约放 src/core/tooling/tool_specs.zig 或 src/builtins/tools.zig，实现放 src/tools/，不许散。
- 权限必须接入 permissions.zig，不许绕过。
- 按 AGENTS.md "Adding a Feature" 六问补全：contract、持久化、文本+JSON、docs、E2E 的 corpus.json 分类与 ci-shard-weights.json 权重。
- 报告"完成"前：构建通过、聚焦测试通过、用 ./zig-out/bin/fx 跑真实交互验证。
- 若新增斜杠命令，走 Adding a Command 流程（command_specs.zig + builtins/commands.zig + cli_surface.zig，需 fx-cli-shape 技能评审）。

## 参考

- billion-context 本地克隆：/tmp/onboarding/billion-context（kernel/DESIGN.md、docs/technical-notes.md）
- fx compactor 文档头：src/core/compactor/compactor.zig:1-23
- 触发点：src/core/agent/runtime/orchestrator.zig:6366 一带
- 模型侧检索：src/builtins/tools.zig 的 read_tool_result、src/tools/session/read_tool_result.zig

## P0 落地备注（2026-11-20）

T-30-impl：红 166f39534 → 绿 b79e2f7b7，review approve c3f3ec21c。用户拍板决策点 1：仅用户侧、零 token 成本。nudge_at = compact_at_tokens * 3/4（常量写死，无新 settings/CLI/env）；push_interactive_notice 通道，测试钉死模型请求体不含 nudge 文本；每武装周期一次，自动/overflow/手动 /compact 成功后重新武装；恢复即新武装周期。整合于 integrate-issue29（HEAD 7275e8a08），PR tt67wq/fx#6。真机 tmux+fake gateway 观察恰一次（90%，trace 坐实）。compactor 边界零触碰。

## P1 落地备注（2026-11-21）

T-31-impl：红 02c4a912d → 绿 f1d8e72d3，review approve 872fa85c7。核查结论：默认面可达性已成立（registry 16 工具）、search 提示原描述已有、系统提示无缺口不动；真缺口为 M/T/L 句柄词汇，新描述 42 词持平补齐（T12 saved tool call / M12 turn / L1 whole earlier compaction / search 无 handle 跨全部记录）。全链测试两次自动压缩后真实 read_tool_result 四支（T1/search/L1/M1）各钉早期细节哨兵；byte-exact 契约哈希双平台重钉（linux 值临时强确实测后还原干净，评审独立复算一致）。模型自主性属 eval 领域未建（诚实边界）。整合于 integrate-issue29（HEAD 5f4856177），PR tt67wq/fx#6。合并树首跑 command_runner 超时 flake 一次，复跑全绿（既有已知 flake 家族）。

## P3 关单备注（2026-11-23，T-27p3 数据论证）

P3 关单（T-27p3 数据论证，2026-11-23）：130 个真实 session（2026-11-06 至 11-23）中无月级会话，最长跨度 2.71 天，最长连续活跃段 2.36 天仅 1 例。按 5min 保守 TTL 切分，98.6% 的 input 重付量（375.6M / 381.0M token）落在缓存暖窗内，冷重付仅 70 次调用 5.33M token（1.4%），前缀缓存亲和的增量收益上界约总输入开销 1.3%。显式缓存断点、稳定前缀跨 worktree 复用与 Claude 缓存保暖 ping 均已落地（PromptCache.tla / CacheWarming.tla）；auto 阈值压缩加 P0/P1 已覆盖实际上下文压力（130 session 仅 3 次压缩）。增量小步折叠在暖档缓存读价下收益边际，且引入摘要成本与信息丢失风险。论证报告与可复跑脚本见 fx-pi1 工作树 .agents/tasks/T-27p3/（本地）。重开条件：出现 >7 天活跃段且冷重付占比 >10% 的样本，或确证主力模型上游无 prompt cache。

conductor 复核：analyze.py 只读复跑 exit 0，结论字段全稳定（月级 0、>7d 0、冷重付 70 次/1.4% 不变；暖窗量随 live store 漂移属预期）；零产品代码改动，git 干净。数据边界：观测窗 17 天，结论限定为现有用法无月级需求证据，非全称否定；缓存命中无实测（上游不回传 cache_read/write），暖冷为 TTL 理论切分。
