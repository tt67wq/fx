# T-36-impl implementation report (T-36-fix corrected version)

Task: ISSUE-36 — compress the codemode description into the 1024-byte
model cap, extend the cap test to gated_all, and align the script
parameter description wording (T-34-review F-1/F-2). This report replaces
the T-36-review-rejected version; corrections are marked below.

## Commits (T-36-impl + T-36-fix, in order)

- 5472dccf2 Add failing cap and wording pins for codemode description
  (red, incomplete: only the F-2 pins landed, see correction below)
- ec46a6290 Fold the codemode description under the model description cap
  (the 1011-byte compressed description; guard test changes were absent)
- 71a444941 Add T-36 implementation report (first version, partially wrong)
- 877ff08ec Prove the widened cap test and constant length pin fail on the
  1172-byte description (T-36-fix red)
- 699e47547 Compress the codemode description to the model cap and fix the
  guard pins (T-36-fix green)

## Corrections to the previous report (T-36-review findings)

- Correction 1 (report items 2 and 4): the first red commit did NOT widen
  the cap test to gated_all and did NOT update the length pin. The edit
  script aborted on an assertion before writing the file, so only the F-2
  pins landed, and the previous red-evidence.txt misattributed the failure
  to tests that were not in the tree. The T-36-review caught this. The
  guard changes are now genuinely in the tree (red 877ff08ec, green
  699e47547), with the honest two-test failure evidence.
- Correction 2: the script parameter description is 224 bytes after the
  F-2 fix, not the 241 bytes previously claimed.

## Final tree state (verified line by line)

src/builtins/tools.zig only; zero execution semantics; host.zig,
bridge.zig, discovery, catalog, and the model_tool_schema cap constant
untouched; the byte-exact registry hash coverage (all, which excludes
codemode) untouched and still passing.

1. Cap test widened: tools.zig "built-in tool descriptions fit the
   model-facing description cap" now iterates gated_all, so
   codemode_description and its property descriptions are checked against
   the cap.
2. Length pin: codemode_description.len <=
   model_tool_schema.description_max_bytes (constant, no magic number, so
   a future cap raise follows automatically). Comment states the real
   values and the ISSUE-36 reason.
3. Review item 3 adopted: "over it, text and console keep head and tail
   with omitted byte count" restores the text/console dual-stream
   subject; description is exactly 1024 bytes, which fits the cap (the
   pin is <=).
4. F-2: the script parameter description reads
   tools.call("tool_name", {args}); the "still works" string-form
   concession is gone. Pins select the property by name == "script", not
   by position index, so a future parameter addition cannot descope them.
5. Description: 1172 bytes / 169 words -> 1024 bytes / 144 words.

## Red proof (T-36-fix, 877ff08ec)

The description reverted to the T-34 1172-byte version while the guard
tests carry the fix. zig build test failed with exactly the two expected
failures (see red-evidence.txt):

- builtins.tools.test.built-in tool descriptions fit the model-facing
  description cap (1172 > 1024 through gated_all)
- builtins.tools.test.codemode description states the nested command
  budget truthfully (the <= cap pin fails on 1172)

Then the green commit restored the compressed description and everything
passes.

## gated_all guard effectiveness probe (acceptance 3)

With the guards green, the description was temporarily padded to 1192
bytes with two inert sentences and zig build test was run: the widened
cap test and the length pin both failed (plus the known command_runner
flake), proving the guard fires. The real description was restored
immediately after; the probe left no tree changes.

## Evidence per acceptance item

1. Red (two named test failures) precedes green; zig build test exit 0
   after one rerun: green run 1 and the probe run each hit the known
   command_runner flake ("runtime cancellation observed at the timeout
   deadline stays graceful"); the final rerun is all green.
2. zig fmt --check src/ exit 0; check-public-surface.sh and the four
   boundary scripts exit 0.
3. Cap test over gated_all green on the 1024-byte description; the
   1192-byte probe made it fail (evidence above); the length pin reads
   model_tool_schema.description_max_bytes.
4. F-2 pins green (object form present, "still works" absent, name-based
   property lookup).
5. FX_BENCH=1 ./zig-out/bin/fx help exit 0, stderr 0 bytes.
6. Red/green commits, this corrected report, and the rewritten
   red-evidence.txt.

## Semantics preserved (11 items + three pitfalls, all within the cap)

1. Default 30s wall clock and 1MiB capture cap
2. Past the cap, text and console keep head and tail with the omitted
   byte count
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

- Description: 1172 bytes / 169 words -> 1024 bytes / 144 words
- Script parameter description: 251 bytes string-form -> 224 bytes
  object-form (under the 1024 property cap)

## Compression trade-offs

Wording-level only; every clause survives. The searchTools("keyword")
inline example dropped (the searchTools(query) guidance clause stays);
"the full output is stored, readable with read_tool_result" compressed
to "read_tool_result reads the full output"; "Wrapping one tool call is
slower than calling it directly" compressed to "Wrapping one call is
slower than a direct call".
