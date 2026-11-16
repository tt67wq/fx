# ISSUE-18: MCP conformance SEP-2322 client request-state checks fail (real defect)

## Symptom

The E2E MCP conformance job fails 3 of 5 checks of scenario `sep-2322-client-request-state` on every run (Linux CI), with scene-level signature `2 passed, 3 failed`. Forensics (issues/ISSUE-17.md, failure 2 section) reproduced the same check-level result on macOS and Linux:

| check id | macOS | Linux |
| --- | --- | --- |
| sep-2322-client-parallel-isolation | SUCCESS | SUCCESS |
| sep-2322-default-result-type-complete | SUCCESS | SUCCESS |
| sep-2322-client-request-state-echoed | FAILURE | FAILURE |
| sep-2322-client-jsonrpc-id-different | FAILURE | FAILURE |
| sep-2322-client-no-state-omitted | FAILURE | FAILURE |

All three failures report `Tool was not called by client or MRTR flow not completed`. Signature is byte-identical to old main CI (tt67wq/fx run 43348575668, CI #46, sha 13713b9b6), predating PR #2 by two rounds.

## Diagnosis

Real defect, not environmental: the check set and messages are identical across macOS (Darwin arm64, node 26, bun 1.4.2, ReleaseSafe binary) and Linux (node:22-bookworm container, node 22, bun 1.4.4, cross-compiled aarch64-linux-gnu debug binary), ruling out platform-specific I/O or timing. fx's conformance adapter layer mis-accounts SEP-2322 MRTR (may-request-tool-result) request state: the echoed request state, differing jsonrpc id, and no-state-omitted MUST requirements all fail.

## Fix direction

Fix the adapter's SEP-2322 MRTR request-state bookkeeping so all three MUST checks pass, then remove the two baseline entries that point here (they self-expire: when a check starts passing, CI flags the stale baseline entry).

## Repro caveats (from T-17-impl-2 forensics)

- The Linux leg used a cross-compiled aarch64-linux-gnu debug fx inside node:22-bookworm, not CI's ubuntu-24.04 ReleaseSafe build; treat the Linux result as supporting evidence, CI remains the authoritative environment.
- Mounting only the conformance subdirectory into the container makes the client exit 1 and all 5 checks fail falsely; mount the full result root.
- CI logs only carry scene-level summaries (the runner's resultRoot is deleted in its finally), so check-level evidence must come from a local run with the resultRoot preserved.

## Decision recorded (ISSUE-17 D3)

baseline-with-link: expected-failures.yml carries the three checks with this issue as the reason link until the fix lands.

## Resolution (closed)

Fixed in merge 06300b549 (branch T-18-impl, merged 2026-11-16). Root cause (verified by wire capture): headless fx ask declared no elicitation capability in initialize, so the MRTR chain ended with unsupported_input on the first input_required answer and the retry round never reached the server. The wire layer was already correct.

Fix (Option A): src/core/cli/cli_ask.zig declares elicitation form and url for headless runs; the question screen stays TTY-gated, so a run without a UI answers each question with exactly {action: cancel} and the multi round-trip request completes. src/mcp/ behavior unchanged (test-only additions).

Evidence: sep-2322-client-request-state 5 passed 0 failed locally; full conformance suite 440 passed 0 failed; new e2e tests/e2e/mcp-mrtr.test.ts pinned red before the fix and green after (independently reproduced by the reviewer); baseline entries removed with the fix. Follow-ups: H5 mixed-round headless gap; fx.sh/docs MCP page needs one line (headless elicitation answers cancel); mcp-stdio updated assertions to be confirmed by CI.
