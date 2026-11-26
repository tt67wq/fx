# ISSUE-44 — 模板字符串包 heredoc/Python/Markdown 内容互踩引号反引号，SyntaxError 残存 40 次，ISSUE-31 检测覆盖不全

- **状态**: open（待立项，ISSUE-31 覆盖面跟进）
- **发现时间**: 2026-11-26
- **来源**: 全量 169 个 session 日志分析（11-19 后 SyntaxError 40 次 / 20 个 session；其中 8 次明确是 String.raw/heredoc 模板串模式；本轮分析自身又实犯 2 次）
- **关联模块**: src/tools/codemode/host.zig:657（escape_leak 检测，只认 \\" 序列）、src/tools/codemode/host.zig:668（escape_hint 文案）

## 现象

ISSUE-31 落地后 "JSON 转义泄漏"（\\" 序列）基本归零（残 2 次），但 SyntaxError 大类仍有 40 次。抽样根因：

| 形态 | 次数 | 例子 |
|---|---|---|
| 模板串内嵌 heredoc/Python，内容含反引号或 ${ | 8 | `python3 - <<'EOF' ... EOF` 里 Python f-string / 正则反斜杠互踩 |
| 模板串包 Markdown 草稿，内含反引号代码围栏 | 若干 | answer-me-with-html 草稿直接塞进 `...` |
| 其余（缺分号、意外字符串、undefined token） | ~30 | 多为上一条的连锁报错位置 |

典型报错只有裸 SyntaxError + 行列号：

```
ScriptError: SyntaxError: expecting ';' (codemode.js:20:42)
ScriptError: SyntaxError: expected '}' after template expression
```

模型看不出"是模板串内容踩了定界符"，往往原样重试再犯。现有 escape_leak 检测（host.zig:657）只匹配 \\" 字面序列，对上述形态全部漏检。

## 修法

接 host.zig:657 现有改写点，扩两类检测（编译期失败才触发，零运行时开销）：

1. **模板串定界符冲突**：SyntaxError 且 script 含模板串时，扫描报错行附近是否有未转义反引号 / ${；命中则追加 "template literal content collided with its delimiters; escape backticks and ${ inside, or build the payload with write_file + run_script file mode"。
2. **heredoc 模式**：script 同时含 `<<'EOF'`（或 <<EOF）与模板串时报同类提示，建议改用 write_file 落盘再执行，绕开双层转义。

提示文案给出**替代写法**而不只是诊断——write_file + run_command 执行文件是本仓库模型已会的动作。

## 处置

- [ ] 两类检测 + 定向提示单测（各一个红→绿样本，语料进 tests/fuzz/corpus/codemode_script/ 如适用）
- [ ] 观察指标：下轮 session 分析 SyntaxError 次数是否显著下降（目标 <10）

## 性价比排名（2026-11-26）

第 5 / 6。SyntaxError 残 40 次 / 约 20 个 session，量大但根因分散，检测只能覆盖模板串子集；中等成本，排在前三批小改之后。
