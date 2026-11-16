import { expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { MODERN_MCP_VERSION } from "./fixtures/mcp-modern-http";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
} from "./tmux-helpers";

// Multi round-trip requests (SEP-2322) over a headless `fx ask`.
//
// ISSUE-18: `fx ask` without a TTY declared no elicitation capability, so the
// first `input_required` answer ended the call before any retry round existed.
// These tests pin the retry round on the wire: it must exist, carry a fresh
// JSON-RPC id, answer every input request under the server's own key, echo the
// `requestState` bytes it received, and omit the field when none was sent.
//
// This mirrors the checks of the official conformance scenario
// `sep-2322-client-request-state` (tests/e2e/conformance/) so a regression is
// caught here, where CI runs it, and not only by the npm conformance job.

const MODEL = "openai/gpt-5";
const SERVER_KEY = "fixture";

type CallRecord = {
  raw: string;
  method: string;
  id: unknown;
  params: Record<string, unknown>;
};

// The requestState exactly as it goes out on the wire: a JSON string token
// holding a backslash-u escape and an escaped quote, so a client that re-encodes
// the value instead of echoing it cannot produce these bytes.
const ECHO_STATE_RAW_TOKEN = '"st\\u00e9-\\"x"';
const ECHO_STATE_VALUE = JSON.parse(ECHO_STATE_RAW_TOKEN) as string;

const MRTR_TOOLS = [
  "test_mrtr_echo_state",
  "test_mrtr_no_state",
  "test_mrtr_unrelated",
  "test_mrtr_no_result_type",
].map((name) => ({
  name,
  description: `MRTR fixture tool ${name}`,
  inputSchema: { type: "object", properties: {}, required: [] },
}));

const elicitationRequests = {
  confirm: {
    method: "elicitation/create",
    params: {
      message: "Please confirm to continue",
      requestedSchema: {
        type: "object",
        properties: { confirmed: { type: "boolean", description: "Confirm?" } },
      },
    },
  },
};

function completeResult(id: unknown, text: string, withResultType = true) {
  const result: Record<string, unknown> = { content: [{ type: "text", text }] };
  if (withResultType) result.resultType = "complete";
  return { jsonrpc: "2.0", id, result };
}

