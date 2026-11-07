import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

// TUI cancel-disposition coverage for a long-running tool submission.
//
// The codemode sandbox (src/tools/codemode/sandbox.zig) joins the same
// worker-cancel path this file exercises: the worker's cancel atomic is
// set, the in-flight work unwinds, the partial result is discarded, and fx
// returns to a responsive composer with a truthful cancelled status. The
// deterministic driver here is a prepared script that loops forever, so
// the scenario does not depend on the codemode tool bridge.

const SKIP = !tmuxAvailable();
const TIMEOUT = 30_000;
const FOLLOW_UP_TEXT = "CODEMODE_CANCEL_FOLLOW_UP_COMPLETE";

let session: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let root: string | null = null;

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  gateway?.stop();
  gateway = null;
  if (root) {
    rmSync(root, { recursive: true, force: true });
    root = null;
  }
});

async function waitForCondition(predicate: () => boolean, description: string): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < TIMEOUT) {
    if (predicate()) return;
    await Bun.sleep(50);
  }
  throw new Error("Timed out waiting for " + description + ".");
}

describe.skipIf(SKIP)("tui: codemode cancel", () => {
  test(
    "Escape cancels an endless script and fx returns to a responsive composer",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-codemode-cancel-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      const workspaceRoot = realpathSync(workspace);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission_mode: "auto",
          permission: {},
        }) + "\n",
      );
      const readyPath = join(workspaceRoot, ".codemode-cancel-ready");
      const scriptPath = join(workspaceRoot, "hold-codemode-cancel.sh");
      writeFileSync(
        scriptPath,
        "#!/bin/sh\n" +
          ": > .codemode-cancel-ready\n" +
          "while :; do sleep 1; done\n",
      );
      chmodSync(scriptPath, 0o755);
      gateway = startFakeGateway([
        fakeShellRun("codemode-cancel-hold", "./hold-codemode-cancel.sh", {
          timeout_ms: 600_000,
        }),
        fakeGatewayFinalText(FOLLOW_UP_TEXT),
      ]);
      session = await TmuxSession.create({
        cwd: workspaceRoot,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-codemode-cancel-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
        },
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the prepared endless script.");

      // The script is mid-flight once its ready marker lands.
      await waitForCondition(() => existsSync(readyPath), "endless script readiness");

      // Two-stroke cancel, then fx must come back promptly and truthfully.
      const cancelStartedAt = Date.now();
      await session.sendKeys("Escape");
      await session.waitForText("esc again to interrupt", TIMEOUT);
      await Bun.sleep(150);
      await session.sendKeys("Escape");
      const cancellation = await session.waitForText("What can fx do differently?", TIMEOUT);
      expect(Date.now() - cancelStartedAt).toBeLessThan(5_000);
      expect(cancellation).toContain("\u25aa Cancelled");
      expect(cancellation).not.toContain("system: cancelled");

      // The composer answers a new prompt, so the turn is responsive again.
      await session.sendText("Confirm the session still responds.");
      await session.waitForText(FOLLOW_UP_TEXT, TIMEOUT);
      expect((await session.capturePaneGrid()).join("\n")).not.toContain("Cancelling");
    },
    TIMEOUT * 3,
  );


  test(
    "Escape cancels an endless codemode script and fx returns to a responsive composer",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-codemode-cancel-tool-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      const workspaceRoot = realpathSync(workspace);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission_mode: "full-access",
          experimental: { codemode: true },
        }) + "\n",
      );
      gateway = startFakeGateway([
        fakeGatewayToolCall("codemode-cancel-hold", "codemode", {
          script: "while (true) {}",
        }),
        fakeGatewayFinalText(FOLLOW_UP_TEXT),
      ]);
      session = await TmuxSession.create({
        cwd: workspaceRoot,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-codemode-cancel-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
        },
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the endless codemode script.");

      // The codemode activity row proves the tool is gated in and running.
      await session.waitForText("Running script", TIMEOUT);

      // Two-stroke cancel, then fx must come back promptly and truthfully.
      const cancelStartedAt = Date.now();
      await session.sendKeys("Escape");
      await session.waitForText("esc again to interrupt", TIMEOUT);
      await Bun.sleep(150);
      await session.sendKeys("Escape");
      const cancellation = await session.waitForText("What can fx do differently?", TIMEOUT);
      expect(Date.now() - cancelStartedAt).toBeLessThan(5_000);
      expect(cancellation).toContain("▪ Cancelled");

      // The composer answers a new prompt, so the turn is responsive again.
      await session.sendText("Confirm the session still responds.");
      await session.waitForText(FOLLOW_UP_TEXT, TIMEOUT);
    },
    TIMEOUT * 3,
  );
});
