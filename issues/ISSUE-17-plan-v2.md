# ISSUE-17 处置方案 v2（T-17-review 评审后修订）

- **状态**: fixing
- **修订时间**: 2026-11-13（复审2后定稿：R1-R4、N-a..N-d 已并入）
- **评审来源**: T-17-review（fx-pi1 分支 T-17-review @ ea47fbd79，review.md changes-requested B1-B4 + N1-N7）
- **v1 差异**: 根因更正（uutils 非 GNU）、改动清单按评审粒度重写、失败 3 数字重排、失败 2 取证步骤重排

## 失败 1：printf shell parity（linux，command_effect.zig）

### 根因（v2 更正）
GitHub runner ubuntu-24.04（Image 20261111.370.1）的 /usr/bin/printf 是 uutils coreutils（clap 选项语义），不是 GNU。native 把数据位的 --help/--version 当帮助/版本标志吃掉（9267 字节帮助文本打到 stdout、exit 0）；shell 内建 printf 当数据打印。GNU（getopt optstring 带 +，首个非选项操作数后停解析）不复现——评审员 docker 实测 ubuntu:24.04 / ubuntu:22.04 / debian:bookworm-slim 均原样打印 --help。修复消失条件部分取决于 GitHub 镜像里 printf 是谁，须在失败打印里带 printf --version 首行以便日后判定。

### 修法（改拒绝词集策略）
沿用拒绝语义（退出 review-free 通道、落回正常审批），但 v1 的"枚举危险词"不可行——uutils 侧 -h/-V/--help=x/未知长选项行为无实证。改为**按词形整类拒绝**：

- planPrintf 守卫：任一数据词（words[2..]）以 '-' 开头 → .{ .approval_required = .unsupported_argument }。
- **守卫位置（R1+R2c 定案）**：守卫在 planPrintf 内、任何 argv 构建之前；现有顺序 printfStringConversionCount(:705) 与 count 检查(:687)保持在前，词形守卫放在 count 检查**之后**——:1741 的 surplus fixture（两数据词对一 %s）因此继续由 count 检查拒绝，count 执法不失去唯一 pair 覆盖。拒绝 reason 枚举跨 macos/linux 一致。
- 不依赖任何 printf 实现的选项语义（B1 的实证要求按构造消解）；覆盖未知长选项与 -h/-V 全类（N5 覆盖真空一并关掉）。
- 已证安全的对照："-leading" 数据类在真 runner 上原样通过（CI 只挂 --help 一项），拒绝它是保守方向的已知 UX 成本，接受（N3：auto 模式无人工屏）。
- **UX 成本显式化（R2）**：拒绝把命令从 .captured review-free 通道移入 automaticReviewOutcome（tool_admission.zig:1139），用户可见面只是额外延迟；且**每次调用都重新规划、重新评审**——除 AGENTS.md 已述机制外无按拒绝原因的跨回合缓存。
- **评审3 C1 补记**：成本不止延迟——tool_admission.zig:79 默认 auto_classifier 为 .disabled()，:998-1000 直通 reviewerUnavailableOutcome，:947-957 返回 deny/review_unavailable：**未配置评审器的用户**会从本来正确的 review-free BSD printf 运行变为硬拒绝。须写进 PR body 与权限手册页（Documentation 规则）。日常受影响面例：printf '%d
' -5（C4）离开 review-free 通道。

### 改动清单（按 B2 粒度，不虚报）
1. planPrintf 守卫本体（含注释引本 issue 与评审）。
2. :1790 "planner native printf forms match shell-visible execution"：语料 "printf '%s' '--help'" 移出，替换为断言它返回 approval_required 的用例。
3. :1305 "planner admits the reviewed direct command matrix"：同条命令移出 direct 表（或改断言拒绝）。
4. "-leading" 数据类（N-a 重述）：声明点三处中 :1758 是 **format 位**（buildPrintfCommand 的 formats 列表），printfStringConversionCount 本就拒绝 '-' 开头 format，**不动它**；数据位只有 :1697 与 :1814 两处，实际喂四个断言循环：:1727-1733（4x6 expectDirect linux）、:1747-1752（6x6 expectDirect macos）、:1831-1836（4x6 native 等价）、:1838-1843（6x6 native 等价），共 30/120 条断言翻转。**不删类**：四个循环保留全部六个类、按期望分支——连字符类断言 approval_required，其余断言 direct/等价；保住生成矩阵并测到守卫双极性。
5. expectNativePrintfEquivalent 失败打印（:1289）追加被测 printf 的 --version 首行（N7/N-c）：BSD printf 无 --version（usage 到 stderr、非零退出），诊断需容错——非零时改打 stderr 首行并注明 --version unavailable。
6. native 家族同类审计（N7）——复审已代跑，落为结论：planFamily(:654) 各族中 printf 是唯一把未校验用户词放进 native 二进制选项解析位的（argv.appendSlice(words[1..]) 无分隔符）；planGrep 在 pattern 前补 --、planLs 补 -- 且拒绝未分隔的选项形操作数、planWc 只收白名单旗标、planCat 仅裸 /bin/cat、planHeadOrTail 仅 -n 数字（boundedDecimal :1060）、planPwd 仅 /bin/pwd -P。词形守卫使 printf 与 ls 已有的规则一致。
7. TDD：先红 = 新拒绝断言用例在守卫落地前失败；既有两张 direct 表的调整与守卫同 commit 绿。

