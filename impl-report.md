# ISSUE-18 implementation report

Branch `T-18-impl` in `/Users/example/fx-piX`, based on `3253b6e2c`.
Implements the finalized plan (Option A) from `/Users/example/fx-piX/issue18-fix-plan.md`
with no redesign. Forensics in `issue18-investigation.md` (branch `T-18-plan-a`).

## Commits, in TDD order

| commit | content |
| --- | --- |
| `d7ebb28d4` | red: `tests/e2e/mcp-mrtr.test.ts` plus its CI wiring |
| `1badc9945` | pins: test-only `test` blocks in three `src/mcp/` files |
| `e1c35992c` | green: capability declaration in `src/core/cli/cli_ask.zig`, baseline removal, updated expectations |

## Red evidence (before the fix)

Captured against a verified unfixed binary (`grep` confirmed `cli_ask.zig` still
passed `ctx.mcp_elicitation_capabilities`), corrected fixture:

```
Expected: 2
Received: 1
(fail) a headless input_required round is answered by a second tools/call
Expected: 2
Received: 1
(fail) a headless input_required round without requestState omits the field
(pass) an unrelated call between MRTR rounds carries no retry fields
(pass) a result without resultType is never retried
 2 pass  2 fail
```

The two failures are exactly the missing retry round. The two passes are the
boundary guards, which pin that the fix must not widen MRTR into tools that
never asked for input. Full text at `/tmp/red-evidence.txt`.

One correction during the red phase: the first fixture draft double-encoded the
`echo_state` response body (an already-stringified payload was passed through
`JSON.stringify` again), so fx could not parse round 1. That produced red for
the wrong reason on one test. The fixture was fixed and red was re-captured
against the unfixed binary, shown above.

## Green evidence (after the fix)

```
 4 pass  0 fail  33 expect() calls     tests/e2e/mcp-mrtr.test.ts
```

## Acceptance, item by item

| requirement | result |
| --- | --- |
| `zig fmt --check src/` | clean, after `zig fmt src/` touched nothing but my files |
| `zig build test` | **9929 pass, 0 fail** with the fix applied |
| new e2e, red to green | 2 fail then 4 pass, same file, same fixture |
| conformance scenario, check level | `sep-2322-client-request-state` **5 passed, 0 failed** (`--output-dir /tmp/t18final`) |
| full conformance suite, no baseline suppression | **440 passed, 0 failed, 0 warnings**, plus `2025-11-25` initialize / tools_call / sse-retry all PASSED, `npm test` exit 0 |
| baseline entries removed | three `sep-2322-client-request-state:...` lines gone; `client: []`, header keeps the rule that removal belongs with the fix |
| built binary driven by hand | `./zig-out/bin/fx ask --json` against a logging MRTR server through the fake Gateway: exit 0, session completed, both tool calls `status: success`, stderr only `Selecting MCP tool ...` and `MCP: ...` |
| `src/mcp/` and `tests/tla/mcp/` untouched behaviorally | no behavior change; see the red line note below |
| no personal paths in new fixtures | none; the test uses `mkdtempSync(tmpdir())` |

## H4 shape recheck (contract item 5)

Round 2 as the fixed binary actually wrote it:

```
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{
  "_meta":{"progressToken":5,"io.modelcontextprotocol/protocolVersion":"2026-07-28",
           "io.modelcontextprotocol/clientCapabilities":{"elicitation":{"form":{},"url":{}}},
           "io.modelcontextprotocol/clientInfo":{"name":"fx","version":"0.0.16"}},
  "name":"test_mrtr_echo_state","arguments":{},
  "inputResponses":{"confirm":{"action":"cancel"}},
  "requestState":"{\"nonce\":\"n1\",\"originalId\":4}"}}
```

Round 1 was `id=4`, so the id differs. `inputResponses` and `requestState` are
top level in `params`, `_meta` carries neither, the answer rides under the
server's own key `confirm`, and the state is the server's bytes unchanged. H4 is
closed, and the new e2e asserts this so a future move into `_meta` fails there.

## Behavior change beyond the plan's file list, needs reviewer attention

