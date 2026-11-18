# ISSUE-20 — codemode 多语言执行原语（ctx_execute 对齐）

- **状态**: closed（2026-11-18）
- **发现时间**: 2026-11-16
- **来源**: fx codemode 与 pi 1.5.1 能力对比（用户驱动）
- **工作量**: 大
- **关联**: ISSUE-14（工具面机制）、ISSUE-15（目录预算，若新增原语需进目录）

## 现象

fx 的 codemode 只接受 JavaScript（QuickJS 沙箱，builtins/tools.zig:743 的工具契约写明 `script` 只收 JS）。pi 的 codemode 另有一个 `ctx_execute` 多语言子进程原语：`language` 收 shell / powershell / javascript / typescript / python 或 PATH 上的其他运行时，起沙箱子进程执行，支持大文件注入（CTX_FILE 环境变量）、intent 驱动的输出过滤与索引、timeoutMs 上限。适合数据处理、统计、格式转换这类"工具做不了、模型算不动"的活。

fx 现在的间接等价物是 JS 里 `await tools.run_command({ command: "python3 ..." })`，但那是走 shell 审查路径的普通子进程调用：没有独立的语言声明、没有输出帽继承语义、没有大文件注入、每次都要过权限评审，体验与安全属性都不对齐。

## 差距清单（pi 侧参照）

- [x] `language` 参数：声明解释器而非拼 shell 命令行（v1：shell + python 枚举，解释器 token 永不来自模型文本）
- [x] 沙箱子进程隔离与超时（timeout_ms 复用 host 1s-120s 区间，ambient 预算封顶，杀树归 shell 运行时；超时是工具失败不是请求重试）
- [ ] 输出帽：只回显脚本打印的答案；全量输出落盘并索引，配 ctx_search 式回读
- [x] 大文件注入：CTX_FILE 以命令 env 前缀交给脚本，不经模型上下文（fx 写临时脚本文件，生命周期有 e2e 钉测：无 TMPDIR 残留、内容不进 command）
- [ ] `file`/`intent` 参数语义（意图过滤、索引分块）

## 修法（方向，实现前需设计评审）

新增 codemode 沙箱内原语（如 `ctx_execute`），而非新顶层工具：保持"JS 编排 + 子进程执行"两层结构与 pi 一致。设计前必须回答：

1. **权限面**：执行任意解释器等价于任意代码执行。run_command 的准入规则（command_effect.plan / parity_review_free_commands 白名单）如何映射到声明式 language+code 形态？白名单如何按语言收口（如 python 只放行解释器本体加脚本 stdin，拒绝 -c 拼接的选项注入）？
2. **fx-cli-shape**：新原语的名称、参数、JSON 输出字段、预算选项（timeout_ms / max_output_tokens）按 CLI 形状规则评审
3. **沙箱边界**：QuickJS 桥内新增原语走 host 回调（mcp host.zig 模式），不得让 codemode 模块直接起进程
4. **ISSUE-15 交互**：新原语进 tools.list() 目录，预算机制需覆盖
5. **TLA+ 评估**：若超时/取消语义进入 recovery 模型范围，按 AGENTS.md 同步 spec

## 处置

- [ ] 设计评审（权限映射 + CLI 形状 + 沙箱边界）定稿
- [ ] TDD：红测试（语言声明、超时杀树、输出帽、文件注入）
- [ ] 实现原语 + 目录接入
- [ ] 文档：--help 与 fx.sh/docs codemode 页


## Resolution（2026-11-18）

以 `run_script` 原语落地（用户拍板命名，遵循 fx 脚本面 snake_case 约定，非 pi 的 ctx_execute）。v1 范围：shell + python 两种语言。

- **权限**：复用 shell 工具既有准入路径——canonicalNestedCall（bridge.zig）把 run_script 规范化为 `shell action:run` 单一路径；argv 恒为"枚举解释器 + fx 写入的临时脚本路径"，模型文本永不进 argv；任何 `-` 前缀 token 在规范化层拒绝（reason 枚举钉测）。准入不变量保持：每次调用一次评审（auto 模式实证 review_origin=codemode），目录面只决定可点名性。
- **面**：只进派生面（experimental.codemode_derived_surface 开启时），catalog T2 层；gate 关闭零变化。
- **输出**：继承 codemode 输出帽与头尾保留（ISSUE-12 地基）。
- **验证**：TDD 红（4e2436db1 等）/绿分层；独立复审 approve（B1 修正：fx 写临时脚本文件替代不可实现的 stdin 形态）；独立验证 changes-requested 两阻塞项（个人路径产物、孤儿临时目录）均修复并钉测；e2e 165 tests 0 fail。
- **未做（留 ISSUE 跟进）**：intent 输出过滤/索引回读（ISSUE-15 地基已备）、powershell/typescript 及 PATH 运行时扩展、 denial 原因的更细文案。
