# ISSUE-31 — codemode script 引号转义泄漏占失败后 80%，需执行前检测/容错

- **状态**: open
- **发现时间**: 2026-11-20
- **来源**: 近 40 个 session 记录分析（~/.fx/sessions/v2/，2026-11-19 修复批次之后 836 次 codemode 调用，71 次失败，本类 57 次）
- **关联模块**: src/tools/codemode/host.zig（SyntaxError 改写点 host.zig:599 一带）、src/tools/codemode/codemode_tool.zig

## 现象

模型把 arguments_json 的 JSON 转义带进 script 源码。典型失败 script：

```
const r = await tools.call(\"run_command\", {command\": \"ls\"});
```

arguments_json JSON 解码一次后，JS 源码里残留 `\"`，直接 SyntaxError。11-19 之后的失败分布：

| 次数 | 报错 |
|---|---|
| 49 | `SyntaxError: Unexpected string (codemode.js:1:51)` |
| 7 | `expecting ';'` / `unexpected end of string` |
| 1 | `expected '}' after template expression` |

注意失败位置集中在第 1 行（第 2 个 script 参数出现处），且 ISSUE-24/25 的报错提示都不触发——这是纯编译期死，模型只能靠重试碰运气，有些 session 同一错误连犯 4 次。

## 修法

两档，先做 A 后评估 B：

- A（报错提示）：script 编译失败且报 SyntaxError 时，扫描源码是否存在 `{key\": \"` / `\"\"` 残留转义模式；命中则在错误尾部追加一行定向提示："检测到 JSON 转义泄漏：script 内不要再写 `\"`，直接写 `"`"。接 host.zig:599 现有 SyntaxError 前缀改写。
- B（执行前容错）：codemode_tool 入口对 script 做转义泄漏检测，命中则 unescape 重解码一次再进沙箱；须用 fuzz corpus 验证不误伤合法 script（合法 script 里 `\"` 只能出现在字符串字面量内部，检测模式要限定在代码 token 层）。

## 处置

- [ ] A：SyntaxError 转义泄漏定向提示 + Zig 单测
- [ ] B（可选）：入口容错 unescape + fuzz 回归
- [ ] e2e 登记：构造带残留转义的 script 验证提示出现
