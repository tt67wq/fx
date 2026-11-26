# ISSUE-39 — codemode 嵌套工具结果是 JSON 字符串，模型当对象用，单类失败 74 次居首

- **状态**: open（待立项）
- **发现时间**: 2026-11-26
- **来源**: 全量 169 个 session 日志分析（~/.fx/sessions/v2/，11-19 修复批次后本类 74 次失败，另有约 2076 个脚本写防御性 JSON.parse）
- **关联模块**: src/tools/codemode/host.zig:1301（toolsCallCallback 返回 JS_NewStringLen）、src/tools/codemode/shell.zig:27（encodeResultJson）、src/builtins/tools.zig:745（codemode_description）

## 现象

tools.call / tools.<name> 的返回值是**JSON 字符串**而非对象。模型按直觉写 `r.output.slice(...)`、`r.exit_code`，拿到 undefined 后整个脚本 ScriptError 作废：

```
ScriptError: TypeError: cannot read property 'slice' of undefined
Last nested output before failure (run_command, ok, 204ms): {"state":"completed",...}
```

关键事实：

| 证据 | 数值 |
|---|---|
| 11-19 后本类失败 | 74 次（占全部 codemode 失败 33%） |
| 分布 | 2 个 session；iOdp3dy91ZhI 一个 session 连犯 73 次，跨两天未自愈 |
| 防御性 parse 脚本 | 约 2076 / 13634（typeof r === "string" / JSON.parse(r)），模型学会绕坑但每个脚本都在付税 |
| 嵌套调用已执行 | 失败不撤销副作用，重试有重复执行风险 |

描述里只说 "arguments are objects"，没说**返回值是字符串**；报错 "cannot read property 'slice' of undefined" 也不指向根因。

## 修法

二选一，需要决策：

1. **A 返回对象**：host.zig:1301 改 JS_ParseJSON（store 路径 host.zig:786 已有先例）。兼容风险：现存防御性 `JSON.parse(r)` 脚本拿到对象再 parse 会报错；需要兼容期或版本说明。
2. **B 提示先行**（倾向）：零兼容风险。
   - codemode_description 加一句 "tool results are JSON strings; parse before use"（受 1024 字节帽约束，src/builtins/tools.zig:778 测试钉死，需压缩腾额度）；
   - host.zig:684 一带的 ScriptError 改写点：检测 "cannot read property 'X' of undefined" 且前一次嵌套调用成功时，追加 "tool results are JSON strings; use JSON.parse(r) first"。

## 处置

- [ ] 决策 A/B（倾向 B 先行，A 视兼容评估另议）
- [ ] 落地 + 定向报错的单测（红→绿）
- [ ] 观察指标：下轮 session 分析本类失败次数与防御性 parse 占比是否下降
