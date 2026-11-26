# ISSUE-43 — 全局函数被写成 tools.searchTools()/tools.list() 等，not-a-function 报错不指向"去掉 tools. 前缀"

- **状态**: open（待立项，ISSUE-34 复发跟进）
- **发现时间**: 2026-11-26
- **来源**: 全量 169 个 session 日志分析（11-19 后 not-a-function 20 次中 12 次是全局函数误挂 tools. 前缀，另 5 次 tools.read_tool_result 未定义、3 次同步结果 .then/.catch）
- **关联模块**: src/tools/codemode/host.zig:684（TypeError: not a function 改写点）、src/tools/codemode/host.zig:533（installCallShim，named functions 只挂 face 内工具）、src/builtins/tools.zig:745（codemode_description）

## 现象

searchTools / describeTool / text / store / load 是**全局函数**，tools.list 是 tools 对象方法。模型高频写错命名空间：

| 误写 | 实际 | 11-19 后次数 |
|---|---|---|
| tools.searchTools("...") | searchTools("...") | 12（含 tools.describeTool / tools.list() 变体） |
| tools.read_tool_result({...}) | 沙箱内不存在（见 ISSUE-40） | 5 |
| tools.read_file({...}).then(...) | 同步返回字符串，无 .then | 3 |

现有报错只有一句通用提示：

```
TypeError: not a function. if the callee was a tool, use tools.call("name", args); tools.list() names the callable tools
```

对 tools.searchTools 这种"名字对、前缀错"的场景，提示反而把模型往 tools.call("searchTools") 引——那会撞 unknown codemode tool，二次失败。ISSUE-34 把常见坑前置进了描述，但没覆盖"全局函数不要加 tools. 前缀"这一条。

## 修法

1. 报错侧（host.zig:684）：QuickJS 的 TypeError 消息可拿到 callee 名（或从 script 行提取），匹配 `tools.(searchTools|describeTool|text|store|load)` 时定向提示 "searchTools is a global function; call it without the tools. prefix"。
2. 描述侧：codemode_description 或 describeTool 补充块加一句 "searchTools/describeTool/text/store/load are globals, not tools.X"（1024 字节帽内腾额度，与 ISSUE-39 的描述改动合并施工省预算）。
3. 顺手项：同步结果 .then 误用可在同一改写点提示 "tool results are synchronous values, not promises"（与 ISSUE-39 的字符串提示合并成一句）。

## 处置

- [ ] 报错定向提示 + 单测（tools.searchTools 场景红→绿）
- [ ] 描述/补充块一句话（与 ISSUE-39 合并施工）
- [ ] 观察指标：下轮 session 分析 globals misnamespaced 次数是否归零
