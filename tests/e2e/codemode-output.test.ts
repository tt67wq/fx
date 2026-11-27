import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startDynamicFakeGateway,
} from "./tmux-helpers";

// ISSUE-12: a codemode capture past the 1MiB cap is impossible here, but a
// capture past the 16KiB externalization threshold is: the model sees head
// and tail halves joined by the omission marker, a stored handle, and the
// read_tool_result hint; a follow-up read_tool_result call returns the
// untouched middle bytes. Both the text() path and the large return-value
// path are covered.

const TIMEOUT = 30_000;

const HEAD_SENTINEL = "CODEMODE-HEAD|";
const MID_SENTINEL = "MIDDLE|" + "M".repeat(40) + "|END";
const TAIL_SENTINEL = "|CODEMODE-TAIL";
// Filler half runs are pure ASCII so byte offsets stay stable end to end.
const FILL = 150_000;

type IsolatedRoot = {
  root: string;

  home: string;
  workspace: string;
};

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(async () => {
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function createIsolatedRoot(): IsolatedRoot {
  const root = realpathSync(
    mkdtempSync(join(tmpdir(), "fx-codemode-output-e2e-")),
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
      experimental: { codemode: true },
    }) + "\n",
  );
  roots.push(root);
  return { root, home, workspace: realpathSync(workspace) };
}

