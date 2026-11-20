# T-29 Docs 节（供 conductor 放入文档 PR 描述的 ## Docs）

按 CONTRIBUTING.md「Changes to the manual」格式：页 URL + 节 + 增/改/删原文。
私有手册仓库不可推（已确认），以下为实现侧核对过的精确改动文本。

## Docs

- https://fx.sh/docs/codemode（codemode 页），"Tool surface" 节：把「the sandbox sees
  glob_files, grep_files, read_file, and run_command; everything else is invisible」
  替换为两态分述：
  「With the derived surface off (the default), the sandbox sees four tools:
  glob_files, grep_files, read_file, and run_command; everything else is invisible.
  With experimental.codemode_derived_surface on (profile-only, default off), it also
  sees write_file, edit_file, web_fetch, ask_user_question, and vision, plus the
  run_script primitive; run_command maps to the registered shell tool. Every nested
  call still passes the same permission checks as a direct call.」

- https://fx.sh/docs/codemode，新增 "run_script" 小节（在工具面之后）：
  「run_script runs shell or python through an fx-picked interpreter: python code
  lands in an fx temp file run via the fixed python3 <path> argv shape, shell code
  runs as the command line. An optional workspace file is exposed to the script as
  CTX_FILE (bounded to 1MiB). Model text never becomes an interpreter option token;
  unknown fields are rejected before admission. timeout_ms is clamped to
  1000..120000.」

- https://fx.sh/docs/codemode，"Catalog and discovery" 节（无则新增）：
  「On the derived surface, tools.list() is budgeted by
  context_limits.codemode_catalog_bytes (16KiB default; override with
  --context-limit codemode_catalog_bytes=BYTES|off). The four core tools always stay
  listed (tier zero), then mutation tools (tier one), then the rest (tier two); a
  triggered budget drops later entries with an omitted list and a hint naming
  observed/effective bytes and the source. searchTools(query) searches the full
  surface by name, parameter, and description, scored, with an optional {limit: N}
  (default 8); describeTool(name) returns one full {name, description, parameters}
  schema and throws with up to five did-you-mean suggestions for an unknown name.」

- https://fx.sh/docs/codemode，"Output limits" 节：补/改为
  「Script output has a 1MiB capture cap; past it, text and console keep the head and
  tail with an omitted byte count, and the full captured output is stored and
  readable with read_tool_result. A failure body carries the same capture markers.
  The @options line (timeout_ms and max_output_tokens, JSON) as the first non-empty
  line declares a bigger budget: timeout 1000..120000 ms hard-capped;
  max_output_tokens hard-capped at 262144 (4 bytes per token, clamped to the 1MiB
  capture cap).」

- https://fx.sh/docs/codemode，"Timeouts" 节：补/改为
  「A script runs on a default 30 second wall-clock budget. A nested run_command gets
  min(requested, remaining script budget): the remaining budget is sampled when the
  nested call starts, and the command's own timeout counts from its own start. A
  nested command whose timeout lands at or before its yield waits for the timeout
  kill, so the budget-boundary outcome is a deterministic timeout failure, not a
  running snapshot. On timeout the failure headline names the elapsed wall, the
  effective budget and its source (default or @options), and the @options fix; the
  last returned nested call's output rides in the failure body's excerpt slot.」

- https://fx.sh/docs/configure-fx/permissions（T-17 的 dash 数据词 Docs 承诺，
  源：issues/archived/ISSUE-17-plan-v2.md 评审3 C1 补记）：在 review-free 命令
  说明处新增一段：
  「printf with a dash-leading data word (for example printf '%d' -5) leaves the
  review-free channel: the word-form guard sends it to automatic security review on
  every call. With no reviewer configured, that review is unavailable and the
  command is denied, where it previously ran review-free. This is the conservative
  cost of refusing to parse printf option semantics; the guard matches word shape,
  not word meaning, and behaves the same on macOS and Linux.」

- https://fx.sh/docs/mcp（T-18 遗留一句话，源：T-18-impl/impl-report.md「Docs
  obligation」）：在 elicitation/headless 说明处新增一句：
  「A headless fx ask declares elicitation form and url support and answers a
  question it cannot show with cancel, so a multi round-trip request completes
  instead of ending unsupported.」
