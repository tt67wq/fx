import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  readdirSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayHeldDecision,
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
  type FakeGatewayResponse,
} from "./tmux-helpers";

// Full-chain codemode admission coverage.
//
// The same shell command reaches admission once directly from the model and
// once through tools.call inside a codemode script. The review payloads must
// differ only in the review origin and the target call id, and the script
// must see the same allow/deny dispositions and execution result the direct
// call reports.

const TIMEOUT = 30_000;
// Wall clock for the budget-expiry case only (T-17 / ISSUE-17 failure 3,
// R3 decision: keep the 30s/45s windows, raise the harness wall).
// Timing invariants, fixed on purpose — do not "tighten the flake":
// - runFx resolves on the child's "close" event (eval-helpers.ts:514-545,
//   stdio all pipe), so it waits for pipe EOF, not for fx to exit.
// - Ordering: product budget 30s < assertion window 45s < nested sleep 60s
//   (commanded length; the budget ends it at 30s) <= harness wall 60s. The
//   wall is headroom over the budget kill plus fx's cleanup and the 45s
//   window, so fx is killed by the budget, never by this test.
// - bun:test case-level timeout (90s, second arg below) must stay above the
//   wall, or the case dies before fx finishes its budget cleanup.
const BUDGET_TEST_TIMEOUT = 60_000;
const COMMAND_APPROVAL_PROMPT = "Would you like to run the following command?";
const USER_PROMPT = "Run the prepared parity probe and report the result.";
const CALL_ID_PLACEHOLDER = "@CALL_ID@";
const ORIGIN_PLACEHOLDER = "@ORIGIN@";

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
};

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
let activeSession: TmuxSession | null = null;

afterEach(async () => {
  if (activeSession) {
    await activeSession.kill();
    activeSession = null;
  }
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function createIsolatedRoot(
  extraExperimental: Record<string, boolean> = {},
  permission: Record<string, unknown> = {},
): IsolatedRoot {
  const root = realpathSync(
    mkdtempSync(join(tmpdir(), "fx-codemode-admission-e2e-")),
  );
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      sandbox: "none",
      permission_mode: "auto",
      permission,
      experimental: { codemode: true, ...extraExperimental },
    }) + "\n",
  );
  roots.push(root);
  return { root, home, workspace: realpathSync(workspace) };
}

