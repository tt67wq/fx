import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
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

function createIsolatedRoot(): IsolatedRoot {
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
      permission: {},
      experimental: { codemode: true },
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
  outputType: "text" | "execution-denied" = "text",
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
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    const elapsedS = (Date.now() - startedAt) / 1000;
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).not.toBe(0);
    expect(elapsedS).toBeGreaterThan(20);
    expect(elapsedS).toBeLessThan(45);
    // The failure detail is not echoed by --quiet --json; the model
    // receives it as the follow-up request's tool result.
    const request = JSON.parse(gateway.requests[1]!.body) as {
      prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
    };
    const toolResult = (request.prompt ?? [])
      .flatMap((message) => message.content ?? [])
      .find((part) => part.type === "tool-result" && part.toolCallId === "budget-1");
    expect(toolResult).toBeDefined();
    const output = toolResult!.output as { type: string; value: string };
    expect(output.type).toBe("error-text");
    expect(output.value).toContain("Timeout");
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
// them at the head of the model-visible result (plan v2 section 3). The
// captured text crosses the 16KiB externalization threshold so the model
// sees only the head preview and the summary must stay visible there
// (review F1). The second read misses on purpose and returns a failure
// status without throwing, so the summary must record .failure for it
// (review F2).
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
    // The head summary survives externalization.
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
