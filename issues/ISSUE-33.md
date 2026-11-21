# ISSUE-33 — codemode 超时判定两处收口：命令已完成仍判失败；@options 上限与提示自相矛盾

- **状态**: open
- **发现时间**: 2026-11-20
- **来源**: 近 40 个 session 记录分析（~/.fx/sessions/v2/，11-19 之后 3 次相关失败）
- **关联模块**: src/tools/codemode/codemode_tool.zig（预算执行）、src/tools/codemode/host.zig

## 现象一：命令实际完成仍判超时失败

失败样本的 partial output 里已带 `{"exit_code":0`——嵌套 run_command 已退出、
输出已在管道里，但 script 因 30s 预算到期被判失败，整轮结果丢弃成功证据。
ISSUE-23 已补部分输出与耗时回显，但"完成与失败的边界"没处理。

## 现象二：@options 上限与报错提示打架

超时报错提示 "raise it with // @options: {\"timeout_ms\": N}, max 120000"，
模型照做写 180000 又被拒："must be 1000..120000 (received 180000)"。
提示本身写了上限，但模型明显不读完整句；且 120s 上限对构建类长命令偏紧。

## 修法

- 现象一：预算到期时先 drain 已完成的嵌套调用结果（带一个很短的 grace，如 500ms），
  若嵌套调用全部退出且 script 只差 text() 收尾，按成功结算已收集输出；否则维持失败但保留 partial。
- 现象二：@options 解析失败时报错直接给出合法示例行（`// @options: {"timeout_ms": 120000}`），
  不再只念约束；评估是否把上限提到 300000 或在 catalog 描述里写明典型命令的建议预算。

## 处置

- [ ] 预算到期 grace drain 与"差 text() 收尾按成功结算"
- [ ] @options 越界报错带合法示例行
- [ ] 上限调整的产品决定（维持 120s / 提高）
- [ ] e2e 登记：30s 预算 + 29s 完成命令的成功结算路径
