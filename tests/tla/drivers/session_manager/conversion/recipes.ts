// The state D56 says the converter carries besides the conversation, each
// made by the older build (v1) through the real binary: the kinds
// carried.test.ts reads back, and the v1 session fixtures' generator makes
// (tests/fixtures/v1-sessions/generate.ts).
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { binary, shellQuote, targetModule } from "../../lib/context";
import {
  fakeGatewayFinalText, fakeGatewaySse, fakeGatewayToolCall, plainReplies, shown, TmuxSession, waitUntil, type Fixture, type Via, v1Writer,
} from "./driver";

const { readPermissionsPanel } = await targetModule("info-panel.ts");

export type Made = { id: string; read(home: string, v2: boolean): Promise<string | null> };

// Continues `id` in the profile at `home` with one prompt: the requests fx
// sent the model, or null when it could not continue. Without --auto, the
// fixture's full access runs every tool call unreviewed.
async function continued(f: Fixture, id: string, home: string, v2: boolean, prompt: string) {
  const mark = f.gateway.requests.length;
  const run = await f.fx(v2, ["ask", "--json", v2 ? "--resume" : "--resume-id", id, prompt], home);
  return run.code === 0 ? f.gateway.requests.slice(mark).map((r: any) => r.body as string) : null;
}

// The results of these tool calls, as the first request carrying them all shows the model.
function toolResults(bodies: string[] | null, ...callIds: string[]): string | null {
  for (const body of bodies ?? []) {
    const results = JSON.parse(body).prompt.filter((m: any) => m.role === "tool").flatMap((m: any) => m.content)
      .filter((part: any) => callIds.includes(part.toolCallId));
    if (results.length === callIds.length) return JSON.stringify(results);
  }
  return null;
}

// Answers with each tool call once the one before it has its result, then with text.
function calls(...steps: [callId: string, tool: string, input: object][]) {
  return (body: string) => {
    const next = steps.find(([callId]) => !body.includes(callId));
    return next ? fakeGatewayToolCall(...next) : fakeGatewayFinalText("CONV_CALLS_DONE");
  };
}

// Resumes `id` in the app on the profile at `home`, runs `use` once the
// session is open, and quits; null when the session does not open.
async function inApp(f: Fixture, home: string, v2: boolean, id: string, use: (app: any) => Promise<string | null>): Promise<string | null> {
  const app = await TmuxSession.create({
    cmd: `${shellQuote(v2 ? binary : v1Writer())} --resume ${shellQuote(id)}`, cwd: f.workspace, env: f.env(v2, home), width: 200, height: 50,
  });
  f.apps.add(app);
  try {
    const opened = await waitUntil(async () => !app.isAlive() || (await app.captureFullScrollback()).includes("session resumed"), 15_000);
    if (!opened || !app.isAlive()) return null;
    await app.waitForComposer(15_000);
    const result = await use(app);
    await app.sendText("/quit");
    await app.waitForSessionEnd(10_000);
    return result;
  } finally { await app.kill().catch(() => {}); f.apps.delete(app); }
}

// A saved-session allow rule, made in the v1 app; read back by /permissions.
// The rule names a path in the workspace, which both copies share.
async function rules(f: Fixture): Promise<Made> {
  plainReplies(f);
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  // Relative, so the rule's display text, which fx shortens, keeps its name.
  const command = "touch conv-allowed";
  await inApp(f, f.home, false, id, async app => {
    await app.sendText(`/permissions remember allow shell ${JSON.stringify({ action: "run", timeout_ms: 600_000, command })}`);
    await app.waitForText("Remember allow for this saved session", 15_000);
    await app.sendKeys("1");
    await app.waitForText("saved-session permission rule updated", 15_000);
    return "";
  });
  assert(readFileSync(join(f.v1Root, id, "permissions.json"), "utf8").includes("conv-allowed"), "the v1 app saved no permission rule");
  return {
    id, read: (home, v2) => inApp(f, home, v2, id, async app => {
      // The older build lists the rules in the transcript; this one in the
      // /permissions panel. Both read back as the older build listed them.
      if (v2) {
        const panel = await readPermissionsPanel(app, 15_000, (shown: any) => shown.fields["Saved rules"] !== undefined);
        const count = panel.fields["Saved rules"];
        if (count === "none") return "saved-session permission rules: none";
        return [`saved-session permission rules (${count}):`, ...(panel.items["Saved rules"] ?? []).map((rule: string) => `  ${rule}`)].join("\n");
      }
      await app.sendText("/permissions");
      await app.waitForText("saved-session permission rules", 15_000);
      const text = await app.captureFullScrollback();
      const [head, ...listed] = text.slice(text.lastIndexOf("saved-session permission rules")).split("\n\n")[0]!.split("\n");
      return [head!.trimEnd(), ...listed.map((rule) => `  ${rule.trim()}`)].join("\n");
    }),
  };
}

// Each kind: how it is made, the host whose open is observed, and what its
// v1 reading must show for the comparison to mean something.
export const KINDS: Record<string, { name: string; make(f: Fixture): Promise<Made>; via: Via; shows: RegExp }> = {
  rules: { name: "saved-session permission rules", make: rules, via: "app", shows: /saved-session permission rules \(1\):\n\s+1 allow shell\.run touch .*conv-allowed/ },
  terminal: { name: "hosted terminal state", make: terminal, via: "ask", shows: /ended when the fx process that started it exited/ },
  unfinished: { name: "unfinished reply in recovery.json", make: unfinished, via: "ask", shows: /CONV_PARTIAL_REPLY.*turn_aborted/ },
  side: { name: "tool-result side files and their handles", make: sideFile, via: "ask", shows: /total_bytes.*output_delta.*150001/ },
  midturn: { name: "cut of a compaction inside a turn", make: midTurn, via: "ask", shows: /CONV_LONG.*CONV_STEP_TWO.*CONV_TURN_DONE/ },
};
