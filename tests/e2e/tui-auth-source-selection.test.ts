import { afterEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { closeStatusPanel, panelAuth, readStatusPanel, waitForStatusPanel } from "./info-panel";
import { readTapeFrames } from "./render-lab/tape";
import { equivalentPngEncodings } from "./fixtures/image-encoding";
import { rootSessionIds, sessionDir } from "./saved-sessions";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  heldFakeGatewayFinalText,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const HAS_TMUX = tmuxAvailable();
if (process.env.FX_REQUIRE_TMUX === "1" && !HAS_TMUX) {
  throw new Error("tmux is required for tui-auth-source-selection.test.ts");
}

const tmuxTest = test.skipIf(!HAS_TMUX);
const profileStoredKeyTmuxTest = test.skipIf(!HAS_TMUX || process.platform === "darwin");
const TIMEOUT = 30_000;
const ENV_TOKEN = "env-api-key-token";
const LOGIN_TOKEN = "fx-login-token";
const STORED_TOKEN = "stored-api-key-token";
const LOGIN_RESPONSE = "LOGIN_SOURCE_RESPONSE";
const STORED_RESPONSE = "STORED_SOURCE_RESPONSE";
const ENV_RESPONSE = "ENV_SOURCE_RESPONSE";
const RESTART_RESPONSE = "RESTART_SOURCE_RESPONSE";
const DIRECT_LOGIN_RESPONSE = "DIRECT_LOGIN_RESPONSE";
const LOGOUT_FALLBACK_RESPONSE = "LOGOUT_FALLBACK_RESPONSE";
const REFRESH_RECOVERY_RESPONSE = "REFRESH_RECOVERY_RESPONSE";
const ACQUIRED_LOGIN_TOKEN = "acquired-login-token";

let session: TmuxSession | null = null;
let home: string | null = null;
let stderrPath: string | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let oauth: ReturnType<typeof startFakeOAuth> | null = null;
let creditsGateway: ReturnType<typeof startFakeCreditsGateway> | null = null;
let catcher: ReturnType<typeof startRequestCatcher> | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  gateway?.stop();
  gateway = null;
  oauth?.stop();
  oauth = null;
  creditsGateway?.stop();
  creditsGateway = null;
  catcher?.stop();
  catcher = null;
  if (home) rmSync(home, { recursive: true, force: true });
  home = null;
  stderrPath = null;
});

function writeSeededFxLogin(
  testHome: string,
  expiresAtMs = Date.now() + 60 * 60 * 1000,
  issuer = "https://vercel.com",
  teamId?: string,
): void {
  const fxDir = join(testHome, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, "auth.json");
  const auth: Record<string, string | number> = {
    version: 1,
    issuer,
    client_id: "test-client",
    access_token: LOGIN_TOKEN,
    refresh_token: "seeded-refresh-token",
    expires_at_ms: expiresAtMs,
    scope: "openid",
    token_type: "Bearer",
  };
  if (teamId) {
    auth.team_id = teamId;
    auth.team_slug = "example-internal-team";
  }
  writeFileSync(authPath, JSON.stringify(auth) + "\n", { mode: 0o600 });
  chmodSync(authPath, 0o600);
}

async function startFx(
  testHome: string,
  testStderrPath: string,
  fakeGateway: ReturnType<typeof startFakeGateway>,
  oauthIssuerUrl?: string,
  tracePath?: string,
  envOverrides: Record<string, string | undefined> = {},
  cwd?: string,
  resumeId?: string,
  launchArgs: string[] = [],
): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: [FX_BIN, ...launchArgs, ...(resumeId ? ["--resume", `'${resumeId}'`] : [])].join(" "),
    cwd,
    env: {
      HOME: testHome,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_GATEWAY_BASE_URL: fakeGateway.baseUrl,
      FX_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${fakeGateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_AUTO_UPGRADE: "0",
      FX_NO_OPEN_BROWSER: "1",
      FX_OAUTH_CLIENT_ID: "test-client",
      FX_TEST_OAUTH_ISSUER_URL: oauthIssuerUrl,
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: tracePath ? "auth,prompt" : undefined,
      ...envOverrides,
    },
    stderrPath: testStderrPath,
    width: 100,
    height: 30,
  });
}

function startRequestCatcher() {
  const requests: Array<{ method: string; path: string }> = [];
  const server = Bun.serve({
    hostname: "0.0.0.0",
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      requests.push({ method: request.method, path: url.pathname });
      return Response.json({ revoked: true });
    },
  });
  return {
    endpoint: `http://localhost.:${server.port}/oauth/revoke`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

function startFakeCreditsGateway() {
  const requests: Array<{
    method: string;
    path: string;
    authorization: string | null;
  }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      requests.push({
        method: request.method,
        path: new URL(request.url).pathname,
        authorization: request.headers.get("authorization"),
      });
      return Response.json({ balance: "42", used: "7", plan: "pro" });
    },
  });
  return {
    url: `http://127.0.0.1:${server.port}/v1/credits`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

function startFakeOAuth(
  accessToken: string | null,
  revocationEndpoint?: string,
  tokenExpiresIn = 3600,
  successfulTokenResponses = Number.POSITIVE_INFINITY,
  options: {
    deviceError?: string;
    rejectAllDeviceClients?: boolean;
    tokenDelayMs?: number;
    revokeDelayMs?: number;
    discoveryDelayMs?: number;
    teamsDelayMs?: number;
    rejectRefreshGrant?: boolean;
    beforeRefreshResponse?: () => void | Promise<void>;
    teams?: Array<{ id: string; slug: string; name: string }>;
  } = {},
) {
  const providerDetail = `provider rejected ${LOGIN_TOKEN}, ${ENV_TOKEN}, and seeded-refresh-token`;
  const requests: Array<{
    method: string;
    path: string;
    authorization: string | null;
    clientId?: string;
    grantType?: string;
    revocation?: { tokenTypeHint: string; validForm: boolean };
  }> = [];
  let tokenResponseCount = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      requests.push({
        method: request.method,
        path: url.pathname,
        authorization: request.headers.get("authorization"),
      });
      const recordedRequest = requests[requests.length - 1];
      const baseUrl = `http://127.0.0.1:${server.port}`;
      switch (url.pathname) {
        case "/.well-known/openid-configuration":
          if (options.discoveryDelayMs) await Bun.sleep(options.discoveryDelayMs);
          return Response.json({
            issuer: baseUrl,
            device_authorization_endpoint: `${baseUrl}/oauth/device`,
            token_endpoint: `${baseUrl}/oauth/token`,
            revocation_endpoint:
              revocationEndpoint ?? `${baseUrl}/oauth/revoke`,
          });
        case "/oauth/device": {
          const form = await request.formData();
          const clientId = form.get("client_id");
          recordedRequest.clientId = typeof clientId === "string" ? clientId : undefined;
          if (
            options.deviceError &&
            (options.rejectAllDeviceClients || clientId === "test-client")
          ) {
            return Response.json({
              error: options.deviceError,
              error_description: providerDetail,
            }, { status: 400 });
          }
          return Response.json({
            device_code: "device-code",
            user_code: "TEST-CODE",
            verification_uri: `${baseUrl}/verify`,
            verification_uri_complete: `${baseUrl}/verify?code=TEST-CODE`,
            expires_in: 60,
            interval: 0,
          });
        }
        case "/oauth/token": {
          if (options.tokenDelayMs) await Bun.sleep(options.tokenDelayMs);
          const form = await request.formData();
          const clientId = form.get("client_id");
          recordedRequest.clientId = typeof clientId === "string" ? clientId : undefined;
          const grantType = form.get("grant_type");
          recordedRequest.grantType = typeof grantType === "string" ? grantType : undefined;
          if (grantType === "refresh_token") {
            await options.beforeRefreshResponse?.();
          }
          tokenResponseCount += 1;
          if (
            (options.rejectRefreshGrant && grantType === "refresh_token") ||
            accessToken === null ||
            tokenResponseCount > successfulTokenResponses
          ) {
            return Response.json({
              error: "invalid_grant",
              error_description: `rejected ${LOGIN_TOKEN} while ${ENV_TOKEN} was available`,
            }, { status: 400 });
          }
          return Response.json({
            access_token: accessToken,
            refresh_token: "acquired-refresh-token",
            expires_in: tokenExpiresIn,
            scope: "openid offline_access use:ai-gateway",
            token_type: "Bearer",
          });
        }
        case "/v2/teams":
          if (options.teamsDelayMs) await Bun.sleep(options.teamsDelayMs);
          return Response.json({ teams: options.teams ?? [] });
        case "/oauth/revoke": {
          if (options.revokeDelayMs) await Bun.sleep(options.revokeDelayMs);
          const form = await request.formData();
          const tokenTypeHint = form.get("token_type_hint");
          const token = form.get("token");
          const tokenMatchesHint =
            (tokenTypeHint === "refresh_token" &&
              (token === "seeded-refresh-token" ||
                token === "acquired-refresh-token")) ||
            (tokenTypeHint === "access_token" &&
              (token === LOGIN_TOKEN || token === accessToken));
          const validForm =
            form.get("client_id") === "test-client" && tokenMatchesHint;
          recordedRequest.revocation = {
            tokenTypeHint:
              typeof tokenTypeHint === "string" ? tokenTypeHint : "missing",
            validForm,
          };
          return Response.json(
            !validForm ? { error: providerDetail } : { revoked: true },
            { status: !validForm ? 400 : 200 },
          );
        }
        default:
          return new Response("not found", { status: 404 });
      }
    },
  });
  return {
    issuerUrl: `http://127.0.0.1:${server.port}`,
    providerDetail,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

tmuxTest("pending gateway prompt retries repaired credential storage without changing accounts", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-prompt-storage-retry-"));
  stderrPath = join(home, "stderr.log");
  gateway = startFakeGateway([fakeGatewayFinalText("GATEWAY_STORAGE_RECOVERED")]);
  oauth = startFakeOAuth("unused-token");
  writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    provider: "gateway",
    credential_source: "fx_login",
    models: { gateway: FAKE_GATEWAY_MODEL },
  }));
  const alias = join(home, "auth.alias");
  linkSync(join(home, ".fx", "auth.json"), alias);
  session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
    FX_MODEL: undefined,
  });
  await session.waitForComposer(TIMEOUT);
  const prompt = "STORAGE_RETRY_gateway";
  await session.sendText(prompt);
  await session.waitForPane((pane) => pane.includes(prompt) && pane.slice(pane.lastIndexOf(prompt) + prompt.length).includes("auth:"), TIMEOUT);
  const scrollback = await session.captureFullScrollback();
  expect(scrollback.slice(scrollback.lastIndexOf(prompt) + prompt.length)).toContain("Saved credential storage is unavailable");
  expect(gateway.requests).toHaveLength(0);
  expect(oauth.requests).toHaveLength(0);

  unlinkSync(alias);
  await session.sendKeys("Enter");
  await session.waitForText("GATEWAY_STORAGE_RECOVERED", TIMEOUT);
  const requests = gateway.requests;
  expect(requests).toHaveLength(1);
  expect(JSON.stringify(requests[0]!.body)).toContain(prompt);
  expect(gateway.requests[0]!.headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
  expect(JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8")).provider).toBe("gateway");
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}, TIMEOUT);

tmuxTest("provider recovery validates a Gateway team after a cancelled turn", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-cancel-team-selection-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  let release!: () => void;
  const held = new Promise<void>((resolve) => { release = resolve; });
  gateway = startFakeGateway([
    async () => { await held; return fakeGatewayFinalText("CANCELLED_TEAM_RESPONSE"); },
    fakeGatewayFinalText("TEAM_AFTER_CANCEL_RESPONSE"),
  ]);
  oauth = startFakeOAuth(LOGIN_TOKEN, undefined, 3600, Infinity, {
    teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
  });
  writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");
  try {
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Hold this request until cancelled.");
    const deadline = Date.now() + TIMEOUT;
    while (gateway.requests.length === 0) {
      if (Date.now() > deadline) throw new Error("Gateway request did not start");
      await Bun.sleep(20);
    }
    await session.sendKeys("C-c");
    await session.waitForText("What can fx do differently?", TIMEOUT);
    release();
    await selectFxLoginCredential(session);
    expect(gateway.modelRequests.some((request) =>
      request.headers.get("authorization") === `Bearer ${LOGIN_TOKEN}`)).toBe(true);
    await session.sendText("Use the selected Vercel team.");
    await session.waitForText("TEAM_AFTER_CANCEL_RESPONSE", TIMEOUT);
    expect(gateway.requests.at(-1)?.headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  } finally {
    release();
  }
}, 60_000);

tmuxTest("pending Gateway prompt waits for valid saved preferences and a repaired login", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-prompt-preference-retry-"));
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  const settingsPath = join(home, ".fx", "settings.json");
  const settings = JSON.stringify({ provider: "gateway", credential_source: "fx_login", models: { gateway: FAKE_GATEWAY_MODEL } });
  writeFileSync(settingsPath, settings);
  stderrPath = join(home, "stderr.log");
  gateway = startFakeGateway([fakeGatewayFinalText("PREFERENCE_REPAIRED")]);
  oauth = startFakeOAuth("unused-token");
  session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, { FX_MODEL: undefined });
  await session.waitForComposer(TIMEOUT);
  writeFileSync(settingsPath, "not-json");
  await session.sendText("PREFERENCE_RETRY_PROMPT");
  await session.waitForText("Could not load authentication settings", TIMEOUT);
  expect(gateway.requests).toHaveLength(0);

  writeFileSync(settingsPath, settings);
  await session.sendKeys("Enter");
  await session.waitForPane(
    (pane) => pane.lastIndexOf("fx needs access to Vercel AI Gateway") > pane.lastIndexOf("Could not load authentication settings"),
    TIMEOUT,
  );
  expect(gateway.requests).toHaveLength(0);
  writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
  await session.sendKeys("Enter");
  await session.waitForText("PREFERENCE_REPAIRED", TIMEOUT);
  expect(gateway.requests).toHaveLength(1);
  expect(JSON.stringify(gateway.requests[0]!.body)).toContain("PREFERENCE_RETRY_PROMPT");
  expect(gateway.requests[0]!.headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
  expect(oauth.requests).toHaveLength(0);
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}, TIMEOUT);

