# T-20-impl 实现报告 — run_script 多语言执行原语

分支 `T-20-impl`（工作树 /Users/example/Project/Zig/fx-pi3）。
权威方案：plan.md（工作树根）。实现契约：task-impl.md。
基线：origin/main @ ef1462f6b；red commit 4e2436db1；green commit 730a95e4b。

## 落地内容

复用既有 codemode bridge→shell 准入路径，单一执行路径，未新增权限面：

* `canonicalNestedCall`（src/tools/codemode/bridge.zig）加 `run_script` 分支：
  规范化为注册工具 `shell` 的 `action:"run"` 调用。语言枚举 v1 = shell + python。
* python：fx 把 `code` 写入每次调用独立的临时目录
  （`$TMPDIR/fx-run-script-<hex8>/script.py`，0o700），command 恒为
  `python3 <fx临时脚本路径>`；解释器 token 只来自枚举表，模型文本永不进 argv。
* shell：`code` 即 command，词形守卫 `command_effect.plan` 照常生效，未绕过。
* `file` 参数：相对 workspace root 解析（realpath + 前缀包含校验，拒绝目录穿越），
  有界读取（1MiB，`run_script_max_ctx_file_bytes`）后由 fx 写入同目录
  `ctx_file` 副本，经 command 前缀环境赋值 `CTX_FILE=<fx临时路径>` 注入脚本环境；
  内容不进模型上下文，源路径不出现在 command 里。
* `timeout_ms`：钳位进 host 既有区间 1000..120000（host.min/max_options_timeout_ms）；
  嵌套运行仍受 `applyAmbientBudget` 脚本剩余墙钟封顶；超时是工具失败，非请求重试。
* 临时文件生命周期：准入前写入（被审查 command 引用的是已存在文件），
  `bridge.call` 内 defer `deleteTree` 在每条返回路径上删除，调用结束即清；
  路径只出现在嵌套 shell command 字符串里（与 run_command 的 argv 同一可见级别），
  内容从不进 transcript。
* `file`/`intent` 字段校验：`file` 非空且首字节非 `-`；`intent` 必须为 string，
  v1 接受后不落盘（见偏差 3）。
* 拒绝点（follow-up note 3）：一切拒发发生在规范化层 `canonicalNestedCall`
  （`error.InvalidToolArguments`），先于 admission、先于 shell decode。
  未知字段（`args`、`interpreter` 等）一律拒，任何 '-' 前缀 token 无进面路径。
* 面与 schema：`derivedFace` 追加 run_script（派生面 10 项），shipped 四名面不变，
  gate 关闭时 run_script 不可点名、不在 tools.list；run_script 无 registry 条目，
  `bridge.schemas()` 直接渲染静态 `run_script_model_schema`（实测 629 字节）；
  `catalog.tierOf("run_script")` 缺省归 T2，测试钉住。
* `shellResult` 编码经 `isShellBackedFaceName` 与 run_command 共用
  `shell.encodeResultJson`（exit_code / output / truncated），输出帽不变。
* 红线核对：`parity_review_free_commands` 未动；src/mcp/ 零触碰；
  src/core/permissions/ 零触碰；QuickJS host 零 spawn（杀树归 shell 运行时）；
  admission 不变量未动（面只决定可点名性）。
* src/core/tooling/model_tool_schema.zig：`PropertyShape`、`PropertyBounds` 改 pub
  （bridge 静态 schema 引用），无行为变化。

## 验收证据（逐条）

1. `zig fmt --check src/` 退 0。实测：exit 0。
2. `zig build test`：三次运行，前两次各只有既有
   `core.execution.command_runner.test.runtime cancellation observed at the timeout
   deadline stays graceful` wall-clock flake 失败，第三次全绿
   （9995 pass / 2 skip / 0 fail）。按契约注明该 flake 复跑可过。
3. `cd tests/e2e && FX_SOUND=0 bun test codemode-admission.test.ts cli.test.ts`：
   19 pass + 139 pass，0 fail。
