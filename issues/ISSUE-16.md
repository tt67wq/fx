# ISSUE-16 — T-14-3 评审发现：gate 未接 fx ask 路径与 shim 双释放

- **状态**: fixed（T-14-4 修复轮，fx-pi1；F1–F4、F7 已修，F5/F6/F8 记录）
- **发现时间**: 2026-11-13
- **来源**: T-14-3 独立评审（fx-pi3 分支 review.md @ 4d84dc074，被评审 5d186b801）
- **工作量**: 小
- **关联**: ISSUE-14 施工（fx-pi1 分支，绿 5b4f6c655）

## F1（阻塞）gate 只接了 TUI agent 路径

tool_runtime.Context 全仓两处构造：app_agent_runtime.zig:393 已接
codemode_derived_surface，cli_ask.zig:1072 toolContext 未接，恒为默认 false。
后果：fx ask / fx ask --json（evals 与一切脚本化调用）上开关无效。评审已实测：
同一二进制同一 profile，TUI 下探针工具出现在面里，ask 下不出现。
修法：cli_ask 的 toolContext 复用 main.zig:1885 的缓存 accessor 形态，禁止每轮
重新合并设置文件；补一条锁住两处构造点的测试 + ask 路径开关生效的断言。

## F2（bug，错误路径）installCallShim 双释放

QuickJS 的 JS_SetPropertyStr/Uint32 无论成败都消费 val（quickjs.c:11016-11026）。
host.zig:362-366 与 :368-371 在 SetProperty 失败分支又 JS_FreeValue(val) → 双释放。
修法：删这两处对 val 的释放；whitelist 在 JS_IsException(tool_name) 分支（:358-361）
的释放是对的，保留。

## 次要项（随修复轮一并处理）

- F3：sandboxFace 头上挂着 schemas 的旧文档注释，挪回。
- F4：host.zig 白名单由 comptime 字面量改运行时注入，偏离 ISSUE-14 方案第 2 条
  （comptime 双面）。可接受但需在代码注释记录理由与「授权点唯一」不变量。
- F5：tools.__codemode_whitelist 现对脚本可见（无安全问题，授权点在 host.zig:625）。
  PR 描述说明，或注入后删该属性。
- F6：app_agent_runtime.zig 4 行越界，conductor 已豁免（与相邻 @hasDecl 模式一致，
  边界脚本通过）。
- F7：新键的 fx config list 展示补一条 e2e 断言。
- F8：e2e 分类与权重无需变更，PR 记录即可。

## 收口顺序（评审建议）

F1 → F2 → F3+F4 注释+F7 → F5/F6/F8 写进 PR 描述。F1 的后续面扩张（标记
web_fetch 等）另开变更，届时补 deny 模式逐次准入覆盖（ISSUE-14 基线建议 6 后半段）。