# T-32-review 评审报告 — 嵌套字符串参数 coercion（ISSUE-32）

- 评审者：fx-pi2（未参与实现，实现者 fx-pi3，作者独立）。
- 评审对象：T-32-impl 分支，绿 **1e0776143**（红 15fbf58c7，产物 fe6c8f769），基线 5f4856177。
- 契约：.agents/tasks/T-32-impl/task.md；报告/红证据：同目录。
- 评审方式：逐行读 bridge.zig diff + 权限链独立核 + schema 判定核 + 探针实测 vision/web_fetch +
  在 fe6c8f769  detached worktree 自跑机械核验（fx-pi3 主工作树已被推进到 T-34/T-36 线，
  非评审目标，故另建 detached worktree 核精确 commit）。

## Verdict: **approve**（附 1 条显著非阻塞观察：vision/web_fetch coercion 与评审清单措辞不一致）

coercion 安全面成立（只包装不放宽，admission 看到与对象调用完全相同的 payload，无绕过），
run_command/read_file/glob/grep 正例正确，对象路径字节级零回归，多 required 工具保留 ISSUE-24
报错，红绿链真实，机械核验全绿，红线全守。唯一观察：vision/web_fetch 按 schema 单一 required
string 规则被 coerce，与评审重点 1 清单将其列为「不 coerce」不一致；该差异良性（见下），不阻塞。

## 一、coercion 正确性 ✔
- run_command 裸字符串 → wrapPrimaryParameter("run_command","command",s) 得 {"command":s} →
  走 canonicalRunCommand 同一管线补 action:run → {"action":"run","command":s}，与对象调用
  {command:s} 产物逐字相同。admission（bridge.call:152 requestPermissionOutcome）消费
  canonical.name+canonical.arguments_json 构造的 nested_call，字符串路径与对象路径完全一致。
  独立核权限链无绕过：coercion 发生在 admission 之前的 canonicalization 层，command 注入面
  与对象调用一致（同一 command 字符串）。✔
- primaryStringParameter 从 model_schema.input_schema.required 读（len==1）+ 对应 property
  json_type==.string，返回字段名；否则 null。无第二套硬编码映射（run_command 的 command 字段
  是 task 明定的 shell 主参数特例，因其走 action 形式）。✔
- 多 required 工具实测不 coerce（探针）：write_file(path+content)、edit_file(3 字段) → passthrough；
  run_script(language+code) → InvalidToolArguments「run_script arguments must be a JSON object」
  （ISSUE-24 原文保留）；ask_user_question(questions array，json_type≠string) → passthrough。✔
- bareStringArgument：parseFromSliceLeaky catch return args_json（非 JSON text 视为裸字符串）；
  parsed≠.string → null（number/array/object/bool/null 保持既有行为）；.string → 值。
  host toolsCallCallback 仅对 object 做 JS_JSONStringify，字符串原样透传（raw），故 raw text 与
  JSON-quoted string 两支均 coerce。对象参数字节级透传（指针相等单测 args.ptr==canonical.ptr）。✔
- 边界：看似 JSON 的裸字符串（如 "123"）raw 到达解析为 number → 不 coerce，符合「数字保持既有行为」；
  sandbox raw-string 约定下此类值与数字 argument 不可区分，保守保持既有行为，合理。

## 二、安全面 ✔
coercion 只包装不放宽：包装后的对象走同一 canonicalization → admission → permissions 链。
不存在字符串路径绕过对象路径校验。run_command 字符串与对象产生相同 admission payload；
read_file/glob/grep 包装后走各自 decoder 同一校验。探针实测 vision/web_fetch 见观察 1，均无绕过。

## 三、红绿链 ✔
- 红 15fbf58c7 仅 bridge.zig 测试（impl 函数计数 0），4 新测试实测红：
  read_file/glob/grep coerce 期望 {"path":...} 实得 "src/main.zig"；run_command coerce failed；
  （另含无关 native_keychain 预存 flake，红证据注明）。先于绿（merge-base 确认）。