test("Vercel CLI keeps an issuer authorization denial distinct from persistence failure", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-vercel-authorization-denied-"));
  oauth = startFakeOAuth("unused-token", undefined, 3600, Number.POSITIVE_INFINITY, {
    deviceError: "access_denied",
    rejectAllDeviceClients: true,
  });
  const result = await runFx(["login", "vercel"], { env: {
    HOME: home,
    AI_GATEWAY_API_KEY: undefined,
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_NO_OPEN_BROWSER: "1",
    FX_OAUTH_CLIENT_ID: "test-client",
    FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
  }, timeoutMs: TIMEOUT });
  expect(result.code).toBe(1);
  expect(result.stderr).toContain("authorization denied");
  expect(result.stderr).not.toContain("Credential could not be saved");
  expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
  expect(oauth.requests.filter((request) => request.path === "/oauth/token")).toHaveLength(0);
}, TIMEOUT);

test("Vercel CLI reports a post-authorization save failure without claiming authorization was denied", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-vercel-save-failure-"));
  gateway = startFakeGateway([]);
  oauth = startFakeOAuth("new-token", undefined, 3600, Number.POSITIVE_INFINITY, {
    tokenDelayMs: 300,
    teams: [{ id: "team_fixture", slug: "fixture", name: "Fixture" }],
  });
  writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
  const authPath = join(home, ".fx", "auth.json");
  const previous = readFileSync(authPath, "utf8");
  const login = runFx(["login", "vercel"], { env: {
    HOME: home,
    AI_GATEWAY_API_KEY: ENV_TOKEN,
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_NO_OPEN_BROWSER: "1",
    FX_OAUTH_CLIENT_ID: "test-client",
    FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  }, timeoutMs: TIMEOUT });
  const deadline = Date.now() + 10_000;
  while (!oauth.requests.some((request) => request.path === "/oauth/token") && Date.now() < deadline) await Bun.sleep(5);
  expect(oauth.requests.some((request) => request.path === "/oauth/token")).toBe(true);
  chmodSync(authPath, 0o400);
  const result = await login;
  expect(result.code).toBe(1);
  expect(result.stderr).toContain("Credential could not be saved");
  expect(result.stderr).not.toContain("authorization denied");
  expect(result.stdout).not.toContain("Signed in");
  expect(readFileSync(authPath, "utf8")).toBe(previous);
  expect(gateway.requests).toHaveLength(0);
}, TIMEOUT);

tmuxTest(
  "malformed sessions and read-only locks never become missing authentication",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-auth-storage-error-kinds-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth("unused-token");
    for (const damage of ["malformed", "lock"]) {
      writeSeededFxLogin(home, damage === "lock" ? 0 : Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
      if (damage === "malformed") {
        writeFileSync(join(home, ".fx", "auth.json"), "not-json", { mode: 0o600 });
      } else {
        writeFileSync(join(home, ".fx", "auth.lock"), "");
        chmodSync(join(home, ".fx", "auth.lock"), 0o400);
      }
      session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
      await session.waitForComposer(TIMEOUT);
      await session.sendKeys("Escape");
      await session.sendKeys("C-u");
      await openProviderPicker(session);
      await session.sendText("vercel");
      await session.waitForPane((pane) => pane.includes("oauth") && pane.includes("api-key"), TIMEOUT);
      await session.sendKeys("Enter");
      await session.waitForText("Vercel AI Gateway: Saved credential storage is unavailable", 10_000);
      expect(await session.captureFullScrollback()).not.toContain("Waiting for authorization");
      expect(oauth.requests).toHaveLength(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      await session.kill();
      session = null;
    }
  },
  60_000,
);

for (const command of ["/provider", "/login", "/setup"]) {
  tmuxTest(`provider picker retains type-ahead after ${command} Enter`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-provider-typeahead-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);

    await session.sendLiteral(`${command}\rvercel`);
    const prefix = command === "/login" ? "/login" : "/provider";
    await session.waitForPane(
      (pane) => pane.split("\n").some((line) => line.trim() === `┃ ${prefix} vercel`) && /^\s+vercel( · current)?\s*$/m.test(pane),
      TIMEOUT,
    );
    await session.sendKeys("BSpace");
    await session.waitForPane(
      (pane) => pane.split("\n").some((line) => line.trim() === `┃ ${prefix} verce`),
      TIMEOUT,
    );
    await session.sendKeys("Escape");
    await session.sendKeys("C-u");
    await session.sendLiteral("retained draft");
    await session.waitForText("retained draft", TIMEOUT);
    expect(gateway.requests).toHaveLength(0);
    expect(await session.captureFullScrollback()).not.toContain("Authorize with Vercel");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  }, TIMEOUT * 2);
}

tmuxTest("provider picker consumes selection keys while inventory is pending", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-provider-pending-"));
  stderrPath = join(home, "stderr.log");
  gateway = startFakeGateway([]);
  session = await startFx(home, stderrPath, gateway);
  await session.waitForComposer(TIMEOUT);

  await session.sendLiteral("/provider\rver\t\r");
  await session.waitForPane(
    (pane) => pane.split("\n").some((line) => line.trim() === "┃ /provider ver") && /^\s+vercel( · current)?\s*$/m.test(pane),
    TIMEOUT,
  );
  expect(gateway.requests).toHaveLength(0);
  await session.sendKeys("Tab");
  await session.waitForText("/provider vercel", TIMEOUT);
  await session.sendKeys("Escape");
  await session.sendKeys("C-u");
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}, TIMEOUT * 2);

for (const scenario of [
  { name: "bare provider", command: "/provider" },
  { name: "setup alias", command: "/setup" },
  { name: "login alias", command: "/login" },
  { name: "typed provider query", command: "/provider " },
]) {
  tmuxTest(`first Enter reports busy provider flow for ${scenario.name}`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-provider-picker-busy-"));
    stderrPath = join(home, "stderr.log");
    let cancelled = false;
    let heartbeat: ReturnType<typeof setInterval> | undefined;
    const encoder = new TextEncoder();
    gateway = startFakeGateway([() => new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(encoder.encode('data: {"type":"text-delta","delta":"The response remains active.\\n\\n"}\n\n'));
        heartbeat = setInterval(() => controller.enqueue(encoder.encode(": keep-alive\n\n")), 100);
      },
      cancel() {
        cancelled = true;
        clearInterval(heartbeat);
      },
    }), { headers: { "content-type": "text/event-stream" } })]);
    try {
      session = await startFx(home, stderrPath, gateway);
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Keep the response active while I inspect provider settings.");
      await session.waitForText("Generating", TIMEOUT);

      await session.sendText(scenario.command);
      const notice = "Provider switching is unavailable until active and queued work finishes.";
      await session.waitForText(notice, TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback.split(notice)).toHaveLength(2);
      expect(cancelled).toBe(false);
      expect(gateway.requests).toHaveLength(1);

      await session.sendKeys("C-u");
      await session.sendInterruptEscapePair(TIMEOUT);
      await session.waitForText("What can fx do differently?", TIMEOUT);
      await session.sendText(scenario.command.trim());
      await session.waitForPane(
        (pane) => pane.includes("vercel"),
        TIMEOUT,
      );
      expect(cancelled).toBe(true);
      expect(gateway.requests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      clearInterval(heartbeat);
    }
  }, TIMEOUT * 2);
}

tmuxTest(
  "unavailable configured credentials remain recoverable in TUI ask and ACP",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-auth-startup-failure-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([
      fakeGatewayFinalText("GATEWAY_RECOVERED_gateway"),
    ]);
    oauth = startFakeOAuth("unused-token");
    writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
    linkSync(join(home, ".fx", "auth.json"), join(home, "auth.json.alias"));
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SOUND: "0",
      FX_AUTO_UPGRADE: "0",
      FX_NO_OPEN_BROWSER: "1",
      FX_MODEL: undefined,
      FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
    };
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
      provider: "gateway",
      credential_source: "fx_login",
      models: { gateway: FAKE_GATEWAY_MODEL },
    }));
    const status = await runFx(["status", "--json"], { env });
    expect(status.code).toBe(0);
    expect(JSON.parse(status.stdout).auth_help).toContain("Saved credential storage is unavailable");
    const doctor = await runFx(["doctor", "--json"], { env });
    expect(doctor.timedOut).toBe(false);
    expect(doctor.stdout).toContain("Saved credential storage is unavailable");
    const ask = await runFx(["ask", "--json", "--no-save", "do not use another account"], { env });
    expect(ask.code).toBe(1);
    expect(JSON.parse(ask.stdout).error).toBe("CredentialStorageUnavailable");
    const acp = await runFx(["acp"], {
      env,
      stdin: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } }) + "\n",
    });
    expect(acp.code).toBe(0);
    const response = acp.stdout.trim().split("\n").map((line) => JSON.parse(line)).find((message) => message.id === 1);
    expect(response.error.code).toBe(-32600);
    expect(response.error.message).toContain("Saved credential storage is unavailable");
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, env);
    await session.waitForComposer(TIMEOUT);
    const unavailable = await readStatusPanel(session, TIMEOUT, (panel) => panel.fields["Auth help"] !== undefined);
    expect(unavailable.fields["Auth help"]).toContain("Saved credential storage is unavailable");
    await selectEnvKeyCredential(session);
    await session.sendText("Use the working Gateway account.");
    await session.waitForText("GATEWAY_RECOVERED_gateway", TIMEOUT);
    const recovered = await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");
    expect(recovered.labels).not.toContain("Auth help");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "all provider sign-in entries reject unavailable storage before OAuth",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-auth-storage-admission-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth("unused-token");
    writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
    linkSync(join(home, ".fx", "auth.json"), join(home, "auth.json.alias"));
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SOUND: "0",
      FX_AUTO_UPGRADE: "0",
      FX_NO_OPEN_BROWSER: "1",
      FX_OAUTH_CLIENT_ID: "test-client",
      FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
    };
    const aliased = await runFx(["login", "vercel"], { env, timeoutMs: 3000 });
    expect(aliased.timedOut).toBe(false);
    expect(aliased.code).toBe(1);
    expect(aliased.stderr).toContain("Saved credential storage is unavailable");
    expect(aliased.stdout).not.toContain("http");
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, env);
    await session.waitForComposer(TIMEOUT);
    await openProviderPicker(session);
    await session.sendKeys("Enter");
    await session.waitForPane((pane) => pane.includes("oauth") && pane.includes("api-key"), TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Saved credential storage is unavailable", TIMEOUT);
    expect(await session.captureFullScrollback()).not.toContain("Sign in with Vercel");
    unlinkSync(join(home, "auth.json.alias"));
    chmodSync(join(home, ".fx", "auth.json"), 0o400);
    const locked = await runFx(["login", "vercel"], { env, timeoutMs: 3000 });
    expect(locked.timedOut).toBe(false);
    expect(locked.code).toBe(1);
    expect(locked.stderr).toContain("Saved credential storage is unavailable");
    expect(locked.stdout).not.toContain("http");
    expect(oauth.requests).toHaveLength(0);
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  30_000,
);