### 明确不做
- 不给 native argv 插 --（N1 中间方案：记录为备选，若词形拒绝的 UX 成本将来被投诉再启用；无条件插 -- 已被 N2 证伪——direct_command.zig 六处精确 argv 断言会全破）。**N-d 更正**：若将来启用插入式，-- 必须放在 format **之前**（printf -- '%s' --help），不是数据词前——已实测 printf '%s' -- --help 会被 bash 当额外数据打印 --，反而复现反向 parity 失败；该备选还需 uutils 的 before-format 实证（评审员的 musl 二进制经 docker bind mount 不可见，仍拿不到）。
- 不动 parity_review_free_commands（:2344/:2448）——拒绝发生在 planPrintf 内部，不改变清单（N3）。

## 失败 2：MCP conformance sep-2322-client-request-state（3 项）

### 取证步骤（按 B4 重排）
1. 本机 macOS 跑套件（tests/e2e/conformance/README.md：FX_SOUND=0 zig build && cd tests/e2e/conformance && npm ci && FX_SOUND=0 npm test）。3 项 macOS 全绿 → 直接得"平台相关"判定（当前最缺的证据）。
2. Linux 复现拿 check 级断言文本（R4 定案取证源）：CI 日志拿不到 check ID 的原因是 run.ts:33 mkdtemp 的 resultRoot 在 :65 finally 里删除、:81 的 pinned runner 输出只留场景级汇总。取证源 = pinned runner（@modelcontextprotocol/conformance 0.2.0-alpha.10）自身 stdout 的 check 清单：本机 macOS 先跑一次保留 resultRoot（或直接 npx pinned runner 对 fixture server）拿 3 项在 macOS 的 check 级结果；再在 linux 容器跑同一命令拿断言文本。
3. 证据齐后二选一：环境性/时序性 → baseline 加 3 项 + **必挂 issue 链接**（N4：baseline 全平台共享，环境性不许裸加，条目开始通过时 CI 会红，机制自带到期）；真实缺陷（SEP-2322 client 请求状态记账在 Linux 的 I/O/时序差异）→ 单开 issue 修复，baseline 同样挂链接。
4. （已完成）旧 main 取证：tt67wq/fx run 43348575668（CI #46，push event，sha 13713b9b6）E2E (MCP conformance) 失败签名逐字节一致（sep-2322-client-request-state: 2 passed, 3 failed; Total: 436 passed, 3 failed）——三失败早于 PR #2 两轮，前提成立。注意 gh 需 -R tt67wq/fx（该 run id 对 vercel-labs/fx 404）。

## 失败 3：codemode budget-expiry e2e（CI 超时）

### 根因（v2 行级更正）
不是"墙钟早于断言窗"，而是 harness 墙钟与产品预算同为 30s（host.zig:18 default_timeout_ms=30_000，e2e TIMEOUT=30_000）。runFx 超时不 throw：置 timedOut=true、SIGKILL、close resolve code=null → result.code!==0 与 elapsedS≈30 均意外"通过"，真炸在 follow-up 请求 TypeError（requests[1] 缺失）。预算到点后 fx 收尾再发一次请求必然略超 30s，本地压线、CI 必炸。

### 修法（评审员三选一取一）
采用选项 1（保窗改墙，最小且失败模式可读）：
- 该用例 runFx timeoutMs 30_000 → 60_000，并在 TIMEOUT 注释里写死时序不变量（R3）：runFx 以子进程 "close" 事件 resolve（eval-helpers.ts:514-545，stdio 全 pipe，等的是管道 EOF 不是 fx 退出）；排序 产品预算 30s < 断言窗 45s < 嵌套 sleep 60s <= harness 墙 60s，bun:test 用例级 90s(:242) 必须保持高于墙——防止后人"收紧 flake"把墙降到 45s 使测试在产品 30s kill 完成前假绿。
- 新增 expect(result.timedOut).toBe(false)：harness 抢跑时失败信息直接是 timedOut 而非 TypeError。
- follow-up 断言加护栏（R3）：先 expect(gateway.requests.length).toBe(2) 再解析 requests[1]，未来回归报"缺 follow-up"而非 TypeError；:238 的 Timeout 字符串断言保留。
- 时间窗 >20 / <45 **不动**（v1 的放宽到 <60 作废：与 sleep 60、墙钟 60s 三数同刻）。
- stretch（不阻塞本项）：查 ambient 预算可否经 @options timeout_ms（codemode_tool.zig:37-38 允许 1000..120000）在测试 env 里压到 5s，若可行用例整体掉到十几秒，缓解 shard 4 时长——作为后续改进单独立项，不混入本修复。

## PR 拆分（N6）
- 失败 1 修复 → type: bug。
- 失败 2、3 → type: maintenance。
- 两个小 PR 分别开，均基于 codemode-derived-surface 或 main 视改动面而定。

## 验收
- 失败 1：zig fmt --check src/ && zig build test（含新拒绝用例 + 两张表调整后全绿）；Linux 侧行为由 CI 验证（本地 macOS 无法复现 uutils 行为，评审员已实证 GNU 不复现，谁在 Linux 跑先红谁签 ready）。
- 失败 2：按取证结论落地后 CI 该 job 绿。
- 失败 3：本地 FX_SOUND=0 bun test codemode-admission.test.ts 全绿 + CI shard 4 绿。
