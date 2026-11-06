# T-5 — G2 尺寸 spike 报告（BLOCKED→由 conductor 代跑完成实测）

## 环境
- macOS arm64（本机 = 生产同架构），zig 0.17（zig cc / zig ar / translate-c）
- quickjs-ng v0.17.0（GitHub release tarball，/tmp/t5-spike/qjs）
- C flags：-Os（ReleaseSmall 口径）/ -O2（ReleaseSafe 对照）、-DNDEBUG -D_GNU_SOURCE、-fno-stack-protector -fno-asynchronous-unwind-tables -fno-unwind-tables
- 宿主 flags：-O ReleaseSmall/-ReleaseSafe -lc -fno-stack-check -fno-stack-protector -fomit-frame-pointer -fno-unwind-tables -fno-error-tracing（与 fx build.zig 同口径：link_libc、无栈保护）
- 来源标注：codex 沙箱无网络且 worktree 只读，流水线由 codex 用 stub 验证（b-stub 系列）；quickjs 真实源码下载、编译、测量由 conductor 在主终端按 codex 的 /tmp/t5-repro.sh 执行

## 尺寸表（strip -x 后；字节）
| 二进制 | unstripped | stripped |
|---|---|---|
| a-small（空 main，ReleaseSmall） | 52424 | 50208 |
| b-small（A + QuickJS，-Os） | 722744 | 672800 |
| a-safe（ReleaseSafe 对照） | 419544 | 353168 |
| b-safe（A + QuickJS，-O2） | 1389784 | 1206384 |

增量：**ReleaseSmall 口径 622592 字节（约 608KB，stripped）**；ReleaseSafe 口径 853216 字节（约 833KB）。

裁剪尝试：
- -ffunction-sections -fdata-sections + -dead_strip：0 收益（622592 不变，JS_Eval 可达全引擎）
- -Oz：仅省 8 字节（622584）
- quickjs-ng v0.17.0 无有效尺寸开关：cutils/libbf 已并入引擎源（无独立 libbf 可去），QJS_DISABLE_PARSER 不可用（我们要解析），QJS_BUILD_LIBC 默认 OFF 未计入
- b-small 运行 'hello' JS 求值退出 0，宿主验证通过

## 结论
**不通过（NO-GO，按当前方案）**：实测 608KB > 450KB 门（超 158KB），且 > 546KB 生产余量（5.98MiB 候选 + 608KB = 6.59MiB > 6.5MiB 硬顶，超约 62KB）。ReleaseSafe 口径 833KB 更不可行。

裁剪空间已探明为无（dead_strip/Oz/编译开关全无效）。按方案第 2 节失败处置：**方案终止**，除非维护者接受以下之一：
1. 换更小的引擎（如 Bellard 原版 quickjs 老版本，未测，需重新 spike；但 ng 是活跃安全跟进面，换老引擎与风险 3 的缓解冲突）
2. 上调 PGSO 生产上限（不可协商，方案已写明）
3. 缩小 codemode 功能面没有意义——608KB 是引擎常量，与绑定面无关

## 可复现命令
bash /tmp/t5-repro.sh（源码已在 /tmp/t5-spike/qjs，重跑编译+测量约 1 分钟；关键 flag：-Os ReleaseSmall 口径、dead_strip 对照）
