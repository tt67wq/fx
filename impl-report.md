# T-23a-impl 实现报告 — codemode Timeout 失败信息补齐（ISSUE-23a）

- 分支：`T-23a-impl`（自 origin/main `4ee0ccd17` 切出）
- 权威需求：`issues/ISSUE-23.md` 差距清单第 1 项（Timeout 错误信息补齐）；契约 `.agents/tasks/T-23a-impl/task.md`
- 纪律：严格 TDD，红/绿分 commit。红 commit 为 `5a71b2985`（红证据 `.fx-red-evidence.txt`），绿 commit 见 head。
- 本工作树：`/Users/example/fx`。
- 本轮范围：只做 Timeout headline 一项；部分输出保留、长命令预算、轮询引导留给 23b。

## 落地内容

Timeout 失败 headline 从裸 `codemode script failed: Timeout` 增强为：

```
codemode script failed: Timeout after {d}ms (budget {d}ms, from default|@options); raise it with // @options: {"timeout_ms": N} on the first script line
```

1. **实际耗时**：`io_mod.milliTimestamp()` 在失败时刻读一次，减 `state.ambient_started_ms`（call 开始时已写入）；负值 clamp 为 0，Cancelled 竞态只损失精度，不崩溃。
2. **生效预算**：`input.effective_timeout_ms`（clamp 后的值，bridge 传入不变）。
3. **来源**：`Input.timeout_from_options`（decode 时记 `script_options.timeout_ms != null`），区分 profile 默认值与 @options 显式传入；恰好传 30000 也如实报 `from @options`。
4. **修正方法**：一行 @options 示例，与 codemode_tool.zig:44 既有 @options 说明同格式。
5. 组装在 `timeoutHeadline`（codemode_tool.zig），call 的 eval 错误处理把 `error.Timeout` 从 else 分支拆出专门处理；**其余错误（ScriptError、Cancelled、MemoryLimit 等）headline 不变**。partial output、nested call summary 的既有 failureBody 逻辑原样复用。

## 红线自检

- 零执行语义变更：超时判定、`bridge.zig:406 clampRunScriptTimeout`、ambient 预算传递均未触碰；diff 只含 headline 字符串、一个 Input 布尔字段、decode 一行赋值、eval 错误 switch 拆分支。
- recovery 语义未动：超时仍是工具失败。
- 未新增 CLI 面、settings 键、环境变量；文案在测试中逐字钉住（`expectEqualStrings` 完整 golden × 2 + e2e `toContain`）。

## 验收证据（逐条）

1. `zig fmt --check src/` → 退 0。
2. `zig build test --summary all` → 22/22 步成功，10013/10015 pass（2 skipped），0 fail（约 6 分钟，无 flake 复跑需要）。红轮实测红：3 条新测试断言失败（2 条 headline golden、1 条 decode 字段），其余 10004 条全过（`.fx-red-evidence.txt`）。
3. `cd tests/e2e && FX_SOUND=0 bun test codemode-admission.test.ts cli.test.ts` → 0 fail（codemode-admission 的 2 条 budget 用例 pass，cli.test.ts 139 pass / 0 fail）。未新建 e2e 文件，corpus 分类与 shard 权重沿用。
4. `bash scripts/check-public-surface.sh` → 退 0；四边界脚本（agents/compactor/indexer/recovery）全部退 0。
5. 真机探针：两条 e2e 用例都跑新构建的 `zig-out/bin/fx`（runFx + fake gateway）：
   - 默认预算（sleep 60 vs 30s 默认，嵌套 run_command 在预算处被杀）→ headline 含 `Timeout after `、`(budget 30000ms, from default)`、`raise it with // @options: {"timeout_ms": N} on the first script line`；
   - @options 抬高（`// @options: {"timeout_ms": 5000}`，5.1s 处失败）→ headline 含 `(budget 5000ms, from @options)`。

## 偏差逐条声明

1. **bindings_tests.zig 未加测试**：headline 只在 `codemode_tool.call` 组装，bindings/host 层没有能产出工具级 Timeout 失败的 seam（bindings_tests 直接 `Host.eval`，拿不到 tool result）；逐字钉测试落在 codemode_tool.zig 内部 golden ×2 + e2e ×2，覆盖等价。
2. **红 commit 带了脚手架**：`timeoutHeadline` 在红 commit 以"返回旧 headline 的 stub"形式存在、`timeout_from_options` 字段未接线。原因：Zig 的 AstGen 级 undeclared-identifier 错误会连累 exe 构建，纯测试红 commit 无法编译出真机二进制、e2e 红证据拿不到；stub 让全部新测试编译并在运行时按旧行为失败（3 条 zig 红 + 2 条 e2e 红），绿 commit 换成真实实现并接线。
3. **e2e 两条超时用例而非一条**：契约写"一条超时用例"，但验收第 5 条要求 @options 抬高后报 `from @options` 的真机探针。做法：既有默认预算用例加三要素断言，另加一条 @options 用例（5s 预算，比默认用例快），两条都并入 codemode-admission.test.ts。
4. **新增 `Input.timeout_from_options`**：契约说"优先借力 state 里现成字段，不新增状态"。耗时/预算用现成字段（ambient_started_ms / effective_timeout_ms），但"来源"信息 decode 之后无处可借（`script_options` 是局部变量），故在 decode 产物 Input 上加一个 bool；未动 `ScriptToolState`，也不随调用持久化。
5. **.fx-red-evidence.txt 中路径已脱敏为 /Users/example/**：初版记录含真实工作树路径，被 `check-public-surface.sh` 拦下（surface_exit=1），按个人路径零容忍改为 /Users/example/ 后复跑退 0。

## Docs

无 `--help`/CLI/文档面变化（工具失败文案不在用户手册 codemode 页的命令清单内）；23b 轮若按 ISSUE-23 处置项补 codemode 页超时与 @options 用法，再一并更新手册。

## 复审 follow-up notes
（留待 t39 review 轮填写。）
