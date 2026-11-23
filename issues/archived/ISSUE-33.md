# ISSUE-33 — codemode 超时判定两处收口：命令已完成仍判失败；@options 上限与提示自相矛盾

- **状态**: done（现象一/二 + 上限决策全部落地，2026-11-23 关单归档）
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

- [x] 预算到期 grace drain 与"差 text() 收尾按成功结算"
- [x] @options 越界报错带合法示例行
- [x] 上限调整的产品决定（用户拍板提到 300000ms，T-33c 落地）
- [ ] e2e 登记：30s 预算 + 29s 完成命令的成功结算路径

## 现象二落地备注（2026-11-21）

T-33a-impl 红 7192208ae → 绿 6bd46da89，review PASS（fx-pi3 独立复现红）。OutOfRange 两支各带可复制合法示例行，range 与示例值全部引用 host 常量（无魔数）；Malformed 分支现状已清晰未动；上限常量未动。已合并 main（7fa7281ef），双远端已推。评审证据尾账：worker 存的 red-evidence.txt 是单文件 zig 直跑的错误调用输出，红本身经评审 detached worktree 独立复现为真。

## 现象一落地备注（2026-11-22）

T-33b 三轮：首轮 deepseek 实现错循环（grace 只在 inner，现象一 settle 在 first eval 循环）+ 七测试全 vacuous，评审插桩探针 CHANGES-REQUESTED（F1-F6）；换 qwen4-max 重做 T-33b-fix 红 de7cf766a → 绿 f77a0a5a5，复审 PASS（fx-pi2 原评审者，逐条 Required 消解 + 探针实证）。终态：grace 进第一个 eval drain 循环（500ms 常量），仅 pending>0 进 grace、pending==0 真停滞立即 Timeout；设计冲突消解 = 预算死权威高于 grace settle（call 返回超预算置 timed_out，settled-SUCCESS honor 它），四个 budget-expiry e2e 恢复 Timeout 且 partial/excerpt 完整，现象一（call exit0 在预算内、finalization spill）成功；新调用 deadline 后仍拒（calls==0 钉死）；interrupt +500ms 刻意双侧 wall bound；pending==0 不必要 hunk 已丢。七 vacuous 测试换确定性 burn 链（grace_deadline_ms>0 断言真进窗口），e2e 对 base 二进制红再信。评审尾账：报告 EXCERPT_LEN 1117/1037 引用不存在（断言实为头尾标记+omitted+stopped/TimeoutExpired 字段，底层声明为真，订正引用非代码）；grace-cancel 测试饱和 runner 潜在 flake（若 flake 加宽 margin 非 timeout）。已合并 main（47757ef4a），合并树全量测试绿，双远端已推。上限产品决策（120s 维持/提高）仍待开。

## 上限决策落地备注（2026-11-23，T-33c）

用户拍板上限 120000 → 300000ms。T-33c-impl 红 8f07e2bfe → 绿 3ecd24d7a，review APPROVE（fx-pi2 独立复核 7 项全过）。单一常量源根治：host.zig max_options_timeout_ms=300_000，timeoutHeadline/bridge description/builtins codemode_description 全改 comptimePrint 引用常量，codemode 语义处无 120000 字面量残留（仅存「旧帽在新界内仍合法」有意守卫）；全仓 116 处 120000 逐处分类，无关处（retry fixture/token 预算/0o120000 symlink mode）不动。min 1000/默认 30000/grace 500 未动。真机实证 300000 接受跑通、300001 拒且示例行带新帽；e2e 32 pass 0 fail；全量测试绿。README:14 区间同步改 300000（conductor 整合时修）。评审尾账：① codemode_description 正好顶 1024 字节帽零余量（base 亦然），后续加词须先删字；② sandbox.zig:145-148 注释「one host timeout period (30s by default)」语义仍对但读者易误以为上限即 30s，声明 300000 后最坏取消等待随之变长；③ T-27 min 语义下上限抬高同时放宽嵌套单命令最长占用，全仓无更短外部 watchdog 截断，新上限真实可达。已合并 main，双远端已推。
