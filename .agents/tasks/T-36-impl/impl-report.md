# T-36-impl implementation report

Task: ISSUE-36 — compress the codemode description into the 1024-byte model cap, extend the cap test to gated_all, and align the script parameter description wording (T-34-review F-1/F-2).

## Commits

- 5472dccf2 Add failing cap and wording pins for codemode description (red)
- (this commit) Coerce the codemode description under the model cap (green)

## Change

Single file: src/builtins/tools.zig. Description strings and pins only;
zero execution semantics, no host.zig/bridge.zig touch, the 1024 cap
constant in model_tool_schema.zig untouched.

1. F-1: codemode_description compressed from 1172 to 1011 bytes (142
   words, down from 169) — fits the cap with 13 bytes of margin and zero
   truncation, so no argued tiering of sentences into the first 1009 was
   needed.
2. Cap test widened from all to gated_all, so the codemode description
   and its schema property descriptions are checked against the cap from
   now on.
3. F-2: the script parameter description now reads
   tools.call("tool_name", {args}) and drops the "still works" string-
   form concession; new pins hold the object form and forbid the old
   wording.
4. Length pin moved from <=1172 to <=1024. The byte-exact registry hash
   covers all, which excludes codemode (T-34 established this), and the
   green run confirms it still passes, so no hash re-pin was needed; the
   script parameter description change rides no hash either.

## Semantics preserved (11 items + three pitfalls, all within the cap)

1. Default 30s wall clock and 1MiB capture cap ("Defaults: 30s wall
   clock, 1MiB capture cap")
2. Past the cap, head and tail kept with the omitted byte count
3. Full output readable with read_tool_result
4. read_tool_result readback (same clause, naming the tool)
5. @options as first non-empty line with the exact JSON shape
6. timeout 1000..120000 ms hard-capped
7. Output 4 bytes per token clamped at 1MiB
8. A declared budget is the script's wall clock
9. Nested run_command gets min(requested, remaining budget) from its own
   start (pinned verbatim)
10. Finish with text(your short summary); top-level return is invalid
11. Wrapping one call is slower than a direct call; tools.list() may be
    a budgeted subset, searchTools(query) searches the full surface,
    describeTool(name) returns one full schema

Three pitfalls: confirm names via searchTools, never from memory; no
Node.js API (no import/require of fs or process, no top-level tool
functions); arguments are objects with the run_command example.

## Byte/word comparison

- Description: 1172 bytes / 169 words -> 1011 bytes / 142 words
- Script parameter description: 251 bytes, string-form example -> 241
  bytes, object-form example (well under the 1024 property cap)

## Compression trade-offs

Wording-level only; every clause survives. Examples: "Run JavaScript in
a sandbox" -> "JavaScript sandbox"; the searchTools("keyword") inline
example dropped (the searchTools(query) guidance clause stays); "the
full output is stored, readable with read_tool_result" -> "read_tool_result
reads the full output"; "Wrapping one tool call is slower than calling it
directly" -> "Wrapping one call is slower than a direct call".

## Evidence per acceptance item

1. Red before green: red-evidence.txt. zig build test: green run 1 hit
   only the known command_runner flake ("runtime cancellation observed
   at the timeout deadline stays graceful"); rerun exit 0, all green.
2. zig fmt --check src/ exit 0; check-public-surface.sh and the four
   boundary scripts exit 0.
3. Cap test over gated_all green; codemode description 1011 <= 1024; the
   budget-truth pin, three-pitfall pins, and the 11-item semantics all
   still pinned and green.
4. F-2 pins green (object form present, "still works" absent).
5. FX_BENCH=1 ./zig-out/bin/fx help exit 0, stderr 0 bytes.
6. Red/green commits and this report.