// A 2026-07-28 streamable-HTTP server that runs the same four MRTR exchanges
// as the pinned conformance fixture, and records every request body it reads.
async function startMrtrFixture() {
  const calls: CallRecord[] = [];
  const server: Server = createServer((request, response) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    request.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      let message: { id?: unknown; method?: string; params?: Record<string, unknown> };
      try {
        message = JSON.parse(raw);
      } catch {
        response.writeHead(400).end();
        return;
      }
      const method = message.method ?? "";
      const params = message.params ?? {};
      calls.push({ raw, method, id: message.id, params });
      // A string payload is already wire bytes: the echo_state answer injects a
      // raw requestState token and must not be encoded a second time.
      const send = (payload: unknown) => {
        const body = typeof payload === "string" ? payload : JSON.stringify(payload);
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end(body);
      };
      switch (method) {
        case "server/discover":
          return send({
            jsonrpc: "2.0",
            id: message.id,
            result: {
              resultType: "complete",
              ttlMs: 0,
              cacheScope: "private",
              supportedVersions: [MODERN_MCP_VERSION],
              capabilities: { tools: {} },
              serverInfo: { name: "fx-mrtr-fixture", version: "1.0.0" },
            },
          });
        case "tools/list":
          return send({
            jsonrpc: "2.0",
            id: message.id,
            result: { resultType: "complete", ttlMs: 0, cacheScope: "private", tools: MRTR_TOOLS },
          });
        case "tools/call": {
          const name = params.name as string;
          const answering = params.inputResponses !== undefined;
          if (name === "test_mrtr_unrelated") return send(completeResult(message.id, "unrelated-ok"));
          if (name === "test_mrtr_no_result_type") {
            return send(completeResult(message.id, "no-result-type-test-ok", false));
          }
          if (name === "test_mrtr_no_state") {
            if (answering) return send(completeResult(message.id, "no-state-ok"));
            return send({
              jsonrpc: "2.0",
              id: message.id,
              result: { resultType: "input_required", inputRequests: elicitationRequests },
            });
          }
          // test_mrtr_echo_state
          if (answering) return send(completeResult(message.id, "echo-state-ok"));
          const result = {
            jsonrpc: "2.0",
            id: message.id,
            result: {
              resultType: "input_required",
              inputRequests: elicitationRequests,
              requestState: "__RAW_STATE_TOKEN__",
            },
          };
          return send(
            JSON.stringify(result).replace('"__RAW_STATE_TOKEN__"', ECHO_STATE_RAW_TOKEN),
          );
        }
        default:
          response.writeHead(204).end();
          return;
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("mrtr fixture bound no port");
  return {
    url: `http://127.0.0.1:${address.port}/mcp`,
    calls,
    async stop() {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

// One headless ask: pick the tool, call it, finish. No TTY on any stream.
async function driveMrtr(toolName: string) {
  const fixture = await startMrtrFixture();
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-mcp-mrtr-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      permission_mode: "auto",
      permission: { [`mcp_${SERVER_KEY}_${toolName}`]: "allow" },
    }),
  );
  writeFileSync(
    join(home, ".fx", "mcp.json"),
    JSON.stringify({
      mcp: {
        [SERVER_KEY]: {
          type: "http",
          url: fixture.url,
          enabled: true,
          startup_timeout_ms: 5_000,
          operation_timeout_ms: 20_000,
        },
      },
    }),
  );
  const gateway = startFakeGateway(
    [
      fakeGatewayToolCall("select_mcp", "mcp_select_tool", {
        name: `mcp_${SERVER_KEY}_${toolName}`,
      }),
      fakeGatewayToolCall("call_mcp", `mcp_${SERVER_KEY}_${toolName}`, {}),
      fakeGatewayFinalText("MRTR e2e finished."),
    ],
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  try {
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", `Call the ${toolName} MCP tool.`],
      {
        cwd: workspace,
        timeoutMs: 60_000,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-mcp-mrtr-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: MODEL,
          FX_SOUND: "0",
          FX_TEST_SKIP_ONBOARDING: "1",
        },
      },
    );
    return {
      result,
      toolCalls: fixture.calls.filter((call) => call.method === "tools/call"),
      discover: fixture.calls.find((call) => call.method === "server/discover"),
    };
  } finally {
    gateway.stop();
    await fixture.stop();
    rmSync(root, { recursive: true, force: true });
  }
}


// The retry fields belong to `params`, not to `_meta` (ISSUE-18 H4): a server
// that reads `params.requestState` never sees them inside the meta object.
function assertRetryFieldsAreTopLevel(call: CallRecord) {
  const meta = (call.params._meta ?? {}) as Record<string, unknown>;
  for (const key of Object.keys(meta)) {
    expect(key.toLowerCase().includes("requeststate")).toBe(false);
    expect(key.toLowerCase().includes("inputresponses")).toBe(false);
  }
}

test("a headless input_required round is answered by a second tools/call", async () => {
  const { toolCalls } = await driveMrtr("test_mrtr_echo_state");
  expect(toolCalls.length).toBe(2);
  const [first, retry] = toolCalls;
  // The first round asks; it carries no retry fields of its own.
  expect(first.params.inputResponses).toBeUndefined();
  expect(first.params.requestState).toBeUndefined();
  // The retry answers every input request under the server's own key.
  const responses = retry.params.inputResponses as Record<string, unknown>;
  expect(Object.keys(responses)).toEqual(["confirm"]);
  // sep-2322-client-jsonrpc-id-different: the retry is a new request.
  expect(retry.id).not.toBe(first.id);
  // sep-2322-client-request-state-echoed: the value, then the exact bytes.
  expect(retry.params.requestState).toBe(ECHO_STATE_VALUE);
  expect(retry.raw).toContain(`"requestState":${ECHO_STATE_RAW_TOKEN}`);
  assertRetryFieldsAreTopLevel(retry);
});

test("a headless input_required round without requestState omits the field", async () => {
  const { toolCalls } = await driveMrtr("test_mrtr_no_state");
  expect(toolCalls.length).toBe(2);
  const [first, retry] = toolCalls;
  expect(Object.keys(retry.params.inputResponses as object)).toEqual(["confirm"]);
  expect(retry.id).not.toBe(first.id);
  // sep-2322-client-no-state-omitted: no key at all, not an empty one.
  expect("requestState" in retry.params).toBe(false);
  expect(retry.raw.includes("requestState")).toBe(false);
  assertRetryFieldsAreTopLevel(retry);
});

test("an unrelated call between MRTR rounds carries no retry fields", async () => {
  const { toolCalls } = await driveMrtr("test_mrtr_unrelated");
  // sep-2322-client-parallel-isolation.
  expect(toolCalls.length).toBe(1);
  expect(toolCalls[0].params.inputResponses).toBeUndefined();
  expect(toolCalls[0].params.requestState).toBeUndefined();
});

test("a result without resultType is complete and never retried", async () => {
  const { toolCalls } = await driveMrtr("test_mrtr_no_result_type");
  // sep-2322-default-result-type-complete.
  expect(toolCalls.length).toBe(1);
  expect(toolCalls[0].params.inputResponses).toBeUndefined();
});
