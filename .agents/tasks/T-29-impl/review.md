# T-29-review 评审报告 — ISSUE-26 文档轮（README / 描述文案 / Docs 节）

- 评审者：fx-pi2（未参与实现，作者独立）。
- 评审对象：fx-pi1 分支 T-29-impl，绿 **967946eac**（红 9e25b1a28，产物 20a77b568），基线 integrate-issue29@a6b910d06。
- 契约：.agents/tasks/T-29-impl/task.md；报告/Docs 节/红证据：同目录。
- 评审方式：README 逐句对实现锚点 + 描述文案红绿核 + --help 独立验证 + Docs 节对照 T-17/T-18 源承诺 + 自跑机械核验。

## Verdict: **approve**

文档轮每句陈述为实现真（逐句锚点核过，含一处需澄清的 head+tail 语义，见下），store()/load() 零出现，
描述文案红绿真实且字数不增长，--help 零改动结论独立验证成立，Docs 节三页齐全且 T-17/T-18 承诺与源一致，
红线全守，机械核验全绿。

## 一、README 逐句对锚（每条实现真）

1. 两态工具面 ✔：gate 关四件套（bindings.zig:23-28 glob/grep/read/run_command）；gate 开
   derivedFace（bridge.zig:1303）= sandbox_reachable 八件（builtins/tools.zig glob/grep/read/write/edit/web_fetch/ask_user_question/vision）+ run_command + run_script。
   README「四件套 + write/edit/web_fetch/ask_user_question/vision + run_script」与实现一致（run_command 计入四件套）。
   experimental.codemode_derived_surface profile-only 默认关（config_runtime.zig:217 orelse false）。
2. run_command→shell 映射 ✔：registeredName（bridge.zig:1284-1287）。
3. 权限同检 ✔：bridge.call requestPermissionOutcome（bridge.zig:152），每嵌套调用走同一 admission。
4. run_script ✔：RunScriptLanguage enum {shell,python}（bridge.zig:305）；python3 <quoted path> 固定 argv（:470 一带，code 入 fx temp file，model text 不成 interpreter option token）；shell 转发命令行；CTX_FILE workspace file 拷贝（run_script_max_ctx_file_bytes=1MiB :316）；未知字段 admission 前拒绝（allowed_fields :451，canonicalRunScript 先于 requestPermissionOutcome）。
5. 目录预算与发现 ✔：codemode_catalog_bytes 16KiB 默认（context_limits.zig:32）；tierOf T0 四件恒列/T1 write+edit/T2 其余（catalog.zig:33-43）；omitted+hint（catalog.zig Omitted、discovery.zig catalog_hint/budget_clause observed/effective/source :28）；searchTools limit 默认 8（discovery.zig:9）；describeTool 全 {name,description,parameters} schema（discovery.zig:21）+ did-you-mean 最多 5（max_describe_candidates=5 :32）。
6. 输出帽 ✔（含澄清）：1MiB 捕获帽（host.zig:27）；@options max_output_tokens 4 bytes/token 钳到 1MiB、硬帽 262144（host.zig:35、codemode_tool effectiveScriptOptions）；失败体 capture 标记（appendCaptureCapMarker）。
   - 澄清「text and console keep the head and tail」：host 捕获缓冲 appendCapped（host.zig:1142）超限只留 head + 计丢弃字节；head+tail 保留发生在模型可见层——成功结果经 result_store.prepareManaged 外置，preview=previewText 走 writeHeadTailOmittedBounded（result_store.zig:641-644，头尾各半+omitted）；失败体 partial 亦走 writeHeadTailOmittedBounded（codemode_tool.zig:104）。故模型读到的预览确为 head+tail+omitted，README 陈述在模型可见层为真。全文（捕获帽内）落盘可经 read_tool_result 回读。该句沿自基线描述（非 T-29 新引入），T-29 同步入 README，语义一致。
7. @options ✔：timeout 1000..120000（host.zig:30/32、codemode_tool:990）；首非空行 JSON（codemode_tool:47）。
8. 超时 ✔：默认 30s（host.zig:21）；嵌套 min(requested, remaining script budget) counted from its own start（T-27 callRun min 分支 + applyAmbientBudget remaining 采样，已上轮核）；timeoutHeadline 报 elapsed/budget/source(default|@options)/@options fix（codemode_tool.zig:459-464）。
9. store()/load() 零出现 ✔：README 与 docs-section grep store()/load() 退出 1；ISSUE-13 状态 open；host.zig 无 store/load 全局绑定。未把未实现写成已有。
10. fork 介绍段与 rtk 节未动 ✔；README 无新增 ## 章节（diff grep ^[+-]## 退出 1）。