function gatewayEnv(
  root: IsolatedRoot,
  gateway: ReturnType<typeof startDynamicFakeGateway>,
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-codemode-output-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

function toolResultOutput(
  body: string,
  toolCallId: string,
): string {
  const request = JSON.parse(body) as {
    prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
  };
  const result = (request.prompt ?? [])
    .flatMap((message) => message.content ?? [])
    .find((part) => part.type === "tool-result" && part.toolCallId === toolCallId);
  expect(result).toBeDefined();
  const output = result!.output as { type: string; value: string };
  return output.value as string;
}

test("a large text capture shows head and tail and reads the middle back", async () => {
  const root = createIsolatedRoot();
  const script =
    'text(' + JSON.stringify(HEAD_SENTINEL) + ' + "a".repeat(' + FILL + ') + ' +
    JSON.stringify(MID_SENTINEL) + ' + "b".repeat(' + FILL + ') + ' +
    JSON.stringify(TAIL_SENTINEL) + ');\n1;';
  let step = 0;
  let canonicalHandle = "";
  const gateway = startDynamicFakeGateway((body: string) => {
    switch (step++) {
      case 0:
        return fakeGatewayToolCall("big-1", "codemode", { script });
      case 1: {
        const output = toolResultOutput(body, "big-1");
        expect(output).toContain(HEAD_SENTINEL);
        expect(output).toContain(TAIL_SENTINEL);
        expect(output).toContain(" bytes omitted]...");
        expect(output).toContain("<tool_result_handle>");
        expect(output).toContain("Full result is stored outside session JSON. Use read_tool_result");
        const match = output.match(
          /<tool_result_handle>([^<]+)<\/tool_result_handle>/,
        );
        canonicalHandle = match?.[1] ?? "";
        expect(canonicalHandle.endsWith(".txt")).toBe(true);
        // The middle sentinel itself is far beyond the preview, so the
        // preview must not leak it.
        expect(output).not.toContain(MID_SENTINEL);
        return fakeGatewayToolCall("read-1", "read_tool_result", {
          handle: canonicalHandle.replace(/\.txt$/, ""),
          start_byte: HEAD_SENTINEL.length + FILL + 1,
          byte_count: MID_SENTINEL.length + 16,
        });
      }
      case 2: {
        const output = toolResultOutput(body, "read-1");
        expect(output).toContain(MID_SENTINEL);
        return fakeGatewayFinalText("MIDDLE_READ_DONE");
      }
      default:
        return new Response("unexpected request", { status: 500 });
    }
  });
  gateways.push(gateway);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "run the big output test"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    expect(result.stdout).toContain("MIDDLE_READ_DONE");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, 90000);

test("a nested codemode script reads the stored middle back through read_tool_result", async () => {
  const root = createIsolatedRoot();
  const script =
    'text(' + JSON.stringify(HEAD_SENTINEL) + ' + "a".repeat(' + FILL + ') + ' +
    JSON.stringify(MID_SENTINEL) + ' + "b".repeat(' + FILL + ') + ' +
    JSON.stringify(TAIL_SENTINEL) + ');\n1;';
  const midStart = HEAD_SENTINEL.length + FILL + 1;
  const midCount = MID_SENTINEL.length + 16;
  let step = 0;
  let canonicalHandle = "";
  const gateway = startDynamicFakeGateway((body: string) => {
    switch (step++) {
      case 0:
        return fakeGatewayToolCall("big-n1", "codemode", { script });
      case 1: {
        const output = toolResultOutput(body, "big-n1");
        expect(output).toContain("<tool_result_handle>");
        expect(output).toContain("Full result is stored outside session JSON. Use read_tool_result");
        const match = output.match(
          /<tool_result_handle>([^<]+)<\/tool_result_handle>/,
        );
        canonicalHandle = match?.[1] ?? "";
        expect(canonicalHandle.endsWith(".txt")).toBe(true);
        expect(output).not.toContain(MID_SENTINEL);
        // The follow-up stays inside the sandbox: the script itself calls
        // read_tool_result with the handle from the truncated output.
        const nested =
          "const mid = await tools.read_tool_result({ handle: " +
          JSON.stringify(canonicalHandle.replace(/\.txt$/, "")) +
          ", start_byte: " + midStart + ", byte_count: " + midCount +
          " });\n" +
          "text(mid);\n" +
          "1;";
        return fakeGatewayToolCall("nested-read-1", "codemode", { script: nested });
      }
      case 2: {
        const output = toolResultOutput(body, "nested-read-1");
        expect(output).toContain(MID_SENTINEL);
        // Negative: a traversal handle must come back as a readable store
        // failure inside the script, never a read of another directory.
        const negative =
          "let seen = \"\";" + "\n" +
          "try { seen = String(await tools.read_tool_result({ handle: \"../escape\", start_byte: 1, byte_count: 16 })); }" + "\n" +
          "catch (err) { seen = \"ERR:\" + (err && err.message ? err.message : String(err)); }" + "\n" +
          "text(seen);" + "\n" +
          "1;";
        return fakeGatewayToolCall("nested-traverse-1", "codemode", { script: negative });
      }
      case 3: {
        const output = toolResultOutput(body, "nested-traverse-1");
        expect(output).toContain("InvalidHandle");
        return fakeGatewayFinalText("SANDBOX_REREAD_DONE");
      }
      default:
        return new Response("unexpected request", { status: 500 });
    }
  });
  gateways.push(gateway);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "run the sandbox reread test"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    expect(result.stdout).toContain("SANDBOX_REREAD_DONE");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, 90000);
test("a large return value is stored and readable the same way", async () => {
  const root = createIsolatedRoot();
  // A bare trailing expression: the completion value rides out even
  // without text() or console.log.
  const script = JSON.stringify("RETURN-HEAD|" + "c".repeat(FILL) + "|RETURN-TAIL") + ';';
  let step = 0;
  const gateway = startDynamicFakeGateway((body: string) => {
    switch (step++) {
      case 0:
        return fakeGatewayToolCall("ret-1", "codemode", { script });
      case 1: {
        const output = toolResultOutput(body, "ret-1");
        expect(output).toContain("RETURN-HEAD|");
        expect(output).toContain("|RETURN-TAIL");
        expect(output).toContain(" bytes omitted]...");
        expect(output).toContain("<tool_result_handle>");
        const match = output.match(
          /<tool_result_handle>([^<]+)<\/tool_result_handle>/,
        );
        const handle = match?.[1] ?? "";
        expect(handle.endsWith(".txt")).toBe(true);
        return fakeGatewayToolCall("read-2", "read_tool_result", {
          handle: handle.replace(/\.txt$/, ""),
          start_byte: 12 + FILL - 4,
          byte_count: 40,
        });
      }
      case 2: {
        const output = toolResultOutput(body, "read-2");
        // The tail sentinel of the return value sits just after the filler.
        expect(output).toContain("c|RETURN-TAIL");
        return fakeGatewayFinalText("RETURN_READ_DONE");
      }
      default:
        return new Response("unexpected request", { status: 500 });
    }
  });
  gateways.push(gateway);
  try {
    const result = await runFx(
      ["ask", "--quiet", "--json", "run the return test"],
      { cwd: root.workspace, env: gatewayEnv(root, gateway), timeoutMs: TIMEOUT },
    );
    expect(result.code, "stderr: " + result.stderr.slice(0, 400)).toBe(0);
    expect(result.stdout).toContain("RETURN_READ_DONE");
  } finally {
    rmSync(root.workspace, { recursive: true, force: true });
  }
}, 90000);
