# ISSUE-16 — codemode 具名调用写法 tools.read_file({...})

- **状态**: open
- **发现时间**: 2026-11-10
- **来源**: fx codemode 与 pi 1.5.1 源码对比
- **工作量**: 小

## 现象

tools.call(name, "{json args}") 要求模型手写 JSON 字符串参数，嵌套引号与转义
易错，错误要到嵌套准入甚至执行时才暴露。

pi 的对应行为：按工具生成具名函数 await tools.read_file({...})，直接传对象，
标识符经 toCodemodeIdentifier 转换。

## 修法

在 installBindings 与 installCallShim 处按 tools.list 的 schema 生成具名函数，
转发到同一 native 入口。行号捕获（shim 读 Error.stack）与准入路径不变；
tools.call 保留兼容，不删旧写法。

## 处置

- [ ] 按注入 schema 生成具名函数
- [ ] 转发同一 native 入口，行号捕获不变
- [ ] tools.call 保留兼容
- [ ] Zig 单测：具名调用与 tools.call 走同一准入