tmuxTest(
  "an expired login during a request opens sign-in and finishes the request",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-recovery-sign-in-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([
      () => new Response(JSON.stringify({ error: { message: "token expired" } }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
      fakeGatewayFinalText("SIGNED_IN_RECOVERY_RESPONSE"),
    ]);
    // The refresh token is rejected, so only a new sign-in can help.
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Infinity, {
      rejectRefreshGrant: true,
      teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
    });
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Answer after I sign in again.");
    // fx opens the sign-in on its own; the fake approves the device code at
    // once, so the team choice comes next.
    const waiting = await session.waitForPane(
      (pane) => pane.includes("Choose a team to finish setup"),
      TIMEOUT,
    );
    expect(waiting).toContain("Sign-in expired · opening /login");
    expect(gateway.requests).toHaveLength(1);
    // The team list shows while the request waits.
    await session.waitForText("› Vercel Labs", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("SIGNED_IN_RECOVERY_RESPONSE", TIMEOUT);

    expect(gateway.requests).toHaveLength(2);
    expect(gateway.requests[0]?.headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
    expect(gateway.requests[1]?.headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "a prompt sent during a running turn queues at once while its fx login refresh is due",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-queued-refresh-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    const firstTurn = heldFakeGatewayFinalText();
    gateway = startFakeGateway([
      () => firstTurn.response,
      fakeGatewayFinalText("QUEUED_PROMPT_RESPONSE"),
    ]);
    // A refresh on the input loop would freeze the terminal this long.
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Infinity, {
      tokenDelayMs: 5_000,
    });
    // fx refreshes an fx login one minute before it expires, so this token
    // serves the first turn and falls due while that turn still runs.
    const refreshDueAt = Date.now() + 8_000;
    writeSeededFxLogin(home, refreshDueAt + 60_000, oauth.issuerUrl, "team_123");

    try {
      session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
        AI_GATEWAY_API_KEY: undefined,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Start the long answer.");
      while (gateway.requests.length < 1) {
        if (Date.now() >= refreshDueAt) throw new Error("the first turn did not start before the refresh came due");
        await Bun.sleep(25);
      }
      await session.waitForPane((pane) => pane.includes("Thinking"), TIMEOUT);
      await Bun.sleep(Math.max(0, refreshDueAt - Date.now()) + 250);

      const queued = "QUEUED_WHILE_REFRESH_DUE";
      await session.sendText(queued);
      const responsiveDraft = "TERMINAL_RESPONSIVE_WHILE_QUEUING";
      await session.sendLiteral(responsiveDraft);
      await session.waitForPane((pane) => pane.includes(responsiveDraft), 1_000);
      // Nothing refreshed on the way in; the worker refreshes when the turn starts.
      expect(oauth.requests.filter((request) => request.path === "/oauth/token")).toHaveLength(0);
      await session.sendKeys("C-u");
      await session.sendKeys("C-k");

      firstTurn.release("FIRST_TURN_RESPONSE");
      await session.waitForText("QUEUED_PROMPT_RESPONSE", TIMEOUT);
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).toContain(queued);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      firstTurn.dispose();
    }
  },
  60_000,
);

tmuxTest(
  "one Esc during the sign-in fx opened closes it and ends the request",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-recovery-sign-in-esc-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([
      () => new Response(JSON.stringify({ error: { message: "token expired" } }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
      fakeGatewayFinalText("MUST_NOT_RUN"),
    ]);
    // The device code stays unapproved, so the sign-in screen stays up.
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Infinity, {
      rejectRefreshGrant: true,
      tokenDelayMs: 20_000,
      teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
    });
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Stop while I would sign in.");
    await session.waitForPane(
      (pane) => pane.includes("Sign in with Vercel") && pane.includes("TEST-CODE") &&
        pane.includes("Sign-in expired · opening /login"),
      TIMEOUT,
    );
    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => !pane.includes("Sign in with Vercel") && !pane.includes("Sign-in expired"),
      TIMEOUT,
    );
    await session.waitForComposer(TIMEOUT);

    expect(gateway.requests).toHaveLength(1);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "Esc while a Vercel sign-in prepares stops its request and saves nothing",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-sign-in-preparing-esc-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    // Issuer discovery stays slow enough to see the preparing state.
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, 1, { discoveryDelayMs: 5_000 });

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    const preparing = await session.waitForPane(
      (pane) => pane.includes("Sign in with Vercel") && pane.includes("Preparing sign-in"),
      2_000,
    );
    expect(preparing).not.toContain("Authorize with Vercel");

    await session.sendKeys("Escape");
    await session.waitForPane((pane) => !pane.includes("Preparing sign-in"), 1_000);
    // Past the discovery delay, a sign-in that kept going would have asked
    // for a device code.
    await Bun.sleep(5_500);
    expect(oauth.requests.filter((request) => request.path === "/oauth/device")).toHaveLength(0);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "inline sign-in renders the device flow and Ctrl+C cancels without a session",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-inline-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, 1, {
      tokenDelayMs: 5_000,
    });

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    const signInScreen = await session.waitForPane(
      (pane) =>
        pane.includes("Sign in with Vercel") &&
        pane.includes("TEST-CODE") &&
        pane.includes("Authorize with Vercel") &&
        pane.includes("Waiting for authorization") &&
        pane.includes("enter reopens browser · esc cancels"),
      TIMEOUT,
    );
    expect(signInScreen).not.toContain("Starting Vercel sign-in");
    // The device page is a link, not its address printed out.
    expect(signInScreen).toMatch(/^   Open\s+Authorize with Vercel$/m);
    expect(signInScreen).not.toContain("/verify");

    await session.sendKeys("C-c");
    await session.waitForComposer(TIMEOUT);

    expect(session.isAlive()).toBe(true);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
    expect(await session.captureFullScrollback()).not.toContain("Signed in to Vercel.");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "provider picker walks every column and Left steps back",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-setup-hub-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, 1, {
      teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
    });
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.resizeWindow(100, 36);
    await session.sendText("/provider");
    const root = await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    expect(root).toContain("vercel · current");
    expect(root).not.toContain("Connections");

    // Right acts as Enter on the highlighted row: into the method column.
    await session.sendKeys("Right");
    const methods = await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    expect(methods).toContain("api-key · current");

    // oauth with a live session opens the team column; the env key is doing
    // inference, so no team is marked current.
    await session.sendKeys("Right");
    const teams = await session.waitForText("vercel-labs", TIMEOUT);
    expect(teams).not.toContain("vercel-labs · current");

    // Left reopens the previous column with the old choice highlighted.
    await session.sendKeys("Left");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );

    await session.sendKeys("Down");
    await session.sendKeys("Right");
    const keySources = await session.waitForPane(
      (pane) => pane.includes("env · AI_GATEWAY_API_KEY · current") && pane.includes("new · paste a key"),
      TIMEOUT,
    );
    expect(keySources).not.toContain("saved · saved by fx");

    await session.sendKeys("Down");
    await session.sendKeys("Right");
    const keyField = await session.waitForText("Paste or type a key", TIMEOUT);
    expect(keyField).toContain("enter saves");
    await session.sendKeys("Escape");
    await session.waitForComposer(TIMEOUT);

    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "first-run Vercel team Escape continues into the setup hub",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-onboarding-team-back-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      {
        teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
      },
    );

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
      FX_TEST_SKIP_ONBOARDING: "0",
    });
    await session.waitForText("Welcome to fx", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Vercel team · Search:", TIMEOUT);
    await session.sendKeys("Escape");
    const setup = await session.waitForPane(
      (pane) => pane.includes("Setup") && /Connections\s+connected/.test(pane),
      TIMEOUT,
    );
    expect(setup).toMatch(/^› Vercel team\s+choose a team$/m);
    expect(setup).not.toContain("Welcome to fx");
    expect(setup).not.toContain("sign in to manage");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest("/status keeps gateway authentication requirements without credentials", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-tui-status-provider-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  mkdirSync(join(home, ".fx"));
  const settingsPath = join(home, ".fx", "settings.json");
  const settings = JSON.stringify({ provider: "gateway", models: { gateway: "test-model" } });
  writeFileSync(settingsPath, settings);
  gateway = startFakeGateway([]);
  session = await startFx(home, stderrPath, gateway, undefined, undefined, {
    AI_GATEWAY_API_KEY: undefined,
    FX_MODEL: undefined,
  });
  await session.waitForComposer(TIMEOUT);
  await session.sendText("/status");
  const panel = await waitForStatusPanel(session, TIMEOUT, (shown) => shown.fields["Auth help"] !== undefined);
  const help = "fx needs access to Vercel AI Gateway.";
  expect(await session.captureFullScrollbackEscapes()).toContain(help);
  await closeStatusPanel(session, TIMEOUT);
  expect(panel.fields["Auth help"]).toStartWith(help);
  // Missing, and not refreshable.
  expect(panel.fields.Auth).toBe("missing");
  expect(gateway.requests).toHaveLength(0);
  expect(readFileSync(settingsPath, "utf8")).toBe(settings);
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}, TIMEOUT);

for (const [source, help] of [
  ["vercel_oidc_token", "VERCEL_OIDC_TOKEN is selected but unavailable."],
  ["stored_key", "A stored API key is selected but unavailable."],
] as const) {
  tmuxTest(`/status retains ${source} until another credential is selected`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-status-explicit-key-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    mkdirSync(join(home, ".fx"));
    const settingsPath = join(home, ".fx", "settings.json");
    const settings = JSON.stringify({ provider: "gateway", credential_source: source });
    writeFileSync(settingsPath, settings);
    gateway = startFakeGateway([fakeGatewayFinalText("EXPLICIT_KEY_RECOVERED")]);
    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);
    const missing = await readStatusPanel(session, TIMEOUT, (panel) => panel.fields["Auth help"] !== undefined);
    expect(missing.fields["Auth help"]).toStartWith(help);
    expect(missing.fields["Auth help"]).not.toContain("set AI_GATEWAY_API_KEY");
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(settingsPath, "utf8")).toBe(settings);

    await selectEnvKeyCredential(session);
    await session.sendText("Verify the account with a greeting.");
    await session.waitForText("EXPLICIT_KEY_RECOVERED", TIMEOUT);
    const recovered = await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");
    expect(recovered.labels).not.toContain("Auth help");
    expect(JSON.parse(readFileSync(settingsPath, "utf8")).credential_source).toBe("ai_gateway_api_key");
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  }, TIMEOUT);
}

tmuxTest("/status preserves a missing selected login through explicit key recovery", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-status-selected-login-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  mkdirSync(join(home, ".fx"));
  const settingsPath = join(home, ".fx", "settings.json");
  const settings = JSON.stringify({
    provider: "gateway",
    models: { gateway: FAKE_GATEWAY_MODEL },
    credential_source: "fx_login",
  });
  writeFileSync(settingsPath, settings);
  gateway = startFakeGateway([fakeGatewayFinalText("SELECTED_KEY_RECOVERED")]);
  session = await startFx(home, stderrPath, gateway);
  await session.waitForComposer(TIMEOUT);
  await session.sendText("/status");
  const missing = await waitForStatusPanel(session, TIMEOUT, (panel) => panel.fields["Auth help"] !== undefined);
  expect(await session.captureFullScrollbackEscapes()).toContain("fx login is selected but unavailable.");
  await closeStatusPanel(session, TIMEOUT);
  expect(missing.fields["Auth help"]).toStartWith("fx login is selected but unavailable.");
  expect(missing.fields["Auth help"]).toContain("Run /login to reconnect");
  expect(missing.fields["Auth help"]).not.toContain("or set AI_GATEWAY_API_KEY");
  expect(gateway.requests).toHaveLength(0);
  expect(readFileSync(settingsPath, "utf8")).toBe(settings);

  writeFileSync(settingsPath, "{broken");
  // Unreadable settings leave the selected credential unknown, so the panel
  // says so and shows no auth.
  const unreadable = await readStatusPanel(session, TIMEOUT, (panel) => panel.fields.Settings !== undefined);
  expect(unreadable.fields.Settings).toStartWith("couldn't be read: ");
  expect(unreadable.labels).not.toContain("Auth");
  expect(unreadable.labels).not.toContain("Auth help");
  expect(gateway.requests).toHaveLength(0);
  writeFileSync(settingsPath, settings);

  await selectEnvKeyCredential(session);
  await session.sendText("Verify the selected account with a greeting.");
  await session.waitForText("SELECTED_KEY_RECOVERED", TIMEOUT);
  expect(JSON.parse(readFileSync(settingsPath, "utf8")).credential_source).toBe("ai_gateway_api_key");
  writeFileSync(settingsPath, "{broken");
  const recovered = await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");
  expect(recovered.labels).not.toContain("Auth help");
  expect(recovered.labels).not.toContain("Settings");
  expect(readFileSync(settingsPath, "utf8")).toBe("{broken");
  expect(gateway.requests).toHaveLength(1);
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}, TIMEOUT);

async function startFxWithoutAuth(
  testHome: string,
  testStderrPath: string,
  fakeGateway: ReturnType<typeof startFakeGateway>,
  cwd?: string,
): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: FX_BIN,
    cwd,
    env: {
      HOME: testHome,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_OAUTH_CLIENT_ID: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_GATEWAY_BASE_URL: fakeGateway.baseUrl,
      FX_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${fakeGateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_AUTO_UPGRADE: "0",
    },
    stderrPath: testStderrPath,
    width: 100,
    height: 30,
  });
}

async function waitForModelRequestCount(
  fakeGateway: ReturnType<typeof startFakeGateway>,
  count: number,
): Promise<void> {
  const started = Date.now();
  while (fakeGateway.modelRequests.length < count) {
    if (Date.now() - started >= TIMEOUT) {
      throw new Error(
        `Timed out waiting for ${count} model requests; saw ${fakeGateway.modelRequests.length}`,
      );
    }
    await Bun.sleep(25);
  }
}

async function waitForOAuthRequestCount(
  fakeOAuth: ReturnType<typeof startFakeOAuth>,
  count: number,
): Promise<void> {
  const started = Date.now();
  while (fakeOAuth.requests.length < count) {
    if (Date.now() - started >= TIMEOUT) {
      throw new Error(
        `Timed out waiting for ${count} OAuth requests; saw ${fakeOAuth.requests.length}`,
      );
    }
    await Bun.sleep(25);
  }
}