- 绿 1e0776143 增 bareStringArgument/primaryStringParameter/wrapPrimaryParameter（计数 3）+ canonicalNestedCall 接入。
- 正例（run_command/read_file/glob/grep）、不可 coerce（run_script 原文/write_file passthrough）、
  对象零回归（指针相等）各自断言，自跑全 OK。

## 四、e2e ✔
codemode-admission.test.ts（既有已分类文件）增「nested tools.call accepts a bare string argument」：
一个脚本内 run_command 字符串 + read_file 字符串两支，断言结果含 hello-coerce 与 alpha notes。
自跑该条绿；全套 29 pass / 0 fail。未新建 root e2e 文件。

## 五、机械核验（自跑，detached worktree @fe6c8f769）
1. zig build test 全绿：独立 --cache-dir /tmp/t32r-cache2 全量重跑，22/22 steps succeeded，
   10287/10294 passed（7 skipped，0 failed）；主二进制直接复跑 10030 pass/2 skip/0 fail，
   4 条 coerce 单测 OK。本轮无 command_runner flake。
2. zig fmt --check src/ 退 0；check-public-surface.sh 与 agents/compactor/indexer/recovery 四边界各退 0。
3. FX_BENCH=1 ./zig-out/bin/fx help 退 0、stderr 0 字节。
注：fx-pi3 主工作树 HEAD 已被推进到 7ea4f19da（T-34 合并）且 builtins/tools.zig 有未提交改动，
非评审目标 fe6c8f769；评审在 fe6c8f769 detached worktree 独立核验，核后已清理该 worktree。

## 六、红线 ✔
- host.zig 零触碰；builtins/tools.zig 描述零触碰（diff name-only 仅 bridge.zig + codemode-admission.test.ts + red-evidence）。
- catalog/tests/tla 零触碰；admission/permissions 判定文件零触碰（coercion 在 bridge canonicalization 层）。
- 无新 settings/CLI/env；无 emoji；无个人路径（diff grep 退出 1）。zig fmt 后提交。

## 七、观察 1（非阻塞，建议 conductor  reconcile 契约措辞）
评审重点 1 清单将 vision/web_fetch/ask_user_question 与 run_script/write_file/edit_file 并列为
「多 required 字段工具…确不 coerce、保留 ISSUE-24 字段级报错原文」。但按 schema：
- vision required=[focus]（单一 string），web_fetch required=[url]（单一 string）→ primaryStringParameter
  返回 focus/url → **被 coerce**（探针实测：vision→{"focus":"bare"}，web_fetch→{"url":"bare"}）。
- ask_user_question required=[questions]（array，json_type≠string）→ 不 coerce（符合清单）。
- write_file/edit_file/run_script 多 required → 不 coerce（符合清单）。
即清单把 vision/web_fetch 误标为「多 required」；实现忠实执行 impl task 的权威规则
（「主参数名取自 schema」「schema 无明确单一主参数的工具不 coerce」），vision/web_fetch 恰有单一
required string 主参数，故 coerce。
影响评估（良性，不阻塞）：
- vision {"focus":s} 下游 parse_vision_request 因 object.count()≠2（缺 image source）→
  InvalidVisionRequest，仍拒绝，fix 句「Send focus and exactly one of paths or image_ids」与改前
  InvalidVisionJson 的 fix 句相同；仅 error 名变（InvalidVisionJson→InvalidVisionRequest），无静默成功、无绕过。
- web_fetch {"url":s} 是合法 web_fetch 调用（url 为其唯一字段），正常走 admission 后执行，有益无害。
建议：conductor  reconcile 评审清单措辞（vision/web_fetch 实为单一 required string）；若产品上
希望 vision 不 coerce，可在 primaryStringParameter 增 min_properties>1 守卫（vision min_properties=2），
但当前行为安全且 web_fetch coercion 有益，本轮不要求返工。

## 八、结论
approve。coercion 安全面与正确性成立，红绿真实，机械核验全绿，红线全守。观察 1 为契约措辞与
schema 规则的良性不一致（vision/web_fetch 被 coerce），无安全回归、无静默成功，建议 reconcile
措辞或按需加 min_properties 守卫，不阻塞本轮。
