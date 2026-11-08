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
import { runFx } from "../evals/eval-helpers";
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
        toolResultText(codemodeGateway.requests[1]!.body, "parity-bridge-call").trim(),
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
        toolResultText(codemodeGateway.requests[1]!.body, "parity-bridge-call").trim(),
      ) as { denied?: boolean; reason?: string };
      expect(codemodeDenial.denied).toBe(true);
      expect(codemodeDenial.reason).toContain(String(directDenial.error?.reason));
    },
    TIMEOUT,
  );
});

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
});