async function waitForTrace(
  tracePath: string,
  needle: string,
  timeoutMs = TIMEOUT,
): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (existsSync(tracePath) && readFileSync(tracePath, "utf8").includes(needle)) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for trace: ${needle}`);
}

async function enterSwitchCredential(pickerSession: TmuxSession): Promise<void> {
  await pickerSession.sendKeys("Up");
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForPane(
    (pane) => pane.includes("Credential source") && pane.includes("Automatic"),
    TIMEOUT,
  );
}

async function openProviderPicker(pickerSession: TmuxSession): Promise<void> {
  await pickerSession.sendText("/provider");
  await pickerSession.waitForPane(
    (pane) => pane.includes("vercel"),
    TIMEOUT,
  );
}

// The inline picker replaced the hub's Credential source screen. Selecting the
// fx login now goes through the oauth method; with no teams to refine it, the
// choice commits the credential directly.
async function selectFxLoginCredential(pickerSession: TmuxSession): Promise<void> {
  await openProviderPicker(pickerSession);
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForPane(
    (pane) => pane.includes("oauth") && pane.includes("api-key"),
    TIMEOUT,
  );
  await pickerSession.sendKeys("Enter");
  const outcome = await pickerSession.waitForPane(
    (pane) => pane.includes("Switched credential to fx login") || pane.includes("vercel-labs"),
    TIMEOUT,
  );
  if (!outcome.includes("Switched credential to fx login")) {
    await pickerSession.sendKeys("Enter");
    await pickerSession.waitForText("Changed Vercel team", TIMEOUT);
  }
}

// Selecting the environment key goes through the api-key method's which-key
// column, which lists it as `env`.
async function selectEnvKeyCredential(pickerSession: TmuxSession): Promise<void> {
  await openProviderPicker(pickerSession);
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForPane(
    (pane) => pane.includes("oauth") && pane.includes("api-key"),
    TIMEOUT,
  );
  await pickerSession.sendKeys("Down");
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForPane(
    (pane) => pane.includes("env · AI_GATEWAY_API_KEY") && pane.includes("new · paste a key"),
    TIMEOUT,
  );
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForText("Switched credential to AI_GATEWAY_API_KEY", TIMEOUT);
}

function savedCredentialSource(testHome: string): string | undefined {
  const settingsPath = join(testHome, ".fx", "settings.json");
  if (!existsSync(settingsPath)) return undefined;
  return (JSON.parse(readFileSync(settingsPath, "utf8")) as { credential_source?: string })
    .credential_source;
}

profileStoredKeyTmuxTest(
  "stored-key setup persists ahead of the environment",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-stored-key-preference-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(STORED_RESPONSE)]);

    session = await startFx(home, stderrPath, gateway, undefined, undefined, {
      FX_DISABLE_KEYCHAIN: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");

    // Typing the full path exercises both space-advance columns: the space
    // after "vercel" opens the methods, the space after "api-key" opens the
    // which-key column, and Enter on "new" opens the masked field.
    await session.sendText("/provider vercel api-key new");
    await session.waitForText("Paste or type a key", TIMEOUT);
    await session.sendLiteralText(STORED_TOKEN);
    await session.sendKeys("Enter");
    await session.waitForText("Saved the API key to profile file and made it active", TIMEOUT);
    await session.sendText("/provider vercel api-key");
    const keyColumn = await session.waitForPane(
      (pane) => pane.includes("saved · saved by fx · current"),
      TIMEOUT,
    );
    expect(keyColumn).toContain("env · AI_GATEWAY_API_KEY");
    await session.sendKeys("Escape");
    await session.sendKeys("C-u");
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "stored API key (profile file)");
    expect(savedCredentialSource(home)).toBe("stored_key");

    const keyPath = join(home, ".fx", "api-key");
    expect(readFileSync(keyPath, "utf8")).toBe(STORED_TOKEN);
    expect(statSync(keyPath).mode & 0o777).toBe(0o600);

    await session.kill();
    session = await startFx(home, stderrPath, gateway, undefined, undefined, {
      FX_DISABLE_KEYCHAIN: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "stored API key (profile file)");
    await session.sendText("use the stored key after restart");
    await session.waitForText(STORED_RESPONSE, TIMEOUT);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${STORED_TOKEN}`);

    const output = await session.captureFullScrollback();
    expect(output).not.toContain(STORED_TOKEN);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "direct login persists ahead of the environment until the env key is selected",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-direct-login-preference-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([
      fakeGatewayFinalText(DIRECT_LOGIN_RESPONSE),
      fakeGatewayFinalText(RESTART_RESPONSE),
      fakeGatewayFinalText(ENV_RESPONSE),
    ]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }] },
    );

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");

    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Signed in to Vercel", TIMEOUT);
    await session.waitForText("Vercel team · Search:", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Changed Vercel team to Vercel Labs", TIMEOUT);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "fx login");
    expect(savedCredentialSource(home)).toBe("fx_login");
    await session.sendText("use the direct login credential");
    await session.waitForText(DIRECT_LOGIN_RESPONSE, TIMEOUT);
    expect(gateway.requests[0].headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );

    await session.kill();
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "fx login");
    await session.sendText("use the remembered direct login credential");
    await session.waitForText(RESTART_RESPONSE, TIMEOUT);
    expect(gateway.requests[1].headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );

    await selectEnvKeyCredential(session);
    expect(savedCredentialSource(home)).toBe("ai_gateway_api_key");
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");

    await session.kill();
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");
    await session.sendText("use automatic precedence after restart");
    await session.waitForText(ENV_RESPONSE, TIMEOUT);
    expect(gateway.requests[2].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);

    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "Change team activates and persists fx login ahead of the environment",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-team-preference-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(LOGIN_RESPONSE)]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      {
        teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
      },
    );
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");

    await openProviderPicker(session);
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("vercel-labs", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Changed Vercel team to Vercel Labs", TIMEOUT);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "fx login");
    expect(savedCredentialSource(home)).toBe("fx_login");

    const savedAuth = JSON.parse(readFileSync(join(home, ".fx", "auth.json"), "utf8")) as {
      team_id?: string;
      team_slug?: string;
    };
    expect(savedAuth.team_id).toBe("team_123");
    expect(savedAuth.team_slug).toBe("vercel-labs");

    await session.kill();
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "fx login");
    await session.sendText("use the selected team after restart");
    await session.waitForText(LOGIN_RESPONSE, TIMEOUT);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);

    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "API key and fx login coexist through selection, restart, login, and logout",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-lifecycle-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    const authPath = join(home, ".fx", "auth.json");
    gateway = startFakeGateway([
      fakeGatewayFinalText(ENV_RESPONSE),
      fakeGatewayFinalText(LOGIN_RESPONSE),
      fakeGatewayFinalText(RESTART_RESPONSE),
      fakeGatewayFinalText(DIRECT_LOGIN_RESPONSE),
      fakeGatewayFinalText(LOGOUT_FALLBACK_RESPONSE),
    ]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }] },
    );
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");
    const seededAuthFile = readFileSync(authPath, "utf8");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    const initial = await session.waitForComposer(TIMEOUT);
    expect(initial).not.toContain("Sign in with Vercel");
    expect(initial).not.toContain("Switch credential");

    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");
    await session.sendText("use normal startup precedence");
    await session.waitForText(ENV_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(authPath, "utf8")).toBe(seededAuthFile);

    await selectFxLoginCredential(session);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "fx login");
    const selectedAuth = JSON.parse(readFileSync(authPath, "utf8")) as {
      team_id?: string;
      team_slug?: string;
    };
    expect(selectedAuth.team_id).toBe("team_123");
    expect(selectedAuth.team_slug).toBe("vercel-labs");
    await session.sendText("use the selected login credential");
    await session.waitForText(LOGIN_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(2);
    expect(gateway.requests[1].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
    expect(JSON.parse(readFileSync(authPath, "utf8")).team_slug).toBe("vercel-labs");

    const firstRunOutput = await session.captureFullScrollback();
    const firstRunStderr = readFileSync(stderrPath, "utf8");
    await session.kill();
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    // The switch above is remembered, so the restart keeps fx login rather than
    // letting AI_GATEWAY_API_KEY reclaim it through precedence.
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "fx login");
    expect(JSON.parse(readFileSync(authPath, "utf8")).team_slug).toBe("vercel-labs");
    await session.sendText("use the remembered credential after restart");
    await session.waitForText(RESTART_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(3);
    expect(gateway.requests[2].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);

    // Acquiring a fresh login needs a signed-out state first; the remembered
    // seeded login would otherwise resolve straight into the team column.
    await session.sendText("/logout");
    await session.waitForText("Signed out of fx.", TIMEOUT);
    const oauthBase = oauth.requests.length;
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    const loginCompleted = await session.waitForText("Signed in to Vercel", TIMEOUT);
    expect(loginCompleted).not.toContain("Connections");
    expect(loginCompleted).toContain("Vercel team · Search:");
    await session.sendKeys("Enter");
    await session.waitForText("Changed Vercel team to Vercel Labs", TIMEOUT);
    const acquisition = oauth.requests
      .slice(oauthBase)
      .map((request) => `${request.method} ${request.path}`);
    expect(acquisition).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/device",
      "POST /oauth/token",
      "GET /v2/teams",
    ]);
    expect(oauth.requests[oauthBase + 3].authorization).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
    expect(oauth.requests[oauthBase + 1].clientId).toBe("test-client");
    expect(oauth.requests[oauthBase + 2].clientId).toBe("test-client");
    const acquiredAuth = JSON.parse(readFileSync(authPath, "utf8")) as {
      issuer: string;
      client_id: string;
      access_token: string;
      refresh_token: string;
    };
    expect(acquiredAuth.issuer).toBe(oauth.issuerUrl);
    expect(acquiredAuth.client_id).toBe("test-client");
    expect(acquiredAuth.access_token).toBe(ACQUIRED_LOGIN_TOKEN);
    expect(acquiredAuth.refresh_token).toBe("acquired-refresh-token");
    expect(statSync(authPath).mode & 0o777).toBe(0o600);
    expect(
      (await session.captureFullScrollback()).match(/Signed in to Vercel\./g) ?? [],
    ).toHaveLength(1);

    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "fx login");
    await session.sendText("direct login prompt");
    await session.waitForText(DIRECT_LOGIN_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(4);
    expect(gateway.requests[3].headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);

    const revokedBefore = completedRevocations(oauth).length;
    await session.sendText("/logout");
    await session.waitForText("Signed out of fx.", TIMEOUT);
    expect(existsSync(authPath)).toBe(false);
    // The issuer revocation runs after the local sign-out, off the input loop.
    await waitForRevocations(oauth, revokedBefore + 2);
    expect(await session.captureFullScrollback()).not.toContain("remote session could not be revoked");
    expect(completedRevocations(oauth).slice(-2)).toEqual([
      { tokenTypeHint: "refresh_token", validForm: true },
      { tokenTypeHint: "access_token", validForm: true },
    ]);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");
    await session.sendText("use the API key after logout");
    await session.waitForText(LOGOUT_FALLBACK_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(5);
    expect(gateway.requests[4].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);

    const output = `${firstRunOutput}\n${await session.captureFullScrollback()}`;
    const stderr = `${firstRunStderr}${readFileSync(stderrPath, "utf8")}`;
    for (const secret of [
      ENV_TOKEN,
      LOGIN_TOKEN,
      ACQUIRED_LOGIN_TOKEN,
      "seeded-refresh-token",
      "acquired-refresh-token",
      oauth.providerDetail,
    ]) {
      expect(output).not.toContain(secret);
      expect(stderr).not.toContain(secret);
    }
    expect(stderr).toBe("");
  },
  60_000,
);

tmuxTest(
  "searched Vercel login team stays open and loads private models",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-team-models-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([], {
      models(request) {
        const teamId = new URL(request.url).searchParams.get("teamId");
        const authenticated =
          request.headers.get("authorization") === `Bearer ${ACQUIRED_LOGIN_TOKEN}` &&
          teamId === "team_123";
        return [
          { id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] },
          ...(authenticated
            ? [{ id: "private/blue-hornbill", type: "language", tags: ["tool-use"] }]
            : []),
        ];
      },
    });
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      {
        teams: [
          { id: "team_456", slug: "other-team", name: "Other Team" },
          { id: "team_123", slug: "example-internal-team", name: "Example Internal Team" },
        ],
      },
    );

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      tracePath,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_TEST_GATEWAY_MODELS_URL: undefined,
        FX_TRACE_SCOPES: "auth,prompt,catalog",
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();

    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Vercel team · Search:", TIMEOUT);
    await session.sendKeys("Escape");
    const setupAfterSignIn = await session.waitForPane(
      (pane) => pane.includes("Setup") && /Connections\s+connected/.test(pane),
      TIMEOUT,
    );
    expect(setupAfterSignIn).toMatch(/^› Vercel team\s+choose a team$/m);
    expect(setupAfterSignIn).not.toContain("sign in to manage");
    await session.sendKeys("Enter");
    await session.waitForText("Vercel team · Search:", TIMEOUT);
    await session.resizeWindow(80, 5);
    await session.sendLiteralText("example");
    await session.waitForPane((pane) => pane.includes("Search: example"), TIMEOUT);
    const compactTeamPickerGrid = await session.capturePaneGrid();
    const compactSearchRow = compactTeamPickerGrid.findIndex((row) =>
      row.includes("Search: example"),
    );
    expect(compactSearchRow).toBeGreaterThanOrEqual(0);
    const compactSearchEnd =
      compactTeamPickerGrid[compactSearchRow]!.indexOf("Search: example") +
      "Search: example".length;
    expect(session.cursorPosition()).toEqual({ row: compactSearchRow, col: compactSearchEnd });

    await session.resizeWindow(80, 24);
    await session.waitForPane(
      (pane) =>
        pane.includes("Vercel team · Search:") &&
        pane.includes("Search: example") &&
        pane.includes("Example Internal Team") &&
        !pane.includes("Other Team"),
      TIMEOUT,
    );
    const teamPickerGrid = await session.capturePaneGrid();
    const searchRow = teamPickerGrid.findIndex((row) => row.includes("Search: example"));
    expect(searchRow).toBeGreaterThanOrEqual(0);
    const searchEnd =
      teamPickerGrid[searchRow]!.indexOf("Search: example") + "Search: example".length;
    expect(session.cursorPosition()).toEqual({ row: searchRow, col: searchEnd });
    await session.sendKeys("Enter");
    await session.waitForText("Changed Vercel team to Example Internal Team", TIMEOUT);
    await waitForModelRequestCount(gateway, 3);

    await session.sendText("/model");
    await session.waitForPane(
      (pane) =>
        pane.includes("private/blue-hornbill") &&
        !pane.includes("Authenticated model catalog loaded."),
      TIMEOUT,
    );

    for (const authenticatedRequest of gateway.modelRequests.slice(1)) {
      expect(authenticatedRequest.headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
      expect(authenticatedRequest.headers.get("x-vercel-ai-gateway-team")).toBeNull();
      expect(new URL(authenticatedRequest.url).searchParams.get("teamId")).toBe("team_123");
    }
    expect(gateway.modelRequests).toHaveLength(3);
    const trace = readFileSync(tracePath, "utf8");
    const catalogEvents = trace.split("\n").filter((line) =>
      line.includes("[catalog] event=model_catalog_load ")
    );
    expect(catalogEvents.at(-1)).toContain(
      "requested_access=authenticated credential_source=fx_login effective_access=authenticated",
    );
    for (const secret of [ACQUIRED_LOGIN_TOKEN, "team_123", "example-internal-team"]) {
      expect(trace).not.toContain(secret);
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "model catalog warmup follows auth source changes exactly once",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-catalog-lifecycle-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);

    await selectFxLoginCredential(session);
    await waitForModelRequestCount(gateway, 2);
    expect(gateway.modelRequests).toHaveLength(2);
    expect(gateway.modelRequests[1].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[1].headers.get("x-vercel-ai-gateway-team")).toBeNull();

    await session.sendText("/logout");
    await session.waitForText("Signed out of fx.", TIMEOUT);
    await waitForModelRequestCount(gateway, 3);
    expect(gateway.modelRequests).toHaveLength(3);
    expect(gateway.modelRequests[2].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

test(
  "fx login falls back once when a custom OAuth client is invalid",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-login-client-fallback-"));
    writeSeededFxLogin(home);
    const authPath = join(home, ".fx", "auth.json");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      {
        deviceError: "invalid_client",
        teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
      },
    );

    const result = await runFx(["login"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: ENV_TOKEN,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_NO_OPEN_BROWSER: "1",
        FX_OAUTH_CLIENT_ID: "test-client",
        FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
      },
      timeoutMs: TIMEOUT,
    });

    expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
    expect(result.stdout).toContain("Signed in to Vercel.");
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/device",
      "POST /oauth/device",
      "POST /oauth/token",
      "GET /v2/teams",
    ]);
    const deviceRequests = oauth.requests.filter(
      (request) => request.path === "/oauth/device",
    );
    expect(deviceRequests).toHaveLength(2);
    expect(deviceRequests[0].clientId).toBe("test-client");
    const fallbackClientId = deviceRequests[1].clientId;
    expect(fallbackClientId).toBeDefined();
    expect(fallbackClientId).not.toBe("test-client");
    const tokenRequests = oauth.requests.filter(
      (request) => request.path === "/oauth/token",
    );
    expect(tokenRequests).toHaveLength(1);
    expect(tokenRequests[0].clientId).toBe(fallbackClientId);

    const persisted = JSON.parse(readFileSync(authPath, "utf8")) as {
      client_id: string;
      access_token: string;
      team_id?: string;
      team_slug?: string;
    };
    expect(persisted.client_id).toBe(fallbackClientId);
    expect(persisted.access_token).toBe(ACQUIRED_LOGIN_TOKEN);
    expect(persisted.team_id).toBe("team_123");
    expect(persisted.team_slug).toBe("vercel-labs");
    expect(statSync(authPath).mode & 0o777).toBe(0o600);
    expect(savedCredentialSource(home)).toBe("fx_login");
    expect(gateway.modelRequests).toHaveLength(1);
    expect(gateway.modelRequests[0]!.headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );
    expect(gateway.modelRequests[0]!.headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(new URL(gateway.modelRequests[0]!.url).searchParams.get("teamId")).toBe("team_123");
    expect(result.stdout.match(/Code: TEST-CODE/g) ?? []).toHaveLength(1);
    expect(result.stdout).not.toContain(oauth.providerDetail);
    expect(result.stderr).toBe("");
  },
  60_000,
);