function gatewayEnv(
  root: IsolatedRoot,
  gateway: ReturnType<typeof startFakeGateway>,
  permissionMode: "auto" | "ask" = "auto",
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-codemode-admission-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_PERMISSION_MODE: permissionMode,
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

function startGateway(
  responses: FakeGatewayResponse[],
  classifierResponses: FakeGatewayResponse[] = [],
) {
  const gateway = startFakeGateway(responses, {
    classifierResponses,
  });
  gateways.push(gateway);
  return gateway;
}

function installScript(workspace: string, name: string, body: string): string {
  const path = join(workspace, name);
  writeFileSync(path, "#!/bin/sh\n" + body);
  chmodSync(path, 0o755);
  return path;
}

function toolResultText(
  body: string,
  toolCallId: string,
  // "error-text" is how a failed tool result reaches the model; a script
  // that never catches its own error lands there (ISSUE-24/25 probes).
  outputType: "text" | "execution-denied" | "error-text" = "text",
): string {
  const request = JSON.parse(body) as {
    prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
  };
  const result = (request.prompt ?? [])
    .flatMap((message) => message.content ?? [])
    .find((part) => part.type === "tool-result" && part.toolCallId === toolCallId);
  expect(result).toBeDefined();
  const output = result!.output as Record<string, unknown>;
  expect(output.type).toBe(outputType);
  const content = outputType === "execution-denied" ? output.reason : output.value;
  expect(typeof content).toBe("string");
  return content as string;
}

// A codemode result that made nested calls now carries the nested call
// summary at the head of its output (ISSUE-11). Tests that parse the
// script's own JSON envelope strip that summary block first: everything
// after the blank line that follows the summary record lines.
function stripNestedCallSummary(text: string): string {
  const title = "Nested tool calls (not undone):";
  if (!text.startsWith(title)) return text;
  const separator = text.indexOf("\n\n", title.length);
  return separator === -1 ? "" : text.slice(separator + 2);
}

function normalizeReviewBody(body: string, callId: string): string {
  return body
    .split(callId)
    .join(CALL_ID_PLACEHOLDER)
    .replace(
      /review_origin: (root|codemode|subagent)/g,
      `review_origin: ${ORIGIN_PLACEHOLDER}`,
    );
}

function firstDifference(direct: string, codemode: string): string {
  const shared = Math.min(direct.length, codemode.length);
  for (let index = 0; index < shared; index += 1) {
    if (direct[index] === codemode[index]) continue;
    return [
      `first difference at byte ${index}`,
      `direct:   ${JSON.stringify(direct.slice(Math.max(0, index - 48), index + 80))}`,
      `codemode: ${JSON.stringify(codemode.slice(Math.max(0, index - 48), index + 80))}`,
    ].join("\n");
  }
  if (direct.length !== codemode.length) {
    return `length differs: direct=${direct.length} codemode=${codemode.length}`;
  }
  return "no difference";
}

function countOccurrences(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

test("REPRO async main completion drains the returned promise", async () => {
  const root = createIsolatedRoot();
  const script =
    'async function main() {\n' +
    '  const ls = await tools.call("run_command", { command: "echo hello-repro" });\n' +
    '  return ls;\n' +
    '}\n' +
    'main();';
  const gateway = startGateway([
    fakeGatewayToolCall("repro-1", "codemode", { script }),
    fakeGatewayFinalText("REPRO_FINAL"),
  ]);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--no-save", "run the repro"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    const body = toolResultText(gateway.requests[1]!.body, "repro-1");
    expect(body).toContain("hello-repro");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, 90000);

test("nested run_command is killed when the codemode script budget expires", async () => {
  const root = createIsolatedRoot();
  // One nested command sleeps far past the 30s script budget. The ambient
  // timeout must kill it at the budget instead of waiting for sleep itself.
  const script = 'await tools.call("run_command", { command: "sleep 60" });\n' +
    'text("slept");';
  const gateway = startGateway([
    fakeGatewayToolCall("budget-1", "codemode", { script }),
    fakeGatewayFinalText("BUDGET_FINAL"),
  ]);
  const startedAt = Date.now();
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--no-save", "run the budget test"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: BUDGET_TEST_TIMEOUT },
    );
    const elapsedS = (Date.now() - startedAt) / 1000;
    expect(result.timedOut).toBe(false);
    // Budget expiry is not a process failure: fx kills the script at the
    // budget, hands the model a Timeout error tool result, and exits 0
    // (same contract as the failed-script case below). A non-zero/null
    // code here only ever came from the old 30s harness wall SIGKILLing
    // fx mid-cleanup, which the raised wall and the timedOut guard above
    // now rule out.
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    expect(elapsedS).toBeGreaterThan(20);
    expect(elapsedS).toBeLessThan(45);
    // The failure detail is not echoed by --quiet --json; the model
    // receives it as the follow-up request's tool result.
    expect(gateway.requests.length).toBe(2);
    const request = JSON.parse(gateway.requests[1]!.body) as {
      prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
    };
    const toolResult = (request.prompt ?? [])
      .flatMap((message) => message.content ?? [])
      .find((part) => part.type === "tool-result" && part.toolCallId === "budget-1");
    expect(toolResult).toBeDefined();
    const output = toolResult!.output as { type: string; value: string };
    expect(output.type).toBe("error-text");
    // ISSUE-23a: the headline names the elapsed wall, the effective budget
    // and its source, and the @options fix, verbatim.
    expect(output.value).toContain("Timeout after ");
    expect(output.value).toContain("(budget 30000ms, from default)");
    expect(output.value).toContain(
      'raise it with // @options: {"timeout_ms": N} on the first script line, max 120000;',
    );
    expect(output.value).toContain(
      "for a wait or a long command, end the script and poll in a later call",
    );
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, 90000); // > BUDGET_TEST_TIMEOUT (R3: keep the wall under the case timeout)

test("a script timeout with a raised @options budget names the source", async () => {
  const root = createIsolatedRoot();
  // The script declares its own 5s budget with @options; the headline must
  // report that budget and its source instead of the profile default.
  const script = '// @options: {"timeout_ms": 5000}\n' +
  'await tools.call("run_command", { command: "sleep 60" });\n' +
  'text("slept");';
  const gateway = startGateway([
    fakeGatewayToolCall("budget-options-1", "codemode", { script }),
    fakeGatewayFinalText("BUDGET_OPTIONS_FINAL"),
  ]);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--no-save", "run the options budget test"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.timedOut).toBe(false);
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    expect(gateway.requests.length).toBe(2);
    const request = JSON.parse(gateway.requests[1]!.body) as {
      prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
    };
    const toolResult = (request.prompt ?? [])
      .flatMap((message) => message.content ?? [])
      .find((part) => part.type === "tool-result" && part.toolCallId === "budget-options-1");
    expect(toolResult).toBeDefined();
    const output = toolResult!.output as { type: string; value: string };
    expect(output.type).toBe("error-text");
    expect(output.value).toContain("Timeout after ");
    expect(output.value).toContain("(budget 5000ms, from @options)");
    expect(output.value).toContain("for a wait or a long command, end the script and poll in a later call");
    // The killed sleep is the last returned nested call: its snapshot rides
    // in the excerpt slot under the headline (coverage matrix row 3, empty
    // delta because sleep produces no output).
    expect(output.value).toContain("Last nested output before failure (run_command, failure,");
    expect(output.value).toContain('"error":"TimeoutExpired"');
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, 60000);

// ISSUE-28: a nested run_command with an explicit timeout_ms must still die
// at min(requested, remaining script budget). The script declares a 2000ms
// budget and nests sleep 8 with timeout_ms 60000: the command must be killed
// near the script deadline (~2s), not run its full requested 8s.
test("a nested command with a large requested timeout dies at the remaining script budget", async () => {
  const root = createIsolatedRoot();
  const script = '// @options: {"timeout_ms": 2000}\n' +
    'await tools.call("run_command", { command: "sleep 8", timeout_ms: 60000 });\n' +
    'text("slept");';
  const gateway = startGateway([
    fakeGatewayToolCall("nested-min-1", "codemode", { script }),
    fakeGatewayFinalText("NESTED_MIN_FINAL"),
  ]);
  const startedAt = Date.now();
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--no-save", "run the nested budget test"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    const elapsedS = (Date.now() - startedAt) / 1000;
    expect(result.timedOut).toBe(false);
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    // min(requested, remaining): the 60000ms request cannot outlive the
    // 2000ms script budget. The old whole-budget/requested-wins behavior
    // ran the full sleep (~8s) and fails this window.
    expect(elapsedS).toBeGreaterThan(1);
    expect(elapsedS).toBeLessThan(6);
    expect(gateway.requests.length).toBe(2);
    const body = toolResultText(gateway.requests[1]!.body, "nested-min-1", "error-text");
    expect(body).toContain("Timeout after ");
    expect(body).toContain("(budget 2000ms, from @options)");
    // Coverage matrix row 3: the killed nested command's TimeoutExpired
    // snapshot still rides in the excerpt slot.
    expect(body).toContain('"error":"TimeoutExpired"');
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, 30000);

// ISSUE-28 min's other branch: when the requested timeout is below the
// remaining script budget, the request wins. Default 30s budget, nested
// sleep 8 requesting 1500ms: the command dies near 1.5s and the script
// still completes normally.
test("a nested command requesting less than the remaining budget keeps its requested timeout", async () => {
  const root = createIsolatedRoot();
  const script = 'await tools.call("run_command", { command: "sleep 8", timeout_ms: 1500 });\n' +
    'text("done-after-kill");';
  const gateway = startGateway([
    fakeGatewayToolCall("nested-req-1", "codemode", { script }),
    fakeGatewayFinalText("NESTED_REQ_FINAL"),
  ]);
  const startedAt = Date.now();
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--no-save", "run the requested timeout test"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    const elapsedS = (Date.now() - startedAt) / 1000;
    expect(result.timedOut).toBe(false);
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    // requested 1500ms < remaining ~30000ms: the kill happens near 1.5s,
    // not at the script budget and not after the full 8s sleep.
    expect(elapsedS).toBeGreaterThan(1);
    expect(elapsedS).toBeLessThan(6);
    expect(gateway.requests.length).toBe(2);
    const body = toolResultText(gateway.requests[1]!.body, "nested-req-1");
    expect(body).toContain("done-after-kill");
    expect(body).toContain("- run_command: failure (");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, 30000);

// ISSUE-23b: the excerpt slot carries the last returned nested call's
// model-visible output in the timeout failure body. The completed call is
// the LAST nested call here: a trailing nested sleep would overwrite the
// slot with its own snapshot per the last-returned rule, so the script
// burns its remaining budget in a JS loop instead of nesting another call.
test("timeout failure body carries the completed nested command's output with head and tail sentinels", async () => {
  const root = createIsolatedRoot();
  // A 1333-byte nested command output: head sentinel, filler, tail
  // sentinel, so the slot excerpt is over 1KiB and truncates.
  writeFileSync(join(root.workspace, "big.txt"), "HEAD-SENT-23b" + "F".repeat(1300) + "TAIL-SENT-23b");
  const script = 'await tools.call("run_command", { command: "cat big.txt" });\n' +
    'const t0 = Date.now(); while (Date.now() - t0 < 45000) {}\n' +
    'text("never");';
  const gateway = startGateway([
    fakeGatewayToolCall("excerpt-1", "codemode", { script }),
    fakeGatewayFinalText("EXCERPT_FINAL"),
  ]);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--no-save", "run the excerpt test"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: BUDGET_TEST_TIMEOUT },
    );
    expect(result.timedOut).toBe(false);
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    expect(gateway.requests.length).toBe(2);
    const body = toolResultText(gateway.requests[1]!.body, "excerpt-1", "error-text");
    // The excerpt section rides under the headline, naming the recorded call.
    expect(body).toContain("Last nested output before failure (run_command, ok, ");
    // The slot excerpt is verbatim and over 1KiB, so head and tail are
    // both kept around the shared omission marker.
    expect(body).toContain("HEAD-SENT-23b");
    expect(body).toContain("TAIL-SENT-23b");
    expect(body).toContain(" bytes omitted]...");
    // The nested call summary still lists the completed exit.
    expect(body).toContain("- run_command: ok (");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, 90000);

// A single long command that keeps producing output is killed at the
// budget: the shell snapshot's output_delta rides into the excerpt slot,
// and the tail sentinel must survive because the snapshot envelope's head
// (state/session_id/handle) eats the head budget while the real progress
// sits at the tail (review C2).
test("budget-killed long command leaves its shell snapshot tail in the failure body", async () => {
  const root = createIsolatedRoot();
  const script = 'await tools.call("run_command", { command: "sh -c \'while true; do for i in $(seq 1 100000); do echo TAILPROBE-$i; done; done\'" });\n' +
    'text("never");';
  const gateway = startGateway([
    fakeGatewayToolCall("killed-1", "codemode", { script }),
    fakeGatewayFinalText("KILLED_FINAL"),
  ]);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--no-save", "run the killed command test"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: BUDGET_TEST_TIMEOUT },
    );
    expect(result.timedOut).toBe(false);
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    expect(gateway.requests.length).toBe(2);
    const body = toolResultText(gateway.requests[1]!.body, "killed-1", "error-text");
    // T-27-fix: the budget-boundary command has one deterministic outcome.
    // Its timeout (the script's remaining budget) lands at or before the
    // yield, so the foreground waits for the timeout kill instead of
    // racing a running snapshot: the excerpt is the failure-timeout one.
    expect(body).toContain("Last nested output before failure (run_command, failure,");
    // The snapshot was over 1KiB, so it is head-tail truncated and the
    // tail keeps the command's last progress lines (review C2: the tail,
    // not the head, proves where the command got to).
    expect(body).toContain(" bytes omitted]...");
    const excerpt = body.split("Last nested output before failure (run_command, failure,")[1]!
      .split("Partial output before failure")[0]!;
    expect(excerpt).toContain('"state":"stopped"');
    expect(excerpt).toContain('"error":"TimeoutExpired"');
    // The excerpt tail ends with the JSON envelope close, but the last
    // progress line must survive the head-tail split inside it.
    expect(excerpt).toMatch(/TAILPROBE-\d+\\nTAILPROBE-\d+"}\s*$/);
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, 90000);

test("a failed script keeps partial output and nested call summary", async () => {
  const root = createIsolatedRoot();
  writeFileSync(join(root.workspace, "notes.txt"), "alpha notes");
  const script = `const notes = await tools.call("read_file", { path: "notes.txt" });
text("reached the read step");
console.log("side effect logged");
throw new Error("boom");`;
  const gateway = startGateway([
    fakeGatewayToolCall("fail-1", "codemode", { script }),
    fakeGatewayFinalText("FAIL_FINAL"),
  ]);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--no-save", "run the failure test"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    // A script error is not a process failure: the model receives the
    // failure body as an error-text tool result and answers normally.
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    const request = JSON.parse(gateway.requests[1]!.body) as {
      prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
    };
    const toolResult = (request.prompt ?? [])
      .flatMap((message) => message.content ?? [])
      .find((part) => part.type === "tool-result" && part.toolCallId === "fail-1");
    expect(toolResult).toBeDefined();
    const output = toolResult!.output as { type: string; value: string };
    expect(output.type).toBe("error-text");
    expect(output.value).toContain("boom");
    expect(output.value).toContain("reached the read step");
    expect(output.value).toContain("side effect logged");
    expect(output.value).toContain("read_file: ok");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
});

// Plan v2 group 10: a successful script that makes nested calls reports
// them at the head of the model-visible result (plan v2 section 3). With
// --no-save there is no session result store, so the 20KiB text is cut to
// the 64KiB model head cap rather than externalized; the summary sits at
// the head either way and stays visible. The true externalization path is
// pinned by the codemode_tool layer test (plan v2 group 9). The second
// read misses on purpose and returns a failure status without throwing,
// so the summary must record .failure for it (review F2).
test("a successful script reports the nested call summary at the head", async () => {
  const root = createIsolatedRoot();
  writeFileSync(join(root.workspace, "notes.txt"), "alpha notes");
  const script = `const notes = await tools.call("read_file", { path: "notes.txt" });
await tools.call("read_file", { path: "missing.txt" });
text("padding " + "x".repeat(20000));
`;
  const gateway = startGateway([
    fakeGatewayToolCall("success-1", "codemode", { script }),
    fakeGatewayFinalText("SUCCESS_FINAL"),
  ]);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--no-save", "run the success test"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    const request = JSON.parse(gateway.requests[1]!.body) as {
      prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
    };
    const toolResult = (request.prompt ?? [])
      .flatMap((message) => message.content ?? [])
      .find((part) => part.type === "tool-result" && part.toolCallId === "success-1");
    expect(toolResult).toBeDefined();
    const output = toolResult!.output as { type: string; value: string };
    expect(output.type).toBe("text");
    // The head summary survives the 64KiB model head cap.
    expect(output.value).toContain("Nested tool calls (not undone):");
    expect(output.value).toContain("- read_file: ok (");
    expect(output.value).toContain("ms)");
    // A returned failure records as failure, not ok (review F2).
    expect(output.value).toContain("- read_file: failure (");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
});

describe("codemode nested admission parity", () => {
  test(
    "one command produces one review payload and one result on both paths",
    async () => {
      const root = createIsolatedRoot();
      const marker = join(root.workspace, "parity-marker.txt");
      installScript(
        root.workspace,
        "parity-probe.sh",
        "printf 'PARITY_SCRIPT_OUTPUT\\n'\n" +
          "printf 'parity-marker\\n' > parity-marker.txt\n",
      );
      const directGateway = startGateway([
        fakeGatewayToolCall("parity-direct-call", "shell", {
          action: "run",
          command: "./parity-probe.sh",
        }),
        fakeGatewayFinalText("DIRECT_DONE"),
      ]);
      const codemodeGateway = startGateway([
        fakeGatewayToolCall("parity-bridge-call", "codemode", {
          script:
            'var result = tools.call("run_command", JSON.stringify({ command: "./parity-probe.sh" }));\n' +
            "text(result);",
        }),
        fakeGatewayFinalText("CODEMODE_DONE"),
      ]);

      rmSync(marker, { force: true });
      const direct = await runFx(
        ["ask", "--quiet", "--json", "--no-save", USER_PROMPT],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, directGateway),
          timeoutMs: TIMEOUT,
        },
      );
      expect(direct.code, `stdout: ${direct.stdout}\nstderr: ${direct.stderr}`).toBe(0);
      expect(direct.stderr).not.toContain("panic");
      expect(direct.stderr).not.toContain("error:");
      expect(directGateway.classifierRequests).toHaveLength(1);
      expect(directGateway.requestCount()).toBe(2);
      expect(existsSync(marker)).toBe(true);
      const directMarker = readFileSync(marker, "utf8");

      rmSync(marker, { force: true });
      const codemode = await runFx(
        ["ask", "--quiet", "--json", "--no-save", USER_PROMPT],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, codemodeGateway),
          timeoutMs: TIMEOUT,
        },
      );
      expect(codemode.code, `stdout: ${codemode.stdout}\nstderr: ${codemode.stderr}`).toBe(0);
      expect(codemode.stderr).not.toContain("panic");
      expect(codemode.stderr).not.toContain("error:");
      expect(codemodeGateway.classifierRequests).toHaveLength(1);
      expect(codemodeGateway.requestCount()).toBe(2);
      expect(existsSync(marker)).toBe(true);
      expect(readFileSync(marker, "utf8")).toBe(directMarker);

      const directBody = directGateway.classifierRequests[0]!.body;
      const codemodeBody = codemodeGateway.classifierRequests[0]!.body;
      expect(directBody).toContain("review_origin: root");
      expect(codemodeBody).toContain("review_origin: codemode");
      expect(directBody).toContain("command: ./parity-probe.sh");
      expect(codemodeBody).toContain("command: ./parity-probe.sh");
      const normalizedDirect = normalizeReviewBody(directBody, "parity-direct-call");
      const normalizedCodemode = normalizeReviewBody(codemodeBody, "codemode-nested-1");
      expect(
        normalizedCodemode,
        firstDifference(normalizedDirect, normalizedCodemode),
      ).toBe(normalizedDirect);

      const directEnvelope = JSON.parse(
        toolResultText(directGateway.requests[1]!.body, "parity-direct-call"),
      ) as { exit_code?: number; output_delta?: string };
      const codemodeOuter = JSON.parse(
        stripNestedCallSummary(
          toolResultText(codemodeGateway.requests[1]!.body, "parity-bridge-call"),
        ).trim(),
      ) as { exit_code?: number; output?: string; truncated?: boolean };
      const codemodeEnvelope = JSON.parse(String(codemodeOuter.output)) as {
        exit_code?: number;
        output_delta?: string;
      };
      expect(codemodeOuter.exit_code).toBe(directEnvelope.exit_code);
      expect(codemodeOuter.truncated).toBe(false);
      expect(codemodeEnvelope.exit_code).toBe(directEnvelope.exit_code);
      expect(codemodeEnvelope.output_delta).toBe(directEnvelope.output_delta);
      expect(directEnvelope.output_delta).toContain("PARITY_SCRIPT_OUTPUT");
    },
    TIMEOUT,
  );

  test(
    "65 nested run_command calls do not exhaust the execution capacity",
    async () => {
      const root = createIsolatedRoot();
      const script = [
        "var last = null;",
        "for (var i = 0; i < 65; i += 1) {",
        '  last = tools.call("run_command", JSON.stringify({ command: "echo CAPACITY_PROBE_" + i }));',
        "}",
        "text(last);",
      ].join("\n");
      const gateway = startGateway([
        fakeGatewayToolCall("capacity-probe-call", "codemode", { script }),
        fakeGatewayFinalText("CAPACITY_DONE"),
      ]);

      const run = await runFx(
        ["ask", "--quiet", "--json", "--no-save", USER_PROMPT],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );
      expect(run.code, `stdout: ${run.stdout}\nstderr: ${run.stderr}`).toBe(0);
      expect(run.stderr).not.toContain("panic");
      expect(run.stderr).not.toContain("error:");
      // The 65th nested call must succeed: before the delivery-token commit
      // fix every nested run_command leaked one execution slot and the
      // capacity admission rejected later calls with ExecutionCapacityExceeded.
      expect(toolResultText(gateway.requests[1]!.body, "capacity-probe-call")).toContain(
        "CAPACITY_PROBE_64",
      );
      expect(run.stdout).not.toContain("ExecutionCapacityExceeded");
    },
    TIMEOUT,
  );
  test(
    "a review caution denies both paths with the same script-visible reason",
    async () => {
      const root = createIsolatedRoot();
      const marker = join(root.workspace, "parity-deny-marker.txt");
      installScript(
        root.workspace,
        "parity-deny-probe.sh",
        "printf 'PARITY_DENY_OUTPUT\\n'\n" +
          "printf 'ran\\n' > parity-deny-marker.txt\n",
      );
      const directGateway = startGateway(
        [
          fakeGatewayToolCall("parity-direct-call", "shell", {
            action: "run",
            command: "./parity-deny-probe.sh",
          }),
          fakeGatewayFinalText("DIRECT_DENIED"),
        ],
        [fakeGatewayHeldDecision()],
      );
      const codemodeGateway = startGateway(
        [
          fakeGatewayToolCall("parity-bridge-call", "codemode", {
            script:
              'text(tools.call("run_command", JSON.stringify({ command: "./parity-deny-probe.sh" })));',
          }),
          fakeGatewayFinalText("CODEMODE_DENIED"),
        ],
        [fakeGatewayHeldDecision()],
      );

      rmSync(marker, { force: true });
      const direct = await runFx(
        ["ask", "--quiet", "--json", "--no-save", USER_PROMPT],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, directGateway),
          timeoutMs: TIMEOUT,
        },
      );
      expect(direct.code, `stdout: ${direct.stdout}\nstderr: ${direct.stderr}`).toBe(0);
      expect(direct.stderr).not.toContain("panic");
      expect(directGateway.classifierRequests).toHaveLength(1);
      expect(directGateway.confirmationRequests).toHaveLength(1);
      expect(directGateway.requestCount()).toBe(2);
      expect(existsSync(marker)).toBe(false);

      rmSync(marker, { force: true });
      const codemode = await runFx(
        ["ask", "--quiet", "--json", "--no-save", USER_PROMPT],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, codemodeGateway),
          timeoutMs: TIMEOUT,
        },
      );
      expect(codemode.code, `stdout: ${codemode.stdout}\nstderr: ${codemode.stderr}`).toBe(0);
      expect(codemode.stderr).not.toContain("panic");
      expect(codemodeGateway.classifierRequests).toHaveLength(1);
      expect(codemodeGateway.confirmationRequests).toHaveLength(1);
      expect(codemodeGateway.requestCount()).toBe(2);
      expect(existsSync(marker)).toBe(false);

      const directBody = directGateway.classifierRequests[0]!.body;
      const codemodeBody = codemodeGateway.classifierRequests[0]!.body;
      expect(directBody).toContain("review_origin: root");
      expect(codemodeBody).toContain("review_origin: codemode");
      const normalizedDirect = normalizeReviewBody(directBody, "parity-direct-call");
      const normalizedCodemode = normalizeReviewBody(codemodeBody, "codemode-nested-1");
      expect(
        normalizedCodemode,
        firstDifference(normalizedDirect, normalizedCodemode),
      ).toBe(normalizedDirect);

      const directDenial = JSON.parse(
        toolResultText(directGateway.requests[1]!.body, "parity-direct-call", "execution-denied"),
      ) as { error?: { reason?: string } };
      expect(directDenial.error?.reason).toBe("review_caution");
      const codemodeDenial = JSON.parse(
        stripNestedCallSummary(
          toolResultText(codemodeGateway.requests[1]!.body, "parity-bridge-call"),
        ).trim(),
      ) as { denied?: boolean; reason?: string };
      expect(codemodeDenial.denied).toBe(true);
      expect(codemodeDenial.reason).toContain(String(directDenial.error?.reason));
    },
    TIMEOUT,
  );
});

  // --- run_script tests (T-20): multi-language execute primitive ---

