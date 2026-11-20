# T-29-impl 实现报告 — ISSUE-26 文档轮（README/--help/描述文案与实现同步）

- 分支：T-29-impl（基线 integrate-issue29 HEAD a6b910d06）
- 红 commit：9e25b1a28（描述钉死测试先改，实测红）；绿 commit：描述+README+报告同 commit
- 纯文档+注释+描述文案轮，零执行语义变更（src 逻辑零触碰，只动描述字符串与测试断言）。

## 一、差距清单 7 项逐条核对（改前 → 改后 → 实现锚点）

1. 工具面列表过时
   - 改前：README「whitelisted built-in tool: glob_files, grep_files, read_file,
     run_command ... Everything else is invisible to the sandbox」（gate 开时为假）。
   - 改后：两态分述——gate 关四件套 + everything else invisible；gate 开
     （experimental.codemode_derived_surface，profile-only，默认关）九件套
     （+write_file/edit_file/web_fetch/ask_user_question/vision）+ run_script，
     run_command 映射 registered shell；嵌套仍走同一 admission。
   - 锚点：bridge.zig sandboxFace/derivedFace（:1299-1316，sandbox_reachable 八件
     + run_command + run_script）；bindings.zig tools 四件套（:23-28）；
     builtins/tools.zig sandbox_reachable=true 八处（glob/grep/read/write/edit/
     web_fetch/ask_user_question/vision）。
2. 无 experimental.codemode_derived_surface 键
   - 改前：README 只列 experimental.codemode。
   - 改后：README 工具面条目明写该键（profile-only，默认关）。
   - 锚点：settings_keys.zig:121 experimental children 含 codemode_derived_surface；
     fx config schema 实测输出三子键一致。
3. 无 run_script 原语
   - 改前：README 无。
   - 改后：新增条目——shell/python、fx temp file + 固定 python3 <path> argv 形态、
     CTX_FILE、model text 不成 interpreter option token、未知字段 admission 前拒绝。
   - 锚点：bridge.zig canonicalRunScript（:428-470 注释与 allowed_fields）、
     run_script_model_schema（:587-594）、RunScriptLanguage enum {:shell,.python}
     （:305）、run_script_max_ctx_file_bytes=1MiB（:316）。
4. 无目录预算与发现接口
   - 改前：README 无。
   - 改后：tools.list() 条目补 codemode_catalog_bytes 16KiB 默认、T0 四件恒列/T1
     mutation/T2 其余、omitted+hint；searchTools 评分+limit 默认 8；describeTool
     全 schema+did-you-mean。
   - 锚点：context_limits.zig:17/:32（16*1024）；catalog.zig tierOf（:33-43）、
     catalog_notice_floor_bytes；discovery.zig catalog_hint/catalog_budget_clause
     （:18-29）、default_search_limit=8（:9）、max_describe_candidates=5（:31）；
     codemode_tool.zig catalogBudgetFor（:277，仅 derived surface 开门）。
5. 无输出超限语义
   - 改前：README 无。
   - 改后：新增条目——1MiB 捕获帽、头尾保留+omitted 字节数、read_tool_result 回读、
     失败体 capture 标记、@options timeout 1000..120000 与 max_output_tokens
     4 bytes/token 钳到 1MiB。
   - 锚点：host.zig default_capture_buffer_bytes=1MiB（:27）、
     max_options_output_tokens=262144（:35）；codemode_tool.zig 失败体 capture
     标记（:80-96 appendCaptureCapMarker 一带）。
6. 无超时反馈语义
   - 改前：README 无。
   - 改后：新增条目——默认 30s 预算、嵌套 min(requested, remaining script budget)
     counted from its own start、Timeout headline 报 elapsed/budget/source/@options fix。
   - 锚点：host.zig default_timeout_ms=30000（:21）；codemode_tool.zig
     timeoutHeadline（:459-464）；bridge.zig applyAmbientBudget（remaining 采样，
     T-27）；shell.zig callRun min 分支 + managed_execution yield_waits_for_timeout
     （T-27-fix，边界确定 failure-timeout）。
7. store()/load() 未实现（ISSUE-13 open）
   - 核对：README 全文 grep store()/load() 计数 0，未把未实现写成已有。
   - 锚点：issues/ISSUE-13.md 状态 open；host.zig 无 store/load 全局绑定。

## 二、描述文案红绿（TDD，本轮新发现 T-27 引入）

- 红（9e25b1a28）：builtins/tools.zig 钉死测试改为——禁止旧句「capped at it from
  its own start」、要求新句「min(requested, remaining budget) from its own start」、
  长度上限 1168→1173 重钉。zig build test 实测红：
  'builtins.tools.test.codemode description states the nested command budget
  truthfully' failed（10026/10029，1 failed）。证据 red-evidence.txt。
- 绿：codemode_description 尾句改为「a nested run_command gets min(requested,
  remaining budget) from its own start」。新长度 1173，净词数 179 与改前持平
  （C4 不增长约束；上限按新文案重钉 1173 并在测试注释注明）。
  ISSUE-26 点名的 :743-744 旧注释（whole-budget 说法）已随红测试注释一并改写为
  T-27 min 语义；全仓 grep 无残留「capped at the whole budget from its own start」。
- zig build test 全绿（TEST_EXIT=0）。

## 三、--help 核对（settings_keys.zig:121 / --context-limit）

- experimental 组：fx config schema 实测三子键 codemode/codemode_derived_surface/rtk
  与 settings_keys.zig:121 一致，描述与实现相符，无需改。
- --context-limit：help 文案「Set name=bytes|off; repeatable」与实现一致；实测
  --context-limit=codemode_catalog_bytes=off 退 0、bogus_name 报 UnknownContextLimit，
  键集由 context_limits.zig Name enum 单一来源驱动（含 codemode_catalog_bytes），
  无枚举漂移，无需改。
- 结论：--help 面本轮零改动（核对一致，非新增键）。

## 四、手册 Docs 节

docs-section.md 已按 CONTRIBUTING「Changes to the manual」格式产出受影响页精确改动：
codemode 页（工具面两态/run_script/目录预算与发现/输出帽/超时含本轮 min 与边界确定结局）、
configure-fx/permissions（T-17 dash 数据词承诺，源 ISSUE-17-plan-v2 评审3 C1）、
mcp 页（T-18 遗留一句话，源 T-18-impl-report Docs obligation）。conductor 放入文档 PR ## Docs。

## 五、验收证据

1. 7 项逐条核对断言：见上节一（改前→改后→锚点）。
2. 描述红绿分 commit（红 9e25b1a28 先实测失败留证）；zig build test 全绿 TEST_EXIT=0。
3. zig fmt --check src/ 退 0；bash scripts/check-public-surface.sh 退 0。
4. fx help 退 0 stderr 0 字节（/tmp/t29-help.txt）；fx config schema experimental
   三子键核对留证（/tmp/t29-schema.txt）；--context-limit 有效/无效键实测；
   FX_BENCH=1 ./zig-out/bin/fx 退 0 stderr 0 字节。
5. 产物：红/绿 commit + impl-report.md + docs-section.md + red-evidence.txt。

## 六、红线自查

- 零执行语义变更：只动 README.md、codemode_description 字符串、钉死测试断言与注释；
  src 逻辑零触碰。tests/tla/、admission/permissions/catalog 零触碰；无新 CLI/settings/env。
- 个人路径零入码；无 emoji；文档不用 -- 作破折号（README grep 核验）。
- fork 介绍段与 rtk 节未动；未新增 README 章节。zig fmt 后提交。