test(
  "fx teams validates Gateway before committing and persists fx login",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-cli-teams-validation-"));
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }] },
    );
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_old");

    const result = await runFx(["teams"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: ENV_TOKEN,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
      },
      timeoutMs: TIMEOUT,
    });

    expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
    expect(result.stdout).toContain("Selected Vercel team: Vercel Labs (vercel-labs).");
    expect(savedCredentialSource(home)).toBe("fx_login");
    const persisted = JSON.parse(
      readFileSync(join(home, ".fx", "auth.json"), "utf8"),
    ) as {
      team_id?: string;
      team_slug?: string;
    };
    expect(persisted.team_id).toBe("team_123");
    expect(persisted.team_slug).toBe("vercel-labs");
    expect(gateway.modelRequests).toHaveLength(2);
    for (const request of gateway.modelRequests) {
      expect(request.headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
      expect(new URL(request.url).searchParams.get("teamId")).toBe("team_123");
    }
  },
  60_000,
);

test(
  "fx teams preserves the previous team when Gateway rejects the candidate",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-cli-teams-rejected-"));
    gateway = startFakeGateway([], {
      models: () => new Response("rejected", { status: 401 }),
    });
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }] },
    );
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_old");

    const result = await runFx(["teams"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: ENV_TOKEN,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
      },
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(1);
    expect(result.stdout).not.toContain("Selected Vercel team");
    expect(result.stderr).toContain("selected team could not access AI Gateway");
    expect(savedCredentialSource(home)).toBeUndefined();
    const persisted = JSON.parse(
      readFileSync(join(home, ".fx", "auth.json"), "utf8"),
    ) as {
      team_id?: string;
    };
    expect(persisted.team_id).toBe("team_old");
  },
  60_000,
);

test("fx logout clears a remembered fx login source", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-cli-logout-preference-"));
  oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
  writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ credential_source: "fx_login" }) + "\n",
    { mode: 0o600 },
  );

  const result = await runFx(["logout"], {
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
    },
    timeoutMs: TIMEOUT,
  });

  expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
  expect(result.stdout).toContain("Signed out of fx.");
  expect(savedCredentialSource(home)).toBeUndefined();
  expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
});

test("fx models does not retry anonymously for an explicit credential", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-cli-models-explicit-auth-"));
  writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, "https://vercel.com", "team_123");
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ credential_source: "fx_login" }) + "\n",
    { mode: 0o600 },
  );
  let calls = 0;
  gateway = startFakeGateway([], {
    models: () => {
      calls += 1;
      if (calls === 1) return new Response("rejected", { status: 401 });
      return [{ id: "public/fallback", type: "language", tags: ["tool-use"] }];
    },
  });

  const result = await runFx(["models", "--json"], {
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
    },
    timeoutMs: TIMEOUT,
  });

  expect(result.code).toBe(1);
  expect(calls).toBe(1);
  expect(result.stdout).not.toContain("public/fallback");
  expect(result.stdout).toContain("AuthenticationRejected");
});

test("status never substitutes an environment key for a missing explicit login", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-cli-status-strict-source-"));
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ credential_source: "fx_login" }) + "\n",
    { mode: 0o600 },
  );

  const result = await runFx(["status", "--json"], {
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
    },
    timeoutMs: TIMEOUT,
  });

  expect(result.code).toBe(0);
  const status = JSON.parse(result.stdout) as { auth: string };
  expect(status.auth).toBe("missing");
  expect(result.stdout).not.toContain("AI_GATEWAY_API_KEY");
});

test("provider SSE framing preserves saved and resumed answers", async () => {
  const prefix = "CONTROL_PREFIX\n", answer = "EXPECTED_FINAL";
  for (const mode of ["no-space", "multiline", "invalid"]) {
    const profile = mkdtempSync(join(tmpdir(), "fx-sse-framing-"));
    const model = FAKE_GATEWAY_MODEL;
    const event = (text: string) => ({ type: "text-delta", id: "answer", delta: text });
    const terminal = { type: "finish", finishReason: { unified: mode === "invalid" ? "tool-calls" : "stop" } };
    const frame = (value: object) => "data: " + JSON.stringify(value) + "\n\n";
    let wire = frame(event(prefix));
    if (mode === "invalid") {
      const input = { path: "read-me.txt" };
      writeFileSync(join(profile, "read-me.txt"), "not admitted");
      wire += frame({ type: "tool-call", toolCallId: "read", toolName: "read_file", input });
      wire += "data: {invalid-json}\n\n";
    } else if (mode === "no-space") wire += "data:" + JSON.stringify(event(answer)) + "\n\n";
    else wire += JSON.stringify(event(answer), null, 2).split("\n").map(line => "data: " + line).join("\n") + "\n\n";
    wire += frame(terminal);
    if (mode === "multiline") wire = "\ufeff" + wire.replaceAll("\n", "\r\n");
    const replies = [new Response(wire, { headers: { "content-type": "text/event-stream" } }), fakeGatewayFinalText("RESUME_OK")];
    const gateway = startFakeGateway(replies);
    try {
      mkdirSync(join(profile, ".fx"), { recursive: true });
      writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider: "gateway", model }));
      const env = {
        HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined, FX_MODEL: model,
        FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_TEST_GATEWAY_MODELS_URL: gateway.baseUrl + "/coding-agent/v1/models",
        FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      };
      const first = await runFx(["ask", "--json", "--auto", "Report the supplied answer."], { cwd: profile, env, timeoutMs: TIMEOUT });
      const output = JSON.parse(first.stdout);
      expect(first.signal).toBeNull();
      expect(gateway.requests.length).toBe(1);
      if (mode === "invalid") {
        expect(first.code, first.stdout + first.stderr).toBe(1);
        expect(output.error).toBe("InvalidGatewaySseEvent");
        expect(output.tool_calls).toEqual([]);
      } else {
        expect(first.code, first.stdout + first.stderr).toBe(0);
        expect(first.stderr).toBe("");
        expect(output.output).toBe(prefix + answer);
        const detail = await runFx(["session", "--json", "--id", output.session_id], { cwd: profile, env });
        expect(detail.code).toBe(0);
        expect(JSON.parse(detail.stdout).history[0].assistant).toBe(prefix + answer);
        const resumed = await runFx(["ask", "--json", "--auto", "--resume", output.session_id, "Recall the prior answer."], { cwd: profile, env, timeoutMs: TIMEOUT });
        expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
        expect(resumed.stderr).toBe("");
        expect(gateway.requests.length).toBe(2);
        const replay = gateway.requests[1].body;
        expect(replay).toContain(JSON.stringify(prefix + answer));
      }
    } finally {
      gateway.stop();
      rmSync(profile, { recursive: true, force: true });
    }
  }
}, 60_000);

test("provider context accounting is independent of image encoding size", async () => {
  const encodings = equivalentPngEncodings();
  const estimates: number[] = [];
  for (const bytes of encodings) {
    const profile = mkdtempSync(join(tmpdir(), "fx-image-context-"));
    const model = "fixture/image";
    const gateway = startFakeGateway([fakeGatewayFinalText("IMAGE_CONTEXT_OK")], {
      models: [{ id: model, type: "language", tags: ["vision", "file-input", "tool-use"], context_window: 1_000_000 }],
    });
    try {
      mkdirSync(join(profile, ".fx"), { recursive: true });
      writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider: "gateway", models: { gateway: model } }), { mode: 0o600 });
      const path = join(profile, "image.png"), trace = join(profile, "trace.log");
      writeFileSync(path, bytes);
      const result = await runFx(["ask", "--json", "--auto", "--no-save", "--image", path, "Describe the attached image."], {
        cwd: profile, timeoutMs: TIMEOUT,
        env: {
          HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined,
          FX_MODEL: model, FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TEST_GATEWAY_MODELS_URL: gateway.baseUrl + "/coding-agent/v1/models",
          FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "context_compaction",
        },
      });
      expect(result.code, result.stdout + result.stderr).toBe(0);
      expect(result.signal).toBeNull();
      expect(result.stderr).toBe("");
      expect(JSON.parse(result.stdout).output).toBe("IMAGE_CONTEXT_OK");
      const bodies = gateway.requests;
      expect(bodies).toHaveLength(1);
      const request = JSON.parse(bodies[0].body);
      const parts = (request.input ?? request.prompt).flatMap((message: { content: unknown }) => Array.isArray(message.content) ? message.content : []);
      const image = parts.find((part: { type?: string }) => part.type === "file");
      expect(image).toBeDefined();
      expect(image.data.data).toBe(bytes.toString("base64"));
      const decision = readFileSync(trace, "utf8");
      expect(decision).toContain("decision=no_op");
      expect(decision).toContain("has_images=true image_baseline=false");
      estimates.push(Number(decision.match(/estimated_tokens=(\d+)/)![1]));
    } finally {
      gateway.stop();
      rmSync(profile, { recursive: true, force: true });
    }
  }
  expect(estimates[0]).toBe(estimates[1]);
}, 60_000);

test(
  "fx login bounds invalid OAuth client fallback to two device requests",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-login-client-fallback-failure-"));
    writeSeededFxLogin(home);
    const authPath = join(home, ".fx", "auth.json");
    const seededAuthFile = readFileSync(authPath, "utf8");
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { deviceError: "invalid_client", rejectAllDeviceClients: true },
    );

    const result = await runFx(["login"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_NO_OPEN_BROWSER: "1",
        FX_OAUTH_CLIENT_ID: "test-client",
        FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
      },
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(1);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/device",
      "POST /oauth/device",
    ]);
    const deviceRequests = oauth.requests.filter(
      (request) => request.path === "/oauth/device",
    );
    expect(deviceRequests).toHaveLength(2);
    expect(deviceRequests[0].clientId).toBe("test-client");
    expect(deviceRequests[1].clientId).toBeDefined();
    expect(deviceRequests[1].clientId).not.toBe("test-client");
    expect(result.stdout).toBe("");
    expect(result.stderr).toBe("fx login: failed to sign in\n");
    expect(result.stderr).not.toContain(oauth.providerDetail);
    expect(readFileSync(authPath, "utf8")).toBe(seededAuthFile);
  },
  60_000,
);

test(
  "fx login does not fall back for another OAuth device error",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-login-client-no-fallback-"));
    writeSeededFxLogin(home);
    const authPath = join(home, ".fx", "auth.json");
    const seededAuthFile = readFileSync(authPath, "utf8");
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { deviceError: "invalid_request" },
    );

    const result = await runFx(["login"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_NO_OPEN_BROWSER: "1",
        FX_OAUTH_CLIENT_ID: "test-client",
        FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
      },
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(1);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/device",
    ]);
    const deviceRequests = oauth.requests.filter(
      (request) => request.path === "/oauth/device",
    );
    expect(deviceRequests).toHaveLength(1);
    expect(deviceRequests[0].clientId).toBe("test-client");
    expect(result.stdout).toBe("");
    expect(result.stderr).toBe("fx login: failed to sign in\n");
    expect(result.stderr).not.toContain(oauth.providerDetail);
    expect(readFileSync(authPath, "utf8")).toBe(seededAuthFile);
  },
  60_000,
);

tmuxTest(
  "missing auth after deferred onboarding preserves the complete prompt",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-preflight-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    const imagePath = join(home, "attachment.png");
    writeFileSync(imagePath, Buffer.from("89504e470d0a1a0a72657374", "hex"));
    gateway = startFakeGateway([], {
      models: [{
        id: FAKE_GATEWAY_MODEL,
        tags: ["vision", "file-input", "tool-use"],
      }],
    });

    session = await startFxWithoutAuth(home, stderrPath, gateway);
    const initial = await session.waitForComposer(TIMEOUT);
    expect(initial).not.toContain("Sign in with Vercel");
    expect(initial).not.toContain("Switch credential");

    await session.sendText(`/image ${imagePath}`);
    await session.waitForText("attached image: attachment.png", TIMEOUT);
    await session.sendText(" preserve this exact prompt");
    const blocked = await session.waitForPane(
      (pane) =>
        pane.includes("fx needs access to Vercel AI Gateway") &&
        pane.includes("preserve this exact prompt") &&
        pane.includes("Image 1"),
      TIMEOUT,
    );
    expect(blocked).not.toContain("Welcome to fx");
    expect(blocked).not.toContain("Switch credential");
    expect(gateway.requests).toHaveLength(0);
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "logout rejects an invalid revocation endpoint and removes the active login",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-active-login-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    const tapePath = join(home, "logout.fxtape");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([
      fakeGatewayFinalText(LOGIN_RESPONSE),
      fakeGatewayFinalText(ENV_RESPONSE),
    ]);
    catcher = startRequestCatcher();
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, catcher.endpoint);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath, {
      FX_RECORD: tapePath,
      FX_RECORD_INPUT: "1",
    });
    await session.waitForComposer(TIMEOUT);
    await selectFxLoginCredential(session);
    await session.sendText("prove fx login is active before logout");
    await session.waitForText(LOGIN_RESPONSE, TIMEOUT);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);

    await session.sendText("/logout");
    const loggedOut = await session.waitForPane(
      (pane) =>
        pane.includes("Signed out of fx.") &&
        pane.includes("remote session could not be revoked"),
      TIMEOUT,
    );
    expect(loggedOut).not.toContain(oauth.providerDetail);
    expect(
      loggedOut.match(/remote session could not be revoked/g) ?? [],
    ).toHaveLength(1);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);

    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");

    await session.sendText("prove environment auth remains active");
    await session.waitForText(ENV_RESPONSE, TIMEOUT);
    expect(gateway.requests[1].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    // The invalid revocation endpoint must never be called, and logout must
    // not attempt a token refresh on its way out.
    expect(oauth.requests.filter((request) => request.path === "/oauth/token")).toEqual([]);
    expect(oauth.requests.filter((request) => request.path === "/oauth/revoke")).toEqual([]);
    expect(catcher.requests).toEqual([]);

    const pane = await session.capturePane();
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    session = null;
    expect(existsSync(tracePath)).toBe(true);
    expect(existsSync(tapePath)).toBe(true);
    const trace = readFileSync(tracePath, "utf8");
    const tape = readFileSync(tapePath);
    for (const secret of [
      LOGIN_TOKEN,
      ENV_TOKEN,
      "seeded-refresh-token",
      oauth.providerDetail,
    ]) {
      expect(pane).not.toContain(secret);
      expect(readFileSync(stderrPath, "utf8")).not.toContain(secret);
      expect(trace).not.toContain(secret);
      expect(tape.includes(Buffer.from(secret))).toBe(false);
    }
  },
  60_000,
);

