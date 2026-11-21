# T-32-impl implementation report

Task: ISSUE-32 — nested tools.call string arguments auto-wrap onto the schema primary parameter.

## Commits

- 15fbf58c7 Add failing tests for nested bare-string argument coercion (red)
- 1e0776143 Coerce nested bare-string tool arguments onto the schema primary parameter (green)

## Change

Single file for the behavior: src/tools/codemode/bridge.zig, canonicalNestedCall.

- run_command with a bare string: the string wraps onto the shell tool's
  command field, then takes the same canonicalRunCommand path an object
  call takes, so the action is added and admission sees the identical
  payload as an object call.
- Other registry-backed tools: primaryStringParameter reads the tool's
  model schema (single required field, string type) and wraps the string
  onto that field name. No second hardcoded mapping. Tools without one
  clear primary parameter (run_script requires language+code, write_file
  requires path+content, edit_file three fields, vision/web_fetch/
  ask_user_question were checked) pass through untouched and keep the
  ISSUE-24 field-level rejection.
- The sandbox hands a script string through raw (host.zig stringifies
  only objects), so bareStringArgument treats a JSON-quoted string and
  non-JSON text as the bare string; any other JSON value (number, array,
  object) keeps the existing behavior. Object arguments pass through
  byte for byte (pinned by a pointer-equality unit test).

Red lines honored: host.zig untouched, builtins/tools.zig descriptions
untouched, admission/permissions path unchanged (the wrapped object
walks the same canonicalization pipeline), no settings/CLI/env added.

## Evidence per acceptance item

1. Red before green: red-evidence.txt captures the failing run; final
   zig build test exit 0 (10038 tests: 10036 pass, 2 skip).
2. zig fmt --check src/ exit 0; check-public-surface.sh and the four
   boundary scripts (agents, compactor, indexer, recovery) exit 0.
3. Coercion positives (run_command, read_file, glob_files, grep_files),
   non-coercible keeps the verbatim ISSUE-24 detail (run_script string
   keeps "run_script arguments must be a JSON object"; write_file string
   passes through), object path zero change: all green in bridge.zig
   unit tests. e2e: codemode-admission.test.ts "nested tools.call
   accepts a bare string argument" green against the freshly built
   binary (full file: 29 pass).
4. FX_BENCH=1 ./zig-out/bin/fx help exit 0, stderr 0 bytes.
5. Red and green commits above; this report.

## Notes

The e2e drove the real binary and exercised both coercions end to end
(run_command string and read_file string inside one script); the tool
result contains the command output and the file content.