Option A was implemented as written: `fx ask` now declares
`.{ .form = true, .url = true }` at `src/core/cli/cli_ask.zig:1851` regardless of
TTY, while `mcp_input_responder` at `:1155` keeps its TTY gate, so an interactive
run still asks the user and only a headless run answers cancel.

Two existing headless tests in `tests/e2e/mcp-stdio.test.ts` pinned the old
outcome, one of them with the intent comment "nothing is made up and sent back to
the server", and two more asserted that a headless run declares
`clientCapabilities: {}` (`assertModernWire` in `mcp-http.test.ts:208` and
`mcp-stdio.test.ts:1982`). The plan's regression inventory did not list these.
With the capability declared, all four are statements about the defect, so I
updated them to pin the new behavior instead of deleting them:

- `assertModernWire` and the stdio twin now expect
  `{ elicitation: { form: {}, url: {} } }`.
- "noninteractive fx ask returns typed input-required without fabricating a
  continuation" became "noninteractive fx ask cancels an input_required round
  without inventing an answer". Its protective core is kept and stated more
  strictly: the answer must equal exactly `{ confirm: { action: "cancel" } }`, so
  fx still cannot put words in the user's mouth, and the state must come back as
  `"opaque"` under a new id.
- "fx ask with no way to ask tells the model the server wanted input" became "fx
  ask with no screen cancels the question and reports the server's answer", now
  asserting the model never sees `the server asked for input fx can't give`.

Net user-visible effect: a headless `fx ask` whose server asks for input now
finishes the call by cancelling the question, instead of failing it. A server
that sees the new declaration may also send a URL elicitation to a headless run,
which is likewise answered cancel.

## Red line note

The contract says "不动 src/mcp/" while its item 2 asks for focused tests in
`src/mcp/core/mrtr.zig` and `src/mcp/protocol/mrtr.zig`. I read these as: no
behavior change in `src/mcp/`, tests still belong inline per `tests/AGENTS.md`.
Commit `1badc9945` is therefore **84 added lines and zero changed lines** across
three files, all of them inside new `test` blocks. No import was added or
removed, so the `src/mcp/` boundary scripts and `tests/tla/mcp/` are untouched,
and the pin explicitly asserts that an undeclared capability still ends the chain
with `unsupported_input`, which is what Option A leans on rather than changes.

## Not verified locally, and why

`tests/e2e/mcp-stdio.test.ts` cannot run in this environment: every test that
starts the modern stdio fixture fails at a uniform 3.1s startup timeout with 0
`tools/call` reaching the server. This is pre-existing and unrelated to the fix,
proved two ways: the same failure appears with the pre-fix binary and an
untouched test file, and the same signature covers `fx mcp call` tests that never
reach `fx ask`. `tests/e2e/node_modules` had also been wiped when this worktree
was recreated, so `bun install` was needed first. Consequently the two updated
stdio tests in that file are **not locally verified**; they must be confirmed by
CI, which is authoritative. `tests/e2e/mcp-http.test.ts`, which exercises the
same headless wire path over a working HTTP fixture, does pass, except one test,
"fixed-length sse responses complete without waiting for the connection to
close", which fails with `ECONNRESET` at baseline too (verified with the pre-fix
binary and the untouched file), so it is also pre-existing and not mine.

## Docs obligation

Per `AGENTS.md`, the fx.sh/docs MCP page needs a line: a headless `fx ask`
declares elicitation form and url and answers a question it cannot show with
cancel, so a multi round-trip request completes instead of ending unsupported.
I have no access to the private manual repo from here, so this belongs in the PR
description's `## Docs` section.

## Suggested follow ups, none blocking

1. H5 from the forensics is still open: the no-UI fallback in
   `src/core/mcp_host/runtime.zig:1235` to `1249` only answers a round whose
   requests are all elicitations, so a mixed elicitation plus sampling or roots
   round in a headless run still ends the call. No fixture produces that shape
   today, which is why no test covers it and why I did not change it.
2. That mixed-round case is worth a fixture mode plus a test, so the boundary is
   pinned rather than assumed.
3. Re-measure the shard weight for `mcp-mrtr.test.ts` after its first CI run;
   local wall time is 0.32s for four tests, set to 2.