function completedRevocations(fakeOAuth: ReturnType<typeof startFakeOAuth>) {
  return fakeOAuth.requests
    .filter((request) => request.path === "/oauth/revoke" && request.revocation)
    .map((request) => request.revocation);
}

async function waitForRevocations(
  fakeOAuth: ReturnType<typeof startFakeOAuth>,
  count: number,
): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  while (completedRevocations(fakeOAuth).length < count) {
    if (Date.now() > deadline) {
      throw new Error(`Timed out waiting for ${count} token revocations; saw ${completedRevocations(fakeOAuth).length}`);
    }
    await Bun.sleep(25);
  }
}

tmuxTest(
  "quitting right after /logout does not wait on a stalled issuer",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-quit-stalled-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    // Longer than the OAuth request deadline, so only cancellation ends it.
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Infinity, { revokeDelayMs: 20_000 });
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/logout");
    await session.waitForText("Signed out of fx.", 1_000);

    const quitAt = Date.now();
    await session.sendText("/quit");
    expect(await session.waitForSessionEnd(10_000)).toBe(true);
    session = null;
    // Shutdown gives the revocation 2 seconds, then cancels it.
    expect(Date.now() - quitAt).toBeLessThan(5_000);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "logout signs out at once while the issuer revokes the session slowly",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-slow-revoke-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    // Revoking inline would hold the terminal for both of these delays.
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Infinity, { revokeDelayMs: 3_000 });
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/logout");
    await session.waitForText("Signed out of fx.", 1_000);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
    const draft = "TYPING_WHILE_LOGOUT_REVOKES";
    await session.sendLiteral(draft);
    await session.waitForPane((pane) => pane.includes(draft), 1_000);
    await session.sendKeys("C-u");
    await session.sendKeys("C-k");

    await waitForRevocations(oauth, 2);
    expect(completedRevocations(oauth)).toEqual([
      { tokenTypeHint: "refresh_token", validForm: true },
      { tokenTypeHint: "access_token", validForm: true },
    ]);
    expect(await session.captureFullScrollback()).not.toContain("remote session could not be revoked");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "logout preserves an active API key when fx login is inactive",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-inactive-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(ENV_RESPONSE)]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/logout");
    await session.waitForText("Signed out of fx.", TIMEOUT);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);

    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");
    await session.sendText("prove the active API key was unchanged");
    await session.waitForText(ENV_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "logout removes an fx login rejected for unsafe permissions",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-rejected-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);
    const authPath = join(home, ".fx", "auth.json");
    chmodSync(authPath, 0o644);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/logout");
    const loggedOut = await session.waitForText("Signed out of fx.", TIMEOUT);
    expect(existsSync(authPath)).toBe(false);

    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "AI_GATEWAY_API_KEY");
    expect(oauth.requests).toEqual([]);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    for (const secret of [
      LOGIN_TOKEN,
      "seeded-refresh-token",
      oauth.providerDetail,
    ]) {
      expect(loggedOut).not.toContain(secret);
    }
  },
  60_000,
);

tmuxTest(
  "logout recalculates auth when local cleanup cannot be completed",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-delete-failure-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(LOGIN_RESPONSE)]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);
    const fxDir = join(home, ".fx");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    const authPath = join(fxDir, "auth.json");
    rmSync(authPath);
    mkdirSync(authPath, { mode: 0o700 });

    await session.sendText("/logout");
    const failed = await session.waitForText(
      "Could not confirm durable fx logout. The active source was recalculated.",
      TIMEOUT,
    );
    expect(failed).not.toContain("Signed out of fx.");
    expect(failed).toContain(
      "Warning: signed out locally, but the remote session could not be revoked.",
    );
    expect(existsSync(authPath)).toBe(true);

    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "missing");
    expect(gateway.requests).toHaveLength(0);
    expect(oauth.requests).toEqual([]);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "logout with the only credential keeps the shell open and reopens onboarding on the next prompt",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-only-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
      FX_TEST_SKIP_ONBOARDING: "1",
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/logout");
    await session.waitForText("Signed out of fx.", TIMEOUT);
    await readStatusPanel(session, TIMEOUT, (panel) => panelAuth(panel) === "missing");

    await session.sendText("/setup");
    const picker = await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    expect(picker).not.toContain("Connections");
    await session.sendKeys("Escape");
    await session.waitForPane((pane) => !pane.includes("vercel"), TIMEOUT);
    await session.sendKeys("C-u");

    const prompt = "prompt waits for auth after logout";
    await session.sendText(prompt);
    const onboarding = await session.waitForPane(
      (pane) =>
        pane.includes(prompt) &&
        pane.includes("Welcome to fx") &&
        pane.includes("Sign in with Vercel") &&
        pane.includes("Add an API key") &&
        pane.includes("esc to set up later"),
      TIMEOUT,
    );
    expect(onboarding).not.toMatch(/^\s+fx login\s+/m);
    expect(onboarding).not.toContain("Switch credential");
    expect(onboarding).not.toContain("Skip for now");
    expect(gateway.requests).toHaveLength(0);
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "HTTP auth failure names the selected source and suppresses provider detail",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-http-failure-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    const providerDetail = `rejected ${ENV_TOKEN} in provider response`;
    gateway = startFakeGateway([
      new Response(JSON.stringify({ error: { message: providerDetail } }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
    ]);

    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("exercise interactive auth failure");
    const failed = await session.waitForPane(
      (pane) =>
        pane.includes("AI_GATEWAY_API_KEY authentication failed · HTTP 401") &&
        pane.includes("Run /provider to repair this source."),
      TIMEOUT,
    );

    expect(failed).not.toContain(ENV_TOKEN);
    expect(failed).not.toContain(providerDetail);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

tmuxTest(
  "manual compaction refreshes the selected login without losing the draft",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-compact-auth-refresh-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    // The first turn reads a file, so compaction has work to summarize and
    // asks the model with the refreshed login.
    writeFileSync(join(home, "compact-auth-notes.txt"), "notes\n");
    gateway = startFakeGateway([
      fakeGatewayToolCall("compact-auth-read", "read_file", { path: "compact-auth-notes.txt" }),
      fakeGatewayFinalText("COMPACT_AUTH_FIRST_REPLY"),
      fakeGatewayFinalText("COMPACT_AUTH_SECOND_REPLY"),
      fakeGatewayFinalText("The conversation established COMPACT_AUTH_FIRST and COMPACT_AUTH_SECOND."),
      fakeGatewayFinalText("COMPACT_AUTH_CONTINUED"),
    ]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, { tokenDelayMs: 2_000 });
    const expiresAt = Date.now() + 80_000;
    writeSeededFxLogin(home, expiresAt, oauth.issuerUrl, "team_123");
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath, {
      AI_GATEWAY_API_KEY: undefined,
      FX_TRACE_SCOPES: "auth,input,worker,context_compaction,session",
    }, home);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Remember COMPACT_AUTH_FIRST.");
    await session.waitForText("COMPACT_AUTH_FIRST_REPLY", TIMEOUT);
    await session.sendText("Remember COMPACT_AUTH_SECOND.");
    await session.waitForText("COMPACT_AUTH_SECOND_REPLY", TIMEOUT);
    expect(gateway.requests).toHaveLength(3);
    expect(oauth.requests.filter((request) => request.path === "/oauth/token")).toHaveLength(0);
    await Bun.sleep(Math.max(0, expiresAt - 60_000 + 100 - Date.now()));
    await readStatusPanel(session, TIMEOUT, (panel) => panel.fields.Auth?.split(" · ").includes("expired") === true);
    const sessionIds = rootSessionIds(home);
    expect(sessionIds).toHaveLength(1);
    const historyPath = join(sessionDir(home, sessionIds[0]!), "log.jsonl");
    const before = readFileSync(historyPath, "utf8");
    await session.sendText("/compact");
    await waitForTrace(tracePath, "manual_compaction_auth_pending", TIMEOUT);
    expect(gateway.requests).toHaveLength(3);
    await session.sendText("/compact");
    await session.sendLiteral("PRESERVE_COMPACTION_DRAFT");
    await session.waitForText("PRESERVE_COMPACTION_DRAFT", 1_000);
    // Success is silent; wait for durable publication and the activity row to clear.
    await session.waitForPane((pane) =>
      pane.includes("PRESERVE_COMPACTION_DRAFT") &&
      !/Preparing compaction|Compacting|Stopping compaction/.test(pane) &&
      readFileSync(historyPath, "utf8").includes('"kind":"compacted"'),
    TIMEOUT);
    const scrollback = await session.captureFullScrollback();
    expect(scrollback).toContain("PRESERVE_COMPACTION_DRAFT");
    expect(scrollback).not.toContain("Context compacted.");
    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);
    expect(gateway.requests).toHaveLength(4);
    expect(gateway.requests[3].headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
    expect(JSON.parse(gateway.requests[3].body).tools ?? []).toHaveLength(0);
    expect(readFileSync(historyPath, "utf8").startsWith(before)).toBe(true);
    const records = readFileSync(historyPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
    expect(records.filter((record) => record.kind === "compacted")).toHaveLength(1);
    await session.sendKeys("C-u");
    await session.sendText("Continue after the manual compaction.");
    await session.waitForText("COMPACT_AUTH_CONTINUED", TIMEOUT);
    expect(gateway.requests).toHaveLength(5);
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    const trace = readFileSync(tracePath, "utf8");
    for (const secret of [LOGIN_TOKEN, ACQUIRED_LOGIN_TOKEN, "seeded-refresh-token", "acquired-refresh-token"]) expect(trace).not.toContain(secret);
  },
  90_000,
);

for (const outcome of ["failure", "cancel"] as const) {
  tmuxTest(`manual compaction auth ${outcome} preserves the session and accepts a later prompt`, async () => {
    home = mkdtempSync(join(tmpdir(), `fx-compact-auth-${outcome}-`));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([
      fakeGatewayFinalText("AUTH_BOUNDARY_FIRST_REPLY"),
      fakeGatewayFinalText("AUTH_BOUNDARY_SECOND_REPLY"),
      fakeGatewayFinalText("AUTH_BOUNDARY_RECOVERED"),
    ]);
    oauth = startFakeOAuth(outcome === "failure" ? null : ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      tokenDelayMs: outcome === "cancel" ? 10_000 : 1_000,
    });
    const expiresAt = Date.now() + 80_000;
    writeSeededFxLogin(home, expiresAt, oauth.issuerUrl, "team_123");
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ credential_source: "fx_login" }));
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath, {
      FX_TRACE_SCOPES: "auth,input,worker,context_compaction,session",
    }, home);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Remember AUTH_BOUNDARY_FIRST.");
    await session.waitForText("AUTH_BOUNDARY_FIRST_REPLY", TIMEOUT);
    await session.sendText("Remember AUTH_BOUNDARY_SECOND.");
    await session.waitForText("AUTH_BOUNDARY_SECOND_REPLY", TIMEOUT);
    const sessionIds = rootSessionIds(home);
    expect(sessionIds).toHaveLength(1);
    const historyPath = join(sessionDir(home, sessionIds[0]!), "log.jsonl");
    const before = readFileSync(historyPath, "utf8");
    expect(gateway.requests).toHaveLength(2);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
    expect(oauth.requests.filter((request) => request.path === "/oauth/token")).toHaveLength(0);
    await Bun.sleep(Math.max(0, expiresAt - 60_000 + 100 - Date.now()));
    await session.sendText("/compact");
    await waitForTrace(tracePath, "manual_compaction_auth_pending", TIMEOUT);
    await session.sendLiteral("DRAFT_DURING_AUTH_BOUNDARY");
    await session.waitForText("DRAFT_DURING_AUTH_BOUNDARY", 1_000);
    if (outcome === "cancel") {
      await session.sendKeys("C-c");
      await session.waitForText("Compaction cancelled. Try /compact again when ready.", 3_000);
    } else {
      await session.waitForText("Compaction was not started. Check authentication and try /compact again.", TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("/compact again");
      expect(scrollback).not.toContain("Your prompt is saved.");
    }
    expect(await session.captureFullScrollback()).toContain("DRAFT_DURING_AUTH_BOUNDARY");
    expect(readFileSync(historyPath, "utf8")).toBe(before);
    expect(gateway.requests).toHaveLength(2);
    await session.sendKeys("C-u");
    await selectEnvKeyCredential(session);
    expect(gateway.requests).toHaveLength(2);
    await session.sendText("Continue the original conversation without tools.");
    await session.waitForText("AUTH_BOUNDARY_RECOVERED", TIMEOUT);
    expect(gateway.requests).toHaveLength(3);
    expect(gateway.requests[2].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(historyPath, "utf8")).not.toContain('"kind":"compacted"');
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    const trace = readFileSync(tracePath, "utf8");
    expect(trace).not.toContain("context_compaction_enqueue");
    for (const secret of [LOGIN_TOKEN, ACQUIRED_LOGIN_TOKEN, ENV_TOKEN, "seeded-refresh-token", "acquired-refresh-token"]) expect(trace).not.toContain(secret);
  }, 90_000);
}

