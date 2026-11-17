# T-21-impl 实施报告（ISSUE-21 打磨：F2/F4/F5/F6）

工作树：本仓库分支 T-21-impl（基于 origin/main）。实现完全按 plan.md 落地，红/绿分 commit，四条顺序 F4 → F5 → F2 → F6。

## Commit 一览

| Commit | 内容 |
| --- | --- |
| a162e2707 | F4 red：catalog 不得自带默认预算（hasDecl 哨兵，当时红） |
| 22e43c5b7 | F4 green：默认预算单源移到 context_limits，删除 default_budget_bytes |
| ade0d6d0a | F5 red：触发后的 hint 必须携带预算通知子句（红） |
| 4374796fa | F5 green：Selection.observed_bytes、catalog_budget_clause、host 渲染、source 贯通 |
| d23ef3b6e | F2 red：地板哨兵要求 hint + 6 条 omitted 的空间（512 下红） |
| a2e22470e | F2 green：地板 512 → 1024，注释改为陈述事实 |
| a501ee615 | F6 red：limit 超上限必须报上限文案（红） |
| a64eb5bc6 | F6 green：discovery.max_search_limit + host 拆两条检查 |
| 5e7b5aca6 | plan.md 里的个人路径脱敏为 /Users/example/（check-public-surface 要求） |

## 验收证据

### 1. zig fmt --check src/

通过（输出为空，退出 0）。

### 2. zig build test

全绿（Build Summary: 22/22 steps succeeded）。重点三处：

* catalog.zig：9 条原有测试全过，新增 2 条（默认预算哨兵、地板哨兵）；
  "catalog exempts tier zero and cascades later omissions" 的夹具按新地板放大尺寸
  （原夹具总字节小于 1024，构造出的预算打不开字节闸），断言与级联口径不变。
* bindings_tests.zig：hint 子句断言、source 标签断言、limit 五态消息断言全过；
  原有 probe 形状测试未改动。
* codemode_tool.zig：gate 测试扩为 bytes + source 双字段断言（compiled default 与
  command_line 两种来源）。

期间两次出现 core.execution.command_runner 的截止时间类测试偶发失败，与本改动
无关（重跑即绿，改动文件均在 src/tools/codemode/，不触碰 command_runner）。

### 3. 真实二进制 ./zig-out/bin/fx 的 codemode 调用

通过 fx ask --json 驱动本地已配置 provider（magpie，127.0.0.1:3425），agent
真实调用 codemode 工具执行脚本：

* 默认 16 KiB：tools.list() 返回 9 项，Object.getOwnPropertyNames(list)
  只有索引与 length，无 omitted/hint。与 origin/main 构建的二进制（临时 worktree
  构建后同脚本同跑）输出逐字节一致（python 比较 == 为 True）。
* searchTools("q", { limit: 100000 }) 实测抛出
  TypeError: searchTools limit must not exceed 65536（新文案）。

### 4. 公开面检查

bash scripts/check-public-surface.sh 退出 0。唯一一次失败是 plan.md 第 3 行
引用方案阶段任务文件时带了真实绝对路径，已把该路径脱敏为
/Users/example/... 后通过。报告与本文件均无个人路径。

### 5. 边界脚本

4 个全部退出 0：check-agents-boundary.sh、check-compactor-boundary.sh、
check-indexer-boundary.sh、check-recovery-boundary.sh。

### 6. 新增测试清单与五态 limit 断言

新增测试：

1. catalog.zig "catalog owns no default budget; config does"（F4）
2. catalog.zig "notice floor covers the rendered hint and six omitted entries"（F2，
   断言 floor >= 10 + 渲染后 hint + 13 + 6*70，clause 代入两个 12 位数字与
   "workspace settings" 标签）
3. bindings_tests.zig "catalog hint renders the configured source label"（F5，
   command_line → "source=command line"）
4. bindings_tests.zig "searchTools limit errors split shape from the maximum"（F6）

五态 limit 断言（probe 捕 e.message）：

| limit | 期望 | 实测 |
| --- | --- | --- |
| 0 | must be a positive integer | 一致 |
| 100000 | must not exceed 65536 | 一致 |
| 65536 | ok（边界放行） | 一致 |
| Infinity | must be a positive integer | 一致 |
| -1 | must be a positive integer | 一致 |

另外扩展的两处断言：

* "tools.list appends omitted and hint own properties when the budget triggers"
  新增 observed=<夹具合计> bytes effective=200 bytes source=compiled default
  完整子串与 --context-limit codemode_catalog_bytes=BYTES|off 子串断言。
* codemode_tool.zig gate 测试新增 source 断言：--context-limit 侧 source 变为
  command_line，bytes 一并返回 4096。

## 红线自查

* 只改 src/tools/codemode/ 下文件与 plan.md 脱敏；未触碰 src/mcp/、tests/tla/、
  权限/白名单/准入路径。
* tool_schemas 全量 face 未动，预算筛选仍只在 tools.list() 返回处生效。
* catalog.zig 生产代码零 config 依赖：context_limits import 只出现在 test 块内。
* 无 CLI 面变化，--help 未动。