4. `bash scripts/check-public-surface.sh` 退 0（报告与本文件只用 /Users/example/）。
5. 四边界脚本（agents/compactor/indexer/recovery）全部退 0。
6. 二进制实测：e2e 用 `./zig-out/bin/fx ask --json`（runFx 驱动 FX_BIN=
   zig-out/bin/fx）跑通真实 python3：stdout 捕获（exit_code 0 + output 含
   py-ok-1137）、非零退出失败路径（exit_code 3 + stderr 行）、CTX_FILE 文件注入、
   拒绝路径、gate 关闭时 run_script 不在 tools.list 且 tools.call 报
   unknown codemode tool。共 5 个 run_script e2e 用例 + 既有 14 个用例全绿。
7. 未新增 e2e 文件（测试并入既有 codemode-admission.test.ts，继承其分类），
   corpus.json 与 ci-shard-weights.json 无需接线。
8. 产物：red commit 4e2436db1（红先提交，实测红：9 个单测失败 +
   4 个 e2e 失败，输出记录于 .fx-red-evidence.txt）→ green commit 730a95e4b
   → 本报告随产物 commit。

## 偏差逐条声明

1. **CTX_FILE 注入机制**：plan 问 3 写“把路径塞进 spawn 的 env”。实现走 command
   前缀环境赋值（`CTX_FILE=<path> python3 <path>`）。原因：shell `action:"run"`
   无 env 字段，加字段会分叉执行路径（红线）。环境赋值同样落在子进程 env，
   脚本 `os.environ["CTX_FILE"]` 读取不变。
2. **CTX_FILE 为副本**：fx 读取 workspace 文件（1MiB 上限）写入临时副本而非传
   原 realpath。原因：plan 明确 fx 写临时文件，且副本让生命周期与 per-call
   临时目录统一（defer deleteTree 一处清理）。
3. **intent 仅接受不落盘**：v1 校验其为 string 后丢弃，未写任何记录面。
   plan 未规定其去向；后续如需 transcript 上下文可在 codemode_tool 层接入。
4. **schema 实测 629 字节**，高于 plan 的 300-500B 估算（五字段描述占位），
   远低于 16KiB 目录预算；测试以 300..768 区间钉住，防止描述膨胀。
5. **timeout_ms 钳位而非拒绝**：区间外值收敛到 1000/120000；非整数拒。
   plan 只说“复用既有区间”，钳位对模型更宽容。
6. ** '-' 前缀拒绝范围**：模型文本根本不进 argv（argv 恒为
   `python3 <fx临时路径>` 或 shell command），故 '-' 守卫落在可能成为
   token 形状的 `file` 值与语言枚举上，未知字段整类拒绝；code 以文件注入，
   首字符 '-' 不构成解释器选项。
7. **测试格式修正**：red commit 后 green 阶段按新签名更新了 python 规范化
   测试调用点（断言不变，补 temp 目录清理），并新增 file 参数四个单测；
   catalog 既有测试 9→10 项（派生面加 run_script）。
8. **dash 拒绝 reason 枚举**：统一 `error.InvalidToolArguments`（与
   canonicalNestedCall 既有约定一致），脚本侧消息
   `codemode tool run_script failed: InvalidToolArguments`；e2e 钉住。

## Docs

fx.sh/docs 的 codemode 页（私有仓库，无法直接推送）需补一段：派生面开启时
脚本可调用 `tools.call("run_script", { language: "shell"|"python", code, file?,
intent?, timeout_ms? })`；python 经 fx 临时脚本文件以固定 argv 运行，
`file` 经 CTX_FILE 环境变量暴露 workspace 文件副本；结果形态与
run_command 相同（exit_code / output / truncated）；gate 关闭时不可见。
`--help` 无需变化（run_script 是脚本面原语，非 CLI 控制）。

## 复审 follow-up notes 落实对照

1. file 参数语义：路径解析（workspace root 相对 + realpath）、穿越拒绝
   （单测 `run_script file param refuses traversal outside the workspace`）、
   生命周期（per-call 目录 defer 删除，见上）均已钉测试。
2. CTX_FILE 临时文件生命周期：准入前写入、脚本调用结束即删、内容不进
   scrollback（路径仅在 command 字符串内，同 run_command 可见级别）。
3. dash 前缀拒绝：钉在规范化层，见偏差 6/8。
