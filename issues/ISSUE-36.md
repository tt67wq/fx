# ISSUE-36 — codemode 描述超模型侧 1024 字节帽被截断，帽测试漏检 gated_all（T-34-review F-1/F-2）

- **状态**: fixing
- **发现时间**: 2026-11-21
- **来源**: T-34-review（fx-pi4，APPROVED 附高优先发现 F-1），评审对象 T-34-impl@73ecd3f59
- **工作量**: 小
- **关联**: ISSUE-34（三则坑前置已落地）、ISSUE-29/28（min 预算真相句被腰斩）、ISSUE-23b

## 现象

1. **F-1（高）**：模型侧描述帽 `model_tool_schema.description_max_bytes = 1024`（src/core/tooling/model_tool_schema.zig:4），超出保留前 1009 字节 + `... [truncated]`（:66-74）。三条出网路径都过它：chat-completions tools 数组（chat_completions_protocol.zig:570）、builtins advertisement（gateway.zig:301-336）、codemode bridge 注入的 run_script schema（bridge.zig:1333）。codemode_description 现 1172 字节，在 chat-completions 路线被截：三则坑在前 1009 内（T-34 目标达成），但 **min(requested, remaining budget) 真相句被腰斩、Finish with text()/top-level return is invalid 收尾规则、searchTools/describeTool 指引到不了模型**。基线 1173 同样越界（非 T-34 引入）。
2. **帽测试漏检**：「描述必须放进模型帽」测试只遍历 `all`（tools.zig:932-936），codemode 在 `gated_all` 漏检，从来没人报警。
3. **F-2（中）**：script 参数描述（tools.zig:778，251 字节完整可见）仍写 `tools.call("tool_name", "{json args}") still works` 旧口径，与正文「arguments are objects」并列把模型往字符串形态带回一格。

## 处置

- [ ] codemode_description 收到 <=1024 字节（优先，零截断）；若语义保全做不到，则必守句全部排进前 1009 字节并在报告论证取舍。**所有钉死语义（三则坑 + 11 项既有语义）不得被截断。**
- [ ] 帽测试覆盖面从 all 扩到 gated_all（含 codemode），让这条线以后自动兜住。
- [ ] F-2：script 参数描述改对象形态示例，去掉 still works 旧让步语气。
- [ ] 长度钉与 byte-exact 哈希（如涉及）同步重钉；净字数约束沿用 C4 精神。
