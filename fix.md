# T-14-4 修复轮产物（ISSUE-16 findings）

分支 fx-pi1，起点 5d186b801。红 commit a9f52ae34，修复 commit 见本文件所在提交之后的记录。

## F1（阻塞）gate 未接 fx ask 路径 — 已修

修法：`src/core/cli/cli_ask.zig` 的 `AskContext` 增加
`codemode_derived_surface_gate: ?bool`，accessor `codemodeDerivedSurface()` 首次读取
merged profile settings 后缓存（与 `main.zig` 的 `codemodeDerivedSurface()` 同形），
`toolContext()` 用 `.codemode_derived_surface = self.codemodeDerivedSurface()` 接入。
不新增每轮磁盘读：一次 ask 运行最多合并一次设置。

红测试（a9f52ae34）：
- `cli_ask.zig`：`fx ask tool context forwards the codemode derived surface gate`
- `app_agent_runtime.zig`：`app agent runtime tool context carries the codemode derived surface gate`
  （FakeApp 增加 `codemodeDerivedSurface` 钩子，锁住两处构造点都接线）

先红证据：

    src/core/cli/cli_ask.zig:4951:9: error: no field named 'codemode_derived_surface_gate'
        in struct 'core.cli.cli_ask.AskContext'
    error: 1 compilation errors

后绿：实现后 `zig build test` 全绿（见验收）。

## F2（bug）installCallShim 双释放 — 已修

`src/tools/codemode/host.zig`：删除 `JS_SetPropertyUint32` 失败分支对 `tool_name`
的释放、`JS_SetPropertyStr` 失败分支对 `whitelist` 的释放，两处各留注释说明 QuickJS
两个 setter 无论成败都消费 val。`JS_IsException(tool_name)` 分支对 `whitelist` 的
释放保留（该分支 val 未被任何 setter 消费）。

## F3 sandboxFace 文档注释错位 — 已修

`bridge.zig`：把 `schemas` 的旧文档注释（"Builds one ToolSchema per whitelisted
tool..."）移回 `pub fn schemas(` 正上方，sandboxFace 只保留自己的注释。

## F4 运行时注入白名单偏离 comptime 双面 — 已补注释

`host.zig` shim 注释补两点：为什么必须在运行时注入（两个面存在，运行时选面，单一
comptime 字面量无法描述两面；QuickJS 自持副本，无字符串拼接与生命周期问题），以及
「授权点唯一」不变量：shim 只决定脚本能否写下名字，不授权；`toolsCallCallback` 在
中断与截止检查之后对同一面复查，唯一执行路径是 bridge 的嵌套准入，且每次都对全量
builtin registry 解析，加名字永远不会让调用免审。

## F5 tools.__codemode_whitelist 对脚本可见 — 不改代码，记录

该属性对脚本可见，但不构成安全问题：授权点在 `host.zig` 的 `toolsCallCallback`
（`bindings.findIn(host.tool_face, name)`）与 bridge 的嵌套准入，脚本改写或删除该属性
只影响它能写下哪些名字，不会让任何调用跳过准入。删除属性会让 shim 无法在安装期
枚举名字（JS_Eval 后的清理同样要触碰已安装的命名函数），收益为零、复杂度增加，
故保留。PR 描述记录。

## F6 app_agent_runtime.zig 越界 4 行 — conductor 已豁免

该文件是 `tool_runtime.Context` 唯一应用侧构造点，`@hasDecl(App, "codemodeDerivedSurface")`
守卫与相邻的 `@hasDecl(App, "providerSet")`、`@hasDecl(App, "toolRegistry")` 等模式一致，
边界脚本通过。PR 描述记录。

## F7 新键的 fx config list 展示 — 已补断言

`tests/e2e/cli.test.ts` 的 `experimental.codemode_derived_surface is a known settings key`
测试增加：`fx config list` 退出码 0 且 stdout 含
`experimental.codemode_derived_surface=true`（实测该键确实被列出）。

## F8 e2e 分类与权重 — 无需变更，记录

新断言落在已分类的 `tests/e2e/cli.test.ts`（Training）内，继承该文件分类；
`tests/e2e/ci-shard-weights.json` 的权重按文件计，文件未新增，无需改动。PR 描述记录。

## 后续（不在本轮）

开启态面扩张（标记 web_fetch、ask_user_question、vision）另开变更，届时补 deny 模式
逐次准入覆盖。本轮开启态与关闭态仍同面。

## 验收

见交付回报中的命令行结果。