tmuxTest(
  "expired selected login preserves the prompt and avoids Gateway before explicit recovery",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-source-failure-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(REFRESH_RECOVERY_RESPONSE)]);
    oauth = startFakeOAuth(null);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath);
    await session.waitForComposer(TIMEOUT);
    await selectFxLoginCredential(session);
    const oauthBaseline = oauth.requests.length;
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    const promptHead = "PRESERVE_CURSOR_";
    const promptTail = "AFTER_SELECTED_LOGIN_REFRESH_FAILURE";
    await session.sendLiteral(`${promptHead}${promptTail}`);
    for (let index = 0; index < promptTail.length; index += 1) {
      await session.sendKeys("Left");
    }
    await session.sendKeys("Enter");
    const failed = await session.waitForPane(
      (pane) =>
        pane.includes("fx login sign-in expired.") &&
        pane.includes("press enter to sign in again.") &&
        !pane.includes("Setup"),
      TIMEOUT,
    );
    expect(failed).toContain(`${promptHead}${promptTail}`);
    expect(failed).not.toContain(LOGIN_TOKEN);
    expect(failed).not.toContain(ENV_TOKEN);
    expect(gateway.requests).toHaveLength(0);
    expect(
      oauth.requests.slice(oauthBaseline).map((request) => `${request.method} ${request.path}`),
    ).toEqual(["GET /.well-known/openid-configuration", "POST /oauth/token"]);

    await session.sendKeys("C-u");
    await session.sendKeys("C-k");
    await selectEnvKeyCredential(session);
    await session.waitForText(REFRESH_RECOVERY_RESPONSE, TIMEOUT);

    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(gateway.requests[0].body).toContain(`${promptHead}${promptTail}`);

    const trace = readFileSync(tracePath, "utf8");
    for (const secret of [LOGIN_TOKEN, ENV_TOKEN, "seeded-refresh-token", "invalid_grant", "rejected"]) {
      expect(trace).not.toContain(secret);
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "permanent fx login failure enters repair without retrying or losing the prompt",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-repair-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    const tapePath = join(home, "pending-activity.fxtape");
    const replayPath = join(home, "pending-activity-replay");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(REFRESH_RECOVERY_RESPONSE)]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      rejectRefreshGrant: true,
      tokenDelayMs: 5_000,
      teams: [{ id: "team_123", slug: "team-harness", name: "Team Harness" }],
    });
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath, {
      AI_GATEWAY_API_KEY: undefined,
      FX_TRACE_SCOPES: "auth,input",
      FX_RECORD: tapePath,
      FX_RECORD_INPUT: "1",
    });
    await session.waitForComposer(TIMEOUT);
    await waitForTrace(tracePath, "prompt credential prewarm start outcome=started", 1_000);
    const prompt = "PRESERVE_DURING_LOGIN_REPAIR";
    await session.sendText(prompt);
    await waitForTrace(tracePath, "event=pending_prompt_frame_committed", 1_000);
    await session.waitForPane(
      (pane) => pane.includes(prompt) && pane.includes("Thinking"),
      1_000,
    );
    const responsiveDraft = "TERMINAL_RESPONSIVE_DURING_CREDENTIAL_REFRESH";
    await session.sendLiteral(responsiveDraft);
    await session.waitForPane(
      (pane) => pane.includes(responsiveDraft),
      1_000,
    );
    await session.sendKeys("C-u");
    await session.sendKeys("C-k");
    await session.waitForPane(
      (pane) => pane.includes("fx login sign-in expired.") && !pane.includes("Thinking"),
      TIMEOUT,
    );
    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);

    const frames = readTapeFrames(tapePath);
    const promptInput = frames.findIndex((frame) => frame.kind === 2 && frame.payload.includes(prompt));
    expect(promptInput).toBeGreaterThanOrEqual(0);
    const enter = frames.findIndex((frame, index) =>
      index > promptInput && frame.kind === 2 && frame.payload.equals(Buffer.from("\r"))
    );
    expect(enter).toBeGreaterThan(promptInput);
    const firstOutput = frames.slice(enter + 1).find((frame) => frame.kind === 1);
    expect(firstOutput).toBeDefined();
    expect(firstOutput!.payload.includes(prompt)).toBe(true);
    expect(firstOutput!.payload.includes("Thinking")).toBe(true);

    const replay = await runFx(["replay", tapePath, "--frames-dir", replayPath]);
    expect(replay.code).toBe(0);
    const grids = readdirSync(join(replayPath, "frames"))
      .filter((name) => name.endsWith(".grid.txt"))
      .sort()
      .map((name) => readFileSync(join(replayPath, "frames", name), "utf8"));
    const thinkingGrids = grids.filter((grid) => grid.includes("Thinking"));
    expect(thinkingGrids.length).toBeGreaterThan(0);
    for (const grid of thinkingGrids) {
      const rows = grid.split("\n");
      const promptRow = rows.findIndex((row) => row.includes(prompt));
      expect(promptRow).toBeGreaterThanOrEqual(0);
      expect(rows.findIndex((row) => row.includes("Thinking"))).toBe(promptRow + 2);
    }

    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);
    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);

    await session.waitForText("Team Harness", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText(REFRESH_RECOVERY_RESPONSE, TIMEOUT);
    const full = await session.captureFullScrollback();
    expect(full.match(/fx login sign-in expired\./g)).toHaveLength(1);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0]!.body).toContain(prompt);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "cancelled fx login repair allows a later explicit login",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-cancelled-repair-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(REFRESH_RECOVERY_RESPONSE)]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      rejectRefreshGrant: true,
      tokenDelayMs: 5_000,
      teams: [{ id: "team_123", slug: "team-harness", name: "Team Harness" }],
    });
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    const prompt = "DO_NOT_REPLAY_AFTER_CANCELLED_REPAIR";
    await session.sendText(prompt);
    await session.waitForText("fx login sign-in expired.", TIMEOUT);
    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);

    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);
    expect(oauth.requests.filter((request) => request.path === "/oauth/device")).toHaveLength(1);
    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => pane.includes(prompt) && !pane.includes("Waiting for authorization"),
      TIMEOUT,
    );
    await session.sendKeys("C-u");
    await session.sendKeys("C-k");
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);

    expect(oauth.requests.filter((request) => request.path === "/oauth/device")).toHaveLength(2);
    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);
    await session.waitForText("Team Harness", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Changed Vercel team to Team Harness", TIMEOUT);
    expect(gateway.requests).toHaveLength(0);

    await session.sendText("use the repaired fx login");
    await session.waitForText(REFRESH_RECOVERY_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0]!.headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );
    expect(gateway.requests[0]!.body).not.toContain(prompt);
    expect(savedCredentialSource(home)).toBe("fx_login");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "refresh save failure retires the session and starts a fresh sign-in",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-refresh-save-failure-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    const authPath = join(home, ".fx", "auth.json");
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      tokenDelayMs: 5_000,
      beforeRefreshResponse() {
        chmodSync(authPath, 0o400);
      },
    });
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);

    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);
    expect(oauth.requests.filter((request) => request.path === "/oauth/device")).toHaveLength(1);
    expect(existsSync(authPath)).toBe(false);
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "a rejected saved session is retired before a later explicit login",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-rejected-session-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(REFRESH_RECOVERY_RESPONSE)]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      rejectRefreshGrant: true,
      tokenDelayMs: 5_000,
      teams: [{ id: "team_123", slug: "team-harness", name: "Team Harness" }],
    });
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);

    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);
    expect(oauth.requests.filter((request) => request.path === "/oauth/device")).toHaveLength(1);
    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => !pane.includes("Waiting for authorization"),
      TIMEOUT,
    );
    await session.sendKeys("C-u");
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);

    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);
    expect(oauth.requests.filter((request) => request.path === "/oauth/device")).toHaveLength(2);
    await session.waitForText("Team Harness", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Changed Vercel team to Team Harness", TIMEOUT);
    expect(savedCredentialSource(home)).toBe("fx_login");

    await session.sendText("use the repaired login after retiring the rejected token");
    await session.waitForText(REFRESH_RECOVERY_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0]!.headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );
    expect(gateway.requests[0]!.headers.get("authorization")).not.toBe(
      `Bearer ${ENV_TOKEN}`,
    );
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "prompt refresh replaces an expired public catalog with the selected team catalog",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-refresh-team-models-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(REFRESH_RECOVERY_RESPONSE)], {
      models(request) {
        const teamId = new URL(request.url).searchParams.get("teamId");
        const authenticated =
          request.headers.get("authorization") === `Bearer ${ACQUIRED_LOGIN_TOKEN}` &&
          teamId === "team_123";
        return [
          { id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] },
          ...(authenticated
            ? [{ id: "private/blue-hornbill", type: "language", tags: ["tool-use"] }]
            : []),
        ];
      },
    });
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl, "team_123");

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      tracePath,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_TEST_GATEWAY_MODELS_URL: undefined,
        FX_TRACE_SCOPES: "auth,prompt,catalog",
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();

    await session.sendText("refresh login and answer");
    await session.waitForText(REFRESH_RECOVERY_RESPONSE, TIMEOUT);
    await waitForModelRequestCount(gateway, 2);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
    expect(gateway.requests[0].headers.get("x-vercel-ai-gateway-team")).toBe("team_123");

    await session.sendText("/model");
    await session.waitForPane(
      (pane) =>
        pane.includes("private/blue-hornbill") &&
        !pane.includes("Authenticated model catalog loaded."),
      TIMEOUT,
    );
    const refreshedCatalogRequest = gateway.modelRequests[1];
    expect(refreshedCatalogRequest.headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
    expect(refreshedCatalogRequest.headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(new URL(refreshedCatalogRequest.url).searchParams.get("teamId")).toBe("team_123");
    expect(gateway.modelRequests).toHaveLength(2);

    const trace = readFileSync(tracePath, "utf8");
    const catalogEvents = trace.split("\n").filter((line) =>
      line.includes("[catalog] event=model_catalog_load ")
    );
    expect(catalogEvents).toHaveLength(2);
    expect(catalogEvents[0]).toContain("public_only_reason=fx_login_refresh_required");
    expect(catalogEvents[1]).toContain(
      "requested_access=authenticated credential_source=fx_login effective_access=authenticated",
    );
    for (const secret of [
      LOGIN_TOKEN,
      ACQUIRED_LOGIN_TOKEN,
      "seeded-refresh-token",
      "acquired-refresh-token",
      "team_123",
      "example-internal-team",
    ]) {
      expect(trace).not.toContain(secret);
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "expired saved login prewarms credentials while model discovery stays anonymous",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-expired-models-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      undefined,
      { AI_GATEWAY_API_KEY: undefined },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    await waitForOAuthRequestCount(oauth, 2);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[0].headers.get("x-vercel-ai-gateway-team")).toBeNull();

    await session.sendText("/model");
    await session.waitForPane(
      (pane) =>
        pane.includes(FAKE_GATEWAY_MODEL) &&
        pane.includes("Vercel sign-in must refresh before team-private models can load.") &&
        pane.includes("esc close"),
      TIMEOUT,
    );

    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "ready team catalog downgrades after fx login expiry and refresh failure",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-ready-catalog-expiry-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([], {
      models(request) {
        const teamId = new URL(request.url).searchParams.get("teamId");
        const authenticated =
          request.headers.get("authorization") === `Bearer ${LOGIN_TOKEN}` &&
          teamId === "team_123";
        return [
          { id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] },
          ...(authenticated
            ? [{ id: "private/blue-hornbill", type: "language", tags: ["tool-use"] }]
            : []),
        ];
      },
    });
    oauth = startFakeOAuth(null);
    writeSeededFxLogin(home, Date.now() + 65_000, oauth.issuerUrl, "team_123");

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      tracePath,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_TEST_GATEWAY_MODELS_URL: undefined,
        FX_TRACE_SCOPES: "auth,prompt,catalog",
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
    expect(new URL(gateway.modelRequests[0].url).searchParams.get("teamId")).toBe("team_123");

    await Bun.sleep(6_000);
    await session.sendText("/model");
    await waitForModelRequestCount(gateway, 2);
    const expiredPane = await session.waitForPane(
      (pane) =>
        pane.includes(FAKE_GATEWAY_MODEL) &&
        pane.includes("Vercel sign-in must refresh before team-private models can load.") &&
        !pane.includes("private/blue-hornbill"),
      TIMEOUT,
    );
    expect(expiredPane).not.toContain("private/blue-hornbill");
    expect(gateway.modelRequests[1].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[1].headers.get("x-vercel-ai-gateway-team")).toBeNull();

    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => !pane.includes("Models ") && !pane.includes("esc close"),
      TIMEOUT,
    );
    await session.waitForComposer(TIMEOUT);
    const blockedPrompt = "refresh the expired team login";
    await session.sendText(blockedPrompt);
    await session.waitForPane(
      (pane) =>
        pane.includes(blockedPrompt) &&
        pane.includes("fx login sign-in expired.") &&
        pane.includes("press enter to sign in again.") &&
        !pane.includes("Model provider"),
      TIMEOUT,
    );
    expect(gateway.requests).toHaveLength(0);

    await session.sendKeys("C-u");
    await session.sendText("/model");
    const failedPane = await session.waitForPane(
      (pane) =>
        pane.includes(FAKE_GATEWAY_MODEL) &&
        pane.includes("Vercel sign-in refresh failed; using the public model catalog.") &&
        !pane.includes("private/blue-hornbill"),
      TIMEOUT,
    );
    expect(failedPane).not.toContain("private/blue-hornbill");
    expect(gateway.modelRequests).toHaveLength(2);

    const trace = readFileSync(tracePath, "utf8");
    const catalogEvents = trace.split("\n").filter((line) =>
      line.includes("[catalog] event=model_catalog_load ")
    );
    expect(catalogEvents).toHaveLength(2);
    expect(catalogEvents[0]).toContain(
      "requested_access=authenticated credential_source=fx_login effective_access=authenticated",
    );
    expect(catalogEvents[1]).toContain("public_only_reason=fx_login_refresh_required");
    for (const secret of [LOGIN_TOKEN, "seeded-refresh-token", "team_123"]) {
      expect(trace).not.toContain(secret);
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "an immediately expired prewarm retires the login and keeps model discovery anonymous",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-expired-refresh-models-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 0);
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      tracePath,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_TRACE_SCOPES: "auth,prompt,catalog",
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[0].headers.get("x-vercel-ai-gateway-team")).toBeNull();

    const firstPrompt = "prompt blocked by an immediately expired refresh";
    await session.sendText(firstPrompt);
    const firstFailure = await session.waitForPane(
      (pane) =>
        pane.includes(firstPrompt) &&
        pane.includes("fx login sign-in expired.") &&
        pane.includes("press enter to sign in again.") &&
        !pane.includes("Model provider"),
      TIMEOUT,
    );
    expect(firstFailure).not.toContain("Choose another source");
    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);

    await session.sendKeys("C-u");
    await session.sendText("/model");
    await session.waitForPane(
      (pane) =>
        pane.includes("Vercel sign-in refresh failed; using the public model catalog.") &&
        pane.includes("esc close"),
      TIMEOUT,
    );
    expect(gateway.modelRequests).toHaveLength(1);
    await session.sendKeys("Escape");
    await session.waitForPane((pane) => !pane.includes("esc close"), TIMEOUT);
    await session.waitForComposer(TIMEOUT);
    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(oauth.requests.every((request) => request.authorization === null)).toBe(true);

    const trace = readFileSync(tracePath, "utf8");
    const catalogEvents = trace.split("\n").filter((line) =>
      line.includes("[catalog] event=model_catalog_load ")
    );
    expect(catalogEvents).toHaveLength(1);
    expect(catalogEvents[0]).toContain(
      "requested_access=public_only credential_source=fx_login effective_access=public_only public_only_reason=fx_login_refresh_required anonymous_fallback=false outcome=loaded failure_category=none http_status=none retryable=none",
    );
    for (const secret of [
      LOGIN_TOKEN,
      ENV_TOKEN,
      ACQUIRED_LOGIN_TOKEN,
      "seeded-refresh-token",
      "acquired-refresh-token",
      oauth.providerDetail,
      "team_123",
      "vercel-labs",
    ]) {
      expect(trace).not.toContain(secret);
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "expired saved login refreshes credits and the selected team catalog",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-expired-credits-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    creditsGateway = startFakeCreditsGateway();
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl, "team_123");

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      undefined,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_TEST_GATEWAY_MODELS_URL: undefined,
        FX_TEST_GATEWAY_CREDITS_URL: creditsGateway.url,
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    await waitForOAuthRequestCount(oauth, 2);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(creditsGateway.requests).toEqual([]);

    await session.sendText("/credits");
    await session.waitForText("* credits: balance=42", TIMEOUT);

    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(creditsGateway.requests).toEqual([{
      method: "GET",
      path: "/v1/credits",
      authorization: `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    }]);
    await waitForModelRequestCount(gateway, 2);
    expect(gateway.modelRequests).toHaveLength(2);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[1].headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );
    expect(new URL(gateway.modelRequests[1].url).searchParams.get("teamId")).toBe("team_123");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "/credits renews a login that falls due without holding the terminal",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-credits-renewal-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    // A renewal on the input loop would hold the terminal this long.
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Infinity, { tokenDelayMs: 3_000 });
    creditsGateway = startFakeCreditsGateway();
    // fx renews an fx login one minute before it expires, so this one is
    // current at launch and falls due a few seconds later.
    const refreshDueAt = Date.now() + 5_000;
    writeSeededFxLogin(home, refreshDueAt + 60_000, oauth.issuerUrl, "team_123");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
      FX_TEST_GATEWAY_CREDITS_URL: creditsGateway.url,
    });
    await session.waitForComposer(TIMEOUT);
    await Bun.sleep(Math.max(0, refreshDueAt - Date.now()) + 250);

    await session.sendText("/credits");
    const draft = "TYPING_WHILE_CREDITS_RENEW";
    await session.sendLiteral(draft);
    await session.waitForPane((pane) => pane.includes(draft), 1_000);
    await session.sendKeys("C-u");
    await session.sendKeys("C-k");

    await session.waitForText("* credits: balance=42", TIMEOUT);
    expect(oauth.requests.filter((request) => request.path === "/oauth/token")).toHaveLength(1);
    expect(creditsGateway.requests).toEqual([{
      method: "GET",
      path: "/v1/credits",
      authorization: `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    }]);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "a team list larger than an OAuth response still opens the team picker",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-provider-large-team-list-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    // About 95 KiB of teams, past the 64 KiB OAuth response limit.
    const padding = Array.from({ length: 300 }, (_, n) => ({
      id: `team_pad_${n}`,
      slug: `padding-team-${n}`,
      name: `Padding team ${n} ` + "x".repeat(240),
    }));
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Infinity, {
      teams: [
        { id: "team_123", slug: "example-internal-team", name: "Example Internal Team" },
        ...padding,
      ],
    });
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      // The /provider team column lists teams by slug.
      (pane) => pane.includes("example-internal-team"),
      TIMEOUT,
    );
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "closing /provider while its team list loads drops the late list",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-provider-team-list-close-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Infinity, {
      teamsDelayMs: 3_000,
      teams: [{ id: "team_123", slug: "example-internal-team", name: "Example Internal Team" }],
    });
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath, {
      FX_TRACE_SCOPES: "auth,provider",
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("loading teams...", 1_000);

    await session.sendKeys("Escape");
    await session.waitForPane((pane) => !pane.includes("loading teams..."), 1_000);
    // Past the teams delay, the late list must not reopen a picker.
    await Bun.sleep(3_500);
    expect(await session.capturePane()).not.toContain("Vercel team · Search:");
    expect(oauth.requests.filter((request) => request.path === "/v2/teams")).toHaveLength(1);
    expect(readFileSync(tracePath, "utf8")).toContain("team list dropped reason=picker_moved");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "/credits with a login that needs a new sign-in says so",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-credits-renewal-rejected-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    // The issuer rejects every refresh grant.
    oauth = startFakeOAuth(null);
    creditsGateway = startFakeCreditsGateway();
    // Current at launch, so nothing renews it before /credits; due a few
    // seconds later.
    const refreshDueAt = Date.now() + 5_000;
    writeSeededFxLogin(home, refreshDueAt + 60_000, oauth.issuerUrl, "team_123");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
      FX_TEST_GATEWAY_CREDITS_URL: creditsGateway.url,
    });
    await session.waitForComposer(TIMEOUT);
    await Bun.sleep(Math.max(0, refreshDueAt - Date.now()) + 250);

    await session.sendText("/credits");
    await session.waitForText("Your sign-in has expired. Run /login, then check credits again.", TIMEOUT);
    expect(creditsGateway.requests).toEqual([]);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "expired login refresh failure keeps one anonymous catalog request and blocks credits",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-expired-startup-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(null);
    creditsGateway = startFakeCreditsGateway();
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      undefined,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_TEST_GATEWAY_CREDITS_URL: creditsGateway.url,
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    await waitForOAuthRequestCount(oauth, 2);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[0].headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(creditsGateway.requests).toEqual([]);

    await session.sendText("/credits");
    const failed = await session.waitForPane(
      (pane) =>
        pane.includes("fx login sign-in expired.") &&
        pane.includes("press enter to sign in again.") &&
        pane.includes("/credits"),
      TIMEOUT,
    );

    expect(failed).toContain("/credits");
    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(creditsGateway.requests).toHaveLength(0);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "model discovery remains available before login",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-models-before-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      undefined,
      { AI_GATEWAY_API_KEY: undefined },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);

    await session.sendText("/model");
    const pane = await session.waitForPane(
      (text) =>
        text.includes(FAKE_GATEWAY_MODEL) &&
        text.includes("Using the public model catalog; sign in or use an API key for team-private models."),
      TIMEOUT,
    );
    expect(pane).toContain(FAKE_GATEWAY_MODEL);
    expect(pane).toContain("Using the public model catalog; sign in or use an API key for team-private models.");

    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[0].headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(oauth.requests).toEqual([]);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "rejected catalog credential renders the degraded public fallback notice",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-populated-catalog-fallback-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([], {
      models(request) {
        if (request.headers.get("authorization")) {
          return new Response("rejected catalog credential", { status: 401 });
        }
        return [{ id: FAKE_GATEWAY_MODEL, tags: ["tool-use"] }];
      },
    });

    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 2);

    await session.sendText("/model");
    const pane = await session.waitForPane(
      (text) =>
        text.includes(FAKE_GATEWAY_MODEL) &&
        text.includes("Your Gateway credential was rejected; using the public model catalog."),
      TIMEOUT,
    );
    expect(pane).toContain(FAKE_GATEWAY_MODEL);
    expect(pane).toContain("Your Gateway credential was rejected; using the public model catalog.");

    expect(gateway.modelRequests).toHaveLength(2);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(gateway.modelRequests[1].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[1].headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

for (const scenario of [
  {
    name: "ordinary public empty catalog",
    authenticated: false,
    status: "Using the public model catalog; sign in or use an API key for team-private models.",
  },
  {
    name: "rejected credential empty fallback catalog",
    authenticated: true,
    status: "Your Gateway credential was rejected; using the public model catalog.",
  },
]) {
  tmuxTest(
    `empty model menu renders the ${scenario.name} status`,
    async () => {
      home = mkdtempSync(join(tmpdir(), "fx-tui-auth-empty-catalog-"));
      stderrPath = join(home, "stderr.log");
      writeFileSync(stderrPath, "");
      gateway = startFakeGateway([], {
        models(request) {
          if (scenario.authenticated && request.headers.get("authorization")) {
            return new Response("rejected catalog credential", { status: 401 });
          }
          return [];
        },
      });

      session = await startFx(
        home,
        stderrPath,
        gateway,
        undefined,
        undefined,
        scenario.authenticated ? {} : { AI_GATEWAY_API_KEY: undefined },
      );
      await session.waitForComposer(TIMEOUT);
      await waitForModelRequestCount(gateway, scenario.authenticated ? 2 : 1);

      await session.sendText("/model");
      const pane = await session.waitForPane(
        (text) => text.includes("No models available.") && text.includes(scenario.status),
        TIMEOUT,
      );
      expect(pane).toContain("No models available.");
      expect(pane).toContain(scenario.status);

      expect(gateway.modelRequests).toHaveLength(scenario.authenticated ? 2 : 1);
      if (scenario.authenticated) {
        expect(gateway.modelRequests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
      }
      const publicRequest = gateway.modelRequests.at(-1)!;
      expect(publicRequest.headers.get("authorization")).toBeNull();
      expect(publicRequest.headers.get("x-vercel-ai-gateway-team")).toBeNull();
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    60_000,
  );
}

for (const outcome of ["cancel", "failure"] as const) {
  tmuxTest(`provider preparation validates Vercel team before saving through ${outcome}`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-team-preparation-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    let entered = 0;
    let release!: () => void;
    const held = new Promise<void>((resolve) => { release = resolve; });
    gateway = startFakeGateway([fakeGatewayFinalText("TEAM_PREPARATION_OK")], { models: async () => {
      entered++;
      if (entered === 1) {
        await held;
        if (outcome === "failure") return new Response("unavailable", { status: 503 });
      }
      return [FAKE_GATEWAY_MODEL, "openai/gpt-5.6-sol"].map((id) => ({ id, type: "language", tags: ["tool-use"] }));
    } });
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      teams: [{ id: "team_next", slug: "next-team", name: "Next Team" }],
    });
    writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_previous");
    const settingsPath = join(home, ".fx", "settings.json");
    const authPath = join(home, ".fx", "auth.json");
    writeFileSync(settingsPath, JSON.stringify({
      provider: "local",
      providers: { local: { protocol: "openai-chat-completions", base_url: "http://127.0.0.1:1/v1", auth: { type: "none" }, model_metadata: { "local-model": { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } } } },
      models: { local: "local-model", gateway: FAKE_GATEWAY_MODEL },
    }));
    const beforeAuth = readFileSync(authPath, "utf8");
    try {
      session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, { FX_MODEL: undefined, FX_SOUND: "0" });
      await session.waitForComposer(TIMEOUT);
      const chooseTeam = async () => {
        await session!.sendKeys("C-u");
        await openProviderPicker(session!);
        await session!.sendLiteral("vercel");
        await session!.sendKeys("Enter");
        await session!.waitForText("oauth", TIMEOUT);
        await session!.sendKeys("Enter");
        await session!.waitForText("next-team", TIMEOUT);
        await session!.sendKeys("Enter");
      };
      await chooseTeam();
      await session.waitForPane(() => entered === 1, 5000);
      await session.sendLiteral("team draft");
      await session.waitForText("team draft", 1500);
      expect(readFileSync(authPath, "utf8")).toBe(beforeAuth);
      if (outcome === "cancel") {
        await session.sendKeys("C-c");
        await session.waitForText("Provider preparation cancelled.", 1500);
        release();
      } else {
        release();
        await session.waitForText("could not be validated for AI Gateway", TIMEOUT);
      }
      expect(readFileSync(authPath, "utf8")).toBe(beforeAuth);
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).provider).toBe("local");
      await chooseTeam();
      await session.waitForText("Changed Vercel team to Next Team", TIMEOUT);
      expect(JSON.parse(readFileSync(authPath, "utf8")).team_id).toBe("team_next");
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).provider).toBe("gateway");
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).models.gateway).toBe(FAKE_GATEWAY_MODEL);
      await session.sendText("Use the validated team.");
      await session.waitForText("TEAM_PREPARATION_OK", TIMEOUT);
      expect(gateway.requests).toHaveLength(1);
      expect(gateway.requests[0]!.headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      await session.captureFullScrollbackEscapes();
      await session.sendText("/quit");
      await session.waitForSessionEnd(3000);
      session = null;
    } finally { release(); }
  }, TIMEOUT);
}
