# ISSUE-17 — codemode @options 助手声明去 pub

- **状态**: closed
- **发现时间**: 2026-11-12
- **来源**: codex 对 ISSUE-10 合并实现的复审（P3，fx-codex-1）
- **工作量**: 小

## 现象

src/tools/codemode/codemode_tool.zig 中 ISSUE-10 引入的六个声明
（options_header_prefix:320、ScriptOptions:322、EffectiveOptions:327、
OptionsParseError:332、parseScriptOptions:337、effectiveScriptOptions:396）
均标 pub，但文件外无任何引用（grep 复核），只有本文件 decode/call 与 in-file tests 使用。
违反 AGENTS.md「Keep pub surface area minimal」规约。

## 修法

六个声明去掉 pub（in-file tests 引用不受影响）。跑 zig build test 确认绿。

## 处置

- [x] 去 pub 并全量测试绿（唯一失败项为 command_runner 环境性 flaky，main 无改动基线同样失败，已归因）