test("run_script python captures stdout and reports non-zero exit", async () => {
  const root = createIsolatedRoot({ codemode_derived_surface: true });
  const script =
    `const ok = await tools.call("run_script", JSON.stringify({` +
    `language: 'python', code: "print('py-ok-1137')" }));` +
    `const bad = await tools.call("run_script", JSON.stringify({` +
    `language: 'python', code: "import sys; print('py-err-line'); sys.exit(3)" }));` +
    `text(JSON.stringify({ ok: JSON.parse(ok), bad: JSON.parse(bad) }));`;
  const gateway = startGateway([
    fakeGatewayToolCall("run-script-1", "codemode", { script }),
    fakeGatewayFinalText("RUN_SCRIPT_DONE"),
  ]);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--yolo", "--no-save", "Probe run_script."],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    const body = stripNestedCallSummary(
      toolResultText(gateway.requests[1]!.body, "run-script-1"),
    );
    const report = JSON.parse(body) as {
      ok: { exit_code: number; output: string; truncated: boolean };
      bad: { exit_code: number; output: string };
    };
    expect(report.ok.exit_code).toBe(0);
    expect(report.ok.output).toContain("py-ok-1137");
    expect(report.ok.truncated).toBe(false);
    expect(report.bad.exit_code).toBe(3);
    expect(report.bad.output).toContain("py-err-line");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, TIMEOUT);

