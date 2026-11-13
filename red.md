# T-14-1 先红后绿证据

## 先红（红测试 commit）

红测试 commit：（见 git log，本文件随红测试一起提交）

zig build test 输出摘要（2026-11-13，分支 fx-pi1，base 合并 main 7fa4228c0 之后）：

    src/core/config/config_runtime.zig:2776:40: error: use of undeclared identifier 'codemodeDerivedSurfaceEnabled'
    src/core/config/config_runtime.zig:2797:40: error: use of undeclared identifier 'codemodeDerivedSurfaceEnabled'
    src/tools/codemode/bindings_tests.zig:21:26: error: root source file struct 'tools.codemode.bridge' has no member named 'sandboxFace'
    error: 3 compilation errors

预期内的编译红：新 API（config gate 的 codemode_derived_surface_enabled 字段、
codemodeDerivedSurfaceEnabled accessor、InvalidExperimentalCodemodeDerivedSurfaceType
错误、bridge.sandboxFace、Tool.sandbox_reachable 字段）均不存在。

## 后绿

（实现完成后填写 green commit SHA）