## 二、描述文案红绿 ✔
- 红 9e25b1a28 仅测试断言+注释改动（描述仍旧句 capped at it from its own start，grep 计数 3=描述+2注释）；
  断言改为禁旧句、要求新句 min(requested, remaining budget) from its own start、上限 1168→1173。
  红证据 red-evidence.txt：zig build test 10026/10029，1 failed（builtins.tools.test.codemode description states the nested command budget truthfully）。先于绿（merge-base 确认）。
- 绿 967946eac 描述尾句改 min 语义。实测长度 1173 字节、179 词；基线 1151 字节、179 词 → 净词数持平（C4 不增长成立），字节上限按新文案重钉 1173（<=1173 恰好成立）。
- 新句与 T-27 实现一致（min(requested,remaining)，命令自身超时从自身起点计）。全仓无残留 whole-budget 描述句（仅测试禁句 pin 与注释引用）。
- 自跑：zig build test 全绿；主二进制直接复跑该 pin 测试 OK（10021 pass/2 skip/0 fail）。

## 三、--help 零改动独立验证 ✔
- settings_keys.zig:121 experimental children = codemode/codemode_derived_surface/rtk，child_descriptions 与实现相符；config_runtime.zig:1884-1892 解析三子键一致。
- --context-limit 键集由 context_limits.Name enum 单一来源驱动（parse 遍历 enum 字段，含 codemode_catalog_bytes :17），无枚举漂移；parseOverride 接受 name=bytes|off。
- diff name-only 不含 settings_keys.zig/commands.zig/cli_surface.zig/context_limits.zig → --help 面本轮零改动。worker「核对一致无需改」结论独立验证成立。

## 四、Docs 节格式与三页 ✔
- 按 CONTRIBUTING「Changes to the manual」格式：页 URL + 节 + 精确增/改/删原文。
- codemode 页：工具面两态/run_script（CTX_FILE 1MiB、timeout 钳 1000..120000）/目录预算与发现（T0/T1/T2、omitted+hint observed/effective/source、searchTools limit 8、describeTool 5 did-you-mean）/输出帽（1MiB、head+tail、262144、4 bytes/token）/超时（min、边界确定 failure-timeout、headline、excerpt slot）——逐条与实现锚点一致。
- configure-fx/permissions：T-17 dash 数据词承诺，对照 issues/archived/ISSUE-17-plan-v2.md 评审3 C1 补记（printf '%d' -5 离开 review-free 通道、未配置评审器硬拒绝、词形守卫非选项语义、macOS/Linux 一致）——一致；实现锚点 command_effect.zig planPrintf 词形守卫（:699-701 words[2..] dash-leading → unsupported_argument）。
- mcp 页：T-18 遗留一句话，对照 T-18-impl/impl-report.md「Docs obligation」（headless fx ask 声明 elicitation form+url、不可展示的问题答 cancel、多轮请求完成而非 unsupported）——逐字一致。

## 五、机械核验（自跑，fx-pi1@20a77b568）
1. zig build test 全绿：独立 --cache-dir /tmp/t29r-cache 全量重跑，22/22 steps succeeded，10278/10285 passed（7 skipped）；主二进制直接复跑 10021 pass/2 skip/0 fail，描述 pin 测试 OK。
2. zig fmt --check src/ 退 0。
3. bash scripts/check-public-surface.sh 退 0。
4. FX_BENCH=1 ./zig-out/bin/fx help 退 0、stderr 0 字节。

## 六、红线 ✔
- 零执行语义：src diff 仅 codemode_description 字符串 + 注释 + 钉死测试断言（非注释/非串/非测试改动行计数 0）；src 逻辑零触碰。
- tests/tla/、admission/permissions/catalog 零触碰；无新 CLI/settings/env。
- 无 emoji（README/docs-section/impl-report python 核 none）；文档无 -- 作破折号（README/docs-section 无 ' -- '；impl-report 唯一一处为引用红线规则本身，非破折号用法）。
- 无个人路径（diff 与三文档按个人路径模式 grep 退出 1）。
- zig fmt 后提交。

## 七、结论
approve。README 逐句为实现真（head+tail 句在模型可见预览层成立，已澄清锚点），store()/load() 零出现，
描述红绿真实且词数不增长，--help 零改动独立验证成立，Docs 节三页齐全且 T-17/T-18 承诺与源逐字一致，
红线全守，机械核验全绿。无阻塞发现。