test("run_script forwards a workspace file through CTX_FILE", async () => {
  const root = createIsolatedRoot({ codemode_derived_surface: true });
  writeFileSync(join(root.workspace, "big-data.txt"), "ctx-file-payload-914");
  const script =
    `const r = await tools.call("run_script", JSON.stringify({` +
    `language: 'python',` +
    `code: "import os,sys; sys.stdout.write(open(os.environ['CTX_FILE']).read())",` +
    `file: 'big-data.txt' }));` +
    `text(String(JSON.parse(r).output));`;
  const gateway = startGateway([
    fakeGatewayToolCall("ctx-file-1", "codemode", { script }),
    fakeGatewayFinalText("CTX_FILE_DONE"),
  ]);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--yolo", "--no-save", "Probe CTX_FILE."],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    const body = stripNestedCallSummary(
      toolResultText(gateway.requests[1]!.body, "ctx-file-1"),
    );
    expect(body).toContain("ctx-file-payload-914");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, TIMEOUT);

test("run_script leaves no fx-run-script temp dirs after the call ends", async () => {
  const root = createIsolatedRoot({ codemode_derived_surface: true });
  writeFileSync(join(root.workspace, "data.txt"), "cleanup-pin-3107");
  const script =
    `const r = await tools.call("run_script", JSON.stringify({` +
    `language: 'python',` +
    `code: "import os,sys; sys.stdout.write(open(os.environ['CTX_FILE']).read())",` +
    `file: 'data.txt' }));` +
    `text(String(JSON.parse(r).output));`;
  const gateway = startGateway([
    fakeGatewayToolCall("cleanup-pin-1", "codemode", { script }),
    fakeGatewayFinalText("CLEANUP_PIN_DONE"),
  ]);
  const before = new Set(
    readdirSync(tmpdir()).filter((name) => name.startsWith("fx-run-script-")),
  );
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--yolo", "--no-save", "Probe cleanup."],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    // The fx process has exited, so the per-call temp dir must be gone:
    // cleanup runs on every return path and nothing survives the call.
    const after = readdirSync(tmpdir()).filter((name) =>
      name.startsWith("fx-run-script-"),
    );
    for (const name of after) {
      expect(before.has(name), "orphan temp dir: " + name).toBe(true);
    }
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, TIMEOUT);

test("run_script rejects interpreter option fields at normalization", async () => {
  const root = createIsolatedRoot({ codemode_derived_surface: true });
  const script =
    `var caught = "";` +
    `try { await tools.call("run_script", JSON.stringify({` +
    `language: 'python', code: '1', args: ['-c', 'print(1337)'] }));` +
    `} catch (e) { caught = String(e.message || e); }` +
    `text(caught);`;
  const gateway = startGateway([
    fakeGatewayToolCall("dash-reject-1", "codemode", { script }),
    fakeGatewayFinalText("DASH_REJECT_DONE"),
  ]);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--yolo", "--no-save", "Probe rejection."],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    const body = toolResultText(gateway.requests[1]!.body, "dash-reject-1");
    expect(body).toContain("InvalidToolArguments");
    expect(body).not.toContain("1337");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, TIMEOUT);

test("run_script is hidden while the derived gate is closed", async () => {
  const root = createIsolatedRoot();
  const script =
    `var list = tools.list();` +
    `var names = list.map(t => t.name);` +
    `var callErr = "";` +
    `try { await tools.call("run_script", JSON.stringify({` +
    `language: 'python', code: '1' }));` +
    `} catch (e) { callErr = String(e.message || e); }` +
    `text(JSON.stringify({ names: names.join(","), callErr: callErr }));`;
  const gateway = startGateway([
    fakeGatewayToolCall("gate-closed-1", "codemode", { script }),
    fakeGatewayFinalText("GATE_CLOSED_DONE"),
  ]);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--yolo", "--no-save", "Probe the closed gate."],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    const body = stripNestedCallSummary(
      toolResultText(gateway.requests[1]!.body, "gate-closed-1"),
    );
    const report = JSON.parse(body) as { names: string; callErr: string };
    expect(report.names).toBe("glob_files,grep_files,read_file,run_command");
    expect(report.callErr).toContain("unknown codemode tool: run_script");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, TIMEOUT);

test("run_script is listed with its schema on the derived surface", async () => {
  const root = createIsolatedRoot({ codemode_derived_surface: true });
  const script =
    `var list = tools.list();` +
    `var rs = list.find(t => t.name === "run_script");` +
    `text(JSON.stringify({` +
    `names: list.map(t => t.name).join(','),` +
    `languageEnum: rs ? rs.parameters.properties.language.enum : null,` +
    `required: rs ? rs.parameters.required.join(',') : null }));`;
  const gateway = startGateway([
    fakeGatewayToolCall("derived-list-1", "codemode", { script }),
    fakeGatewayFinalText("DERIVED_LIST_DONE"),
  ]);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "--yolo", "--no-save", "Probe the derived list."],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    const body = stripNestedCallSummary(
      toolResultText(gateway.requests[1]!.body, "derived-list-1"),
    );
    const report = JSON.parse(body) as {
      names: string;
      languageEnum: string[];
      required: string;
    };
    expect(report.names).toContain("run_script");
    expect(report.languageEnum).toEqual(["shell", "python"]);
    expect(report.required).toBe("language,code");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, TIMEOUT);


test("tools.list exposes parsed schema objects inside scripts", async () => {
    const root = createIsolatedRoot();
    const gateway = startGateway([
      fakeGatewayToolCall("schema-probe", "codemode", {
        script:
          "var list = tools.list();" +
          "\nvar glob = list.find(t => t.name === 'glob_files');" +
          "\ntext(JSON.stringify({names: list.map(t => t.name).join(',')," +
          " kind: typeof glob.parameters," +
          " pattern: glob.parameters.properties.pattern.type," +
          " required: glob.parameters.required[0]}));",
      }),
      fakeGatewayFinalText("SCHEMA_PROBE_DONE"),
    ]);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", "Introspect the tools."],
      {
        cwd: root.workspace,
        env: gatewayEnv(root, gateway),
        timeoutMs: TIMEOUT,
      },
    );
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toBe("SCHEMA_PROBE_DONE");

    // The script saw one schema object per whitelisted tool, with the
    // inputSchema already parsed: no JSON.parse layer in the script.
    const report = JSON.parse(
      toolResultText(gateway.requests[1]!.body, "schema-probe"),
    );
    expect(report.names).toBe("glob_files,grep_files,read_file,run_command");
    expect(report.kind).toBe("object");
    expect(report.pattern).toBe("string");
    expect(report.required).toBe("pattern");
  }, TIMEOUT);

test(
  "a nested write then read back returns the written content",
  async () => {
    // G1: the nested result owner is a distinct arena from the call owner, so
    // a prepared file mutation and the result that follows it cannot share
    // one arena's lifetime. A single arena makes the write fail silently.
    const root = createIsolatedRoot({ codemode_derived_surface: true }, { edit: "allow" });
    const target = join(root.workspace, "result-arena-probe.txt");
    const script =
      'const w = await tools.call("write_file", JSON.stringify({ path: ' +
      JSON.stringify(target) +
      ', content: "result-arena-probe" }));' +
      'const r = await tools.call("read_file", JSON.stringify({ path: ' +
      JSON.stringify(target) +
      " }));" +
      "text(String(r));";
    const gateway = startGateway([
      fakeGatewayToolCall("arena-write-1", "codemode", { script }),
      fakeGatewayFinalText("ARENA_FINAL"),
    ]);
    rmSync(target, { force: true });
    try {
      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", USER_PROMPT],
        { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, result.stderr.slice(0, 400)).toBe(0);
      expect(existsSync(target)).toBe(true);
      expect(readFileSync(target, "utf8")).toBe("result-arena-probe");
      // The read-back crosses the same bridge, so the script sees the content
      // written by the previous nested call.
      const body = toolResultText(gateway.requests[1]!.body, "arena-write-1");
      expect(body).toContain("result-arena-probe");
    } finally {
      rmSync(target, { force: true });
    }
  },
  TIMEOUT,
);

test(
  "a nested edit_file on the derived face is still denied by admission",
  async () => {
    // G2: the deny coverage for the derived face includes edit_file, not only
    // write_file.
    const root = createIsolatedRoot({ codemode_derived_surface: true }, { edit: "deny" });
    const target = join(root.workspace, "script-edit.txt");
    writeFileSync(target, "alpha\n");
    const script =
      'text(tools.call("edit_file", JSON.stringify({ path: ' +
      JSON.stringify(target) +
      ', old_string: "alpha", new_string: "beta" })));';
    const gateway = startGateway([
      fakeGatewayToolCall("surface-edit-1", "codemode", { script }),
      fakeGatewayFinalText("SURFACE_EDIT_FINAL"),
    ]);
    try {
      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", USER_PROMPT],
        { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, result.stderr.slice(0, 400)).toBe(0);
      expect(readFileSync(target, "utf8")).toBe("alpha\n");
      const denial = JSON.parse(
        stripNestedCallSummary(
          toolResultText(gateway.requests[1]!.body, "surface-edit-1"),
        ).trim(),
      ) as { denied?: boolean; reason?: string };
      expect(denial.denied).toBe(true);
      expect(denial.reason).toBeTruthy();
    } finally {
      rmSync(target, { force: true });
    }
  },
  TIMEOUT,
);

test(
  "a nested write_file on the derived face is still denied by admission",
  async () => {
    // A configured deny is the authority the derived face must not bypass.
    const root = createIsolatedRoot({ codemode_derived_surface: true }, { edit: "deny" });
    const target = join(root.workspace, "script-write.txt");
    const script =
      'text(tools.call("write_file", JSON.stringify({ path: ' +
      JSON.stringify(target) +
      ', content: "scripted" })));';
    const gateway = startGateway([
      fakeGatewayToolCall("surface-write-1", "codemode", { script }),
      fakeGatewayFinalText("SURFACE_WRITE_FINAL"),
    ]);
    rmSync(target, { force: true });
    try {
      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", USER_PROMPT],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );
      expect(
        result.code,
        `stdout: \${result.stdout}
stderr: \${result.stderr}`,
      ).toBe(0);
      // The derived face only widens which names the script can write down:
      // the write is denied by admission and never touches the workspace.
      expect(existsSync(target)).toBe(false);
      const denial = JSON.parse(
        stripNestedCallSummary(
          toolResultText(gateway.requests[1]!.body, "surface-write-1"),
        ).trim(),
      ) as { denied?: boolean; reason?: string };
      expect(denial.denied).toBe(true);
      expect(denial.reason).toBeTruthy();
    } finally {
      rmSync(target, { force: true });
    }
  },
  TIMEOUT,
);

describe.skipIf(!tmuxAvailable())("tui: codemode nested permission slots", () => {
  test(
    "sequential in-script commands reuse one pending permission slot",
    async () => {
      const root = createIsolatedRoot();
      const markerOne = join(root.workspace, "slot-one.marker");
      const markerTwo = join(root.workspace, "slot-two.marker");
      installScript(
        root.workspace,
        "slot-one.sh",
        "printf 'SLOT_ONE_OUTPUT\\n'\n: > slot-one.marker\n",
      );
      installScript(
        root.workspace,
        "slot-two.sh",
        "printf 'SLOT_TWO_OUTPUT\\n'\n: > slot-two.marker\n",
      );
      const gateway = startGateway([
        fakeGatewayToolCall("codemode-slot-call", "codemode", {
          script:
            'var one = tools.call("run_command", JSON.stringify({ command: "./slot-" + "one" + ".sh" }));\n' +
            'var two = tools.call("run_command", JSON.stringify({ command: "./slot-" + "two" + ".sh" }));\n' +
            'text("SLOT_COMPLETE\\n" + one + "\\n" + two);',
        }),
        fakeGatewayFinalText("SLOT_MODEL_DONE"),
      ]);

      activeSession = await TmuxSession.create({
        cwd: root.workspace,
        env: gatewayEnv(root, gateway, "ask"),
        stderrPath: join(root.root, "stderr.log"),
        width: 120,
        height: 40,
      });
      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText(USER_PROMPT);

      await activeSession.waitForPane(
        (pane) => pane.includes(COMMAND_APPROVAL_PROMPT) && pane.includes("./slot-one.sh"),
        TIMEOUT,
      );
      await Bun.sleep(500);
      const onePending = (await activeSession.capturePaneGrid()).join("\n");
      expect(countOccurrences(onePending, COMMAND_APPROVAL_PROMPT)).toBe(1);
      expect(onePending).not.toContain("./slot-two.sh");

      await activeSession.sendKeys("1");
      await activeSession.waitForPane(
        (pane) => pane.includes(COMMAND_APPROVAL_PROMPT) && pane.includes("./slot-two.sh"),
        TIMEOUT,
      );
      expect(existsSync(markerOne)).toBe(true);
      expect(existsSync(markerTwo)).toBe(false);

      await activeSession.sendKeys("1");
      await activeSession.waitForText("SLOT_MODEL_DONE", TIMEOUT);
      expect(existsSync(markerOne)).toBe(true);
      expect(existsSync(markerTwo)).toBe(true);

      const result = toolResultText(gateway.requests[1]!.body, "codemode-slot-call");
      expect(result).toContain("SLOT_COMPLETE");
      expect(result).toContain("SLOT_ONE_OUTPUT");
      expect(result).toContain("SLOT_TWO_OUTPUT");
      expect(result).not.toContain("denied");
      expect(result.indexOf("SLOT_ONE_OUTPUT")).toBeLessThan(
        result.indexOf("SLOT_TWO_OUTPUT"),
      );
    },
    TIMEOUT * 3,
  );

  test(
    "a denied in-script command reaches the script as denied json",
    async () => {
      const root = createIsolatedRoot();
      const marker = join(root.workspace, "codemode-denied-marker.txt");
      installScript(
        root.workspace,
        "codemode-denied-probe.sh",
        "printf 'DENIED_PROBE_OUTPUT\\n'\n" +
          "printf 'ran\\n' > codemode-denied-marker.txt\n",
      );
      const gateway = startGateway([
        fakeGatewayToolCall("codemode-denied-call", "codemode", {
          script:
            'text(tools.call("run_command", JSON.stringify({ command: "./codemode-denied-probe.sh" })));',
        }),
        (body) => {
          const result = toolResultText(body, "codemode-denied-call");
          expect(result).toContain('"denied":true');
          expect(result).toContain("user_denied");
          return fakeGatewayFinalText("DENIAL_REPORTED");
        },
      ]);

      activeSession = await TmuxSession.create({
        cwd: root.workspace,
        env: gatewayEnv(root, gateway, "ask"),
        stderrPath: join(root.root, "stderr.log"),
        width: 120,
        height: 40,
      });
      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText(USER_PROMPT);

      const promptPane = await activeSession.waitForPane(
        (pane) => pane.includes(COMMAND_APPROVAL_PROMPT) &&
          pane.includes("./codemode-denied-probe.sh"),
        TIMEOUT,
      );
      expect(promptPane).toContain("./codemode-denied-probe.sh");
      await activeSession.sendKeys("3");
      await activeSession.waitForText("DENIAL_REPORTED", TIMEOUT);

      expect(existsSync(marker)).toBe(false);
      expect(
        countOccurrences(
          (await activeSession.capturePaneGrid()).join("\n"),
          COMMAND_APPROVAL_PROMPT,
        ),
      ).toBe(0);
      expect(gateway.requestCount()).toBe(2);
      expect(gateway.classifierRequests).toHaveLength(0);
    },
    TIMEOUT * 3,
  );

  test(
    "codemode-only profile narrows the model surface, not the script surface",
    async () => {
      const root = createIsolatedRoot();
      writeFileSync(
        join(root.workspace, "README.md"),
        "PROFILE_SURFACE_README" + "\n",
      );
      const profileDir = join(root.home, ".fx", "agents", "codemode-only");
      mkdirSync(profileDir, { recursive: true });
      writeFileSync(
        join(profileDir, "profile.json"),
        JSON.stringify({ description: "codemode-only", tools: ["codemode"] }) + "\n",
      );
      writeFileSync(
        join(profileDir, "prompt.md"),
        "Drive everything through codemode scripts." + "\n",
      );
      const gateway = startGateway([
        fakeGatewayToolCall("profile-nested-read", "codemode", {
          script:
            'const r = await tools.call("read_file", { path: "README.md" });' + 
            "\ntext(r);",
        }),
        fakeGatewayFinalText("PROFILE_READ_DONE"),
        fakeGatewayToolCall("profile-value", "codemode", { script: "1 + 1" }),
        fakeGatewayFinalText("PROFILE_VALUE_DONE"),
      ]);
      const session = await TmuxSession.create({
        cmd: FX_BIN + " --profile codemode-only",
        cwd: root.workspace,
        env: gatewayEnv(root, gateway),
        stderrPath: join(root.root, "profile-stderr.log"),
        width: 140,
        height: 50,
      });
      activeSession = session;
      await session.waitForComposer(TIMEOUT);

      await session.sendText("read through a script");
      await session.waitForText("PROFILE_READ_DONE", TIMEOUT);
      await session.sendText("compute a value");
      await session.waitForText("PROFILE_VALUE_DONE", TIMEOUT);

      // The model saw the codemode-only surface: no bare read_file call.
      const readBody = JSON.parse(gateway.requests[1]!.body);
      expect(readBody.tools.map((t: { name: string }) => t.name)).toEqual(["codemode"]);
      // The nested object-argument call resolved against the full registry.
      // TUI request order may interleave title requests; scan for the call.
      const findResult = (callId: string): string | undefined => {
        for (const request of gateway.requests) {
          const body = JSON.parse(request.body) as {
            prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
          };
          const part = (body.prompt ?? [])
            .flatMap((message) => message.content ?? [])
            .find((p) => p.type === "tool-result" && p.toolCallId === callId);
          if (part) return JSON.stringify((part as { output: unknown }).output);
        }
        return undefined;
      };
      const read = findResult("profile-nested-read");
      expect(read).toBeDefined();
      expect(read!).toContain("PROFILE_SURFACE_README");
      // A bare expression completion value reaches the model.
      const value = findResult("profile-value");
      expect(JSON.parse(value!).value).toBe("2\n");
      expect(gateway.classifierRequests).toHaveLength(0);
    },
    TIMEOUT * 2,
  );

});

// ISSUE-24 and ISSUE-25 (T-24-impl): model-visible failure feedback for
// common codemode script mistakes. The strings below are the pinned
// wording; a test that stops matching means the feedback changed.
describe("codemode script mistake feedback", () => {
  test("top-level return explains the allowed shapes", async () => {
    const root = createIsolatedRoot();
    const script = "var a = 1;\nreturn a;";
    const gateway = startGateway([
      fakeGatewayToolCall("return-hint-1", "codemode", { script }),
      fakeGatewayFinalText("RETURN_HINT_DONE"),
    ]);
    try {
      const result = await runFx(
        ["ask", "--quiet", "--json", "--yolo", "--no-save", "Trigger a top-level return."],
        { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
      const body = toolResultText(
        gateway.requests[1]!.body,
        "return-hint-1",
        "error-text",
      );
      expect(body).toContain(
        "SyntaxError: return not in a function (codemode.js:2:1). " +
          "top-level return is not allowed; use text() or make the last expression the result",
      );
    } finally {
      rmSync(root.workspace, { recursive: true, force: true });
    }
  }, TIMEOUT);

  test("run_command with the wrong key names the field it wanted", async () => {
    const root = createIsolatedRoot();
    const script =
      "var caught = \"\";" +
      "try { await tools.call(\"run_command\", JSON.stringify({ cmd: \"echo nope\" })); }" +
      "catch (e) { caught = String(e.message || e); }" +
      "text(caught);";
    const gateway = startGateway([
      fakeGatewayToolCall("field-detail-1", "codemode", { script }),
      fakeGatewayFinalText("FIELD_DETAIL_DONE"),
    ]);
    try {
      const result = await runFx(
        ["ask", "--quiet", "--json", "--yolo", "--no-save", "Probe the field mistake."],
        { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
      const body = toolResultText(gateway.requests[1]!.body, "field-detail-1");
      expect(body).toContain(
        "InvalidToolArguments: run_command requires field \"command\"; received fields: cmd",
      );
    } finally {
      rmSync(root.workspace, { recursive: true, force: true });
    }
  }, TIMEOUT);

  test("an unknown tool name in tools.call suggests the closest name", async () => {
    const root = createIsolatedRoot();
    const script =
      "var caught = \"\";" +
      "try { await tools.call(\"read_fil\", \"{}\"); }" +
      "catch (e) { caught = String(e.message || e); }" +
      "text(caught);";
    const gateway = startGateway([
      fakeGatewayToolCall("suggest-1", "codemode", { script }),
      fakeGatewayFinalText("SUGGEST_DONE"),
    ]);
    try {
      const result = await runFx(
        ["ask", "--quiet", "--json", "--yolo", "--no-save", "Probe an unknown name."],
        { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
      const body = toolResultText(gateway.requests[1]!.body, "suggest-1");
      expect(body).toContain("unknown codemode tool: read_fil. did you mean: read_file");
      expect(body).toContain("use searchTools(\"read_fil\") to discover tools");
    } finally {
      rmSync(root.workspace, { recursive: true, force: true });
    }
  }, TIMEOUT);
});
