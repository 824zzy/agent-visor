import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { SessionRepository } from "../sessions.js";
import { chatCapabilities } from "../chat.js";
import { menuPresentation } from "../menu.js";
import { CodexProvider } from "./codex.js";
import {
  canonicalCodexHome, codexHomeStatuses, codexInstanceID, codexSessionID, codexThreadReference, type CodexHome,
} from "./codex-instances.js";
import { LiveProviderEnvironment, type ProcessRecord } from "./environment.js";

const threadID = "019f3931-ec11-7f31-8400-1c8624aa9e4d";
const executable = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT";

class TwoDesktopEnvironment extends LiveProviderEnvironment {
  running: ProcessRecord[] = [];
  commands = new Map<number, string>();
  override async processes() { return this.running; }
  override async codexDesktopCommand(pid: number) { return this.commands.get(pid); }
}

function createThread(home: string, title: string): string {
  mkdirSync(home, { recursive: true });
  const database = path.join(home, "state_5.sqlite");
  const rollout = path.join(home, "rollout.jsonl");
  writeFileSync(rollout, [
    JSON.stringify({ type: "session_meta", payload: { id: threadID, originator: "Codex Desktop" } }),
    JSON.stringify({ timestamp: "2026-09-28T23:00:00Z", type: "event_msg",
      payload: { type: "task_complete", turn_id: "turn-1" } }),
  ].join("\n") + "\n");
  execFileSync("/usr/bin/sqlite3", [database, `
    create table threads (id text primary key, rollout_path text, cwd text, title text,
      updated_at integer, archived integer, source text);
    insert into threads values ('${threadID}', '${rollout}', '/project', '${title}',
      1790636400, 0, 'vscode');
  `]);
  return rollout;
}

describe("Codex Desktop instances", () => {
  it("keeps equal thread UUIDs separate and routes each verified owner", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "visor-codex-homes-"));
    try {
      const nativeHome = path.join(root, ".codex");
      const copilotHome = path.join(root, "copilot");
      const nativeRollout = createThread(nativeHome, "Native task");
      const copilotRollout = createThread(copilotHome, "Copilot task");
      writeFileSync(path.join(copilotHome, "config.toml"), 'model_provider = "copilot_api"\n');
      const canonicalNative = await canonicalCodexHome(nativeHome);
      const canonicalCopilot = await canonicalCodexHome(copilotHome);
      const environment = new TwoDesktopEnvironment(root, { now: () => new Date("2026-09-28T23:05:00Z") });
      environment.running = [48377, 70220].map((pid) => ({
        pid, parentPID: 1, command: executable, arguments: executable,
      }));
      environment.commands.set(48377, executable);
      environment.commands.set(70220, `${executable} --user-data-dir=/tmp/copilot CODEX_HOME=${copilotHome}`);
      const homes: CodexHome[] = [];
      let ignored: string[] = [];
      const provider = new CodexProvider(
        environment, () => homes, async (home) => { homes.push(home); }, () => ignored,
      );
      const repository = new SessionRepository([provider]);
      const sessions = (await repository.refresh()).sessions;
      const secondID = codexSessionID(codexInstanceID(canonicalCopilot, canonicalNative), threadID);
      expect(sessions.map((session) => session.id)).toEqual([threadID, secondID]);
      expect(sessions.map((session) => session.owner)).toEqual(["Codex", "Codex · Copilot"]);
      expect(menuPresentation(await repository.current(), [], Date.now()).navigatorPills
        .find((pill) => pill.id === secondID)?.source).toBe("Codex · Copilot");
      expect(homes).toEqual([{ path: canonicalCopilot, label: "Codex · Copilot" }]);
      expect((await provider.resolve(threadID))?.chatPath).toBe(nativeRollout);
      const second = await provider.resolve(secondID);
      expect(second).toMatchObject({
        chatPath: copilotRollout, title: "Copilot task", canEnterChat: true,
        controlTarget: { kind: "codex_thread", target: {
          pid: 70220, home: canonicalCopilot, threadId: threadID,
        } },
      });
      expect(second?.messageTransport).toBeUndefined();
      expect(chatCapabilities(second!).canSendText).toBe(false);
      expect((await provider.resolve(threadID))?.controlTarget).toEqual({
        kind: "codex_thread", target: { pid: 48377, home: canonicalNative, threadId: threadID },
      });
      expect(codexThreadReference(secondID)).toEqual({
        instanceID: codexInstanceID(canonicalCopilot, canonicalNative), threadID,
      });

      environment.running = [];
      const closed = await provider.resolve(secondID);
      expect(closed?.canOpenOwner).toBe(false);
      expect(closed?.controlTarget).toBeUndefined();
      expect(closed?.chatPath).toBe(copilotRollout);

      homes.length = 0;
      ignored = [canonicalCopilot];
      environment.running = [{ pid: 70220, parentPID: 1, command: executable, arguments: executable }];
      expect((await provider.discover()).map((session) => session.id)).toEqual([threadID]);
      expect((await provider.resolve(threadID))?.canOpenOwner).toBe(false);
      expect(homes).toEqual([]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("does not bind an unreadable custom-profile process to the native home", async () => {
    const environment = new TwoDesktopEnvironment("/fixture");
    environment.running = [{ pid: 42, parentPID: 1, command: executable, arguments: executable }];
    environment.commands.set(42, `${executable} --user-data-dir=/tmp/other`);
    const { codexDesktopBindings } = await import("./codex-instances.js");
    expect(await codexDesktopBindings(environment, "/fixture/.codex")).toEqual(new Map());
  });

  it("reports running, saved, and missing homes from their own index", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "visor-codex-status-"));
    try {
      const native = path.join(root, ".codex");
      const copilot = path.join(root, "copilot");
      createThread(native, "Native task");
      createThread(copilot, "Copilot task");
      const environment = new TwoDesktopEnvironment(root);
      environment.running = [{ pid: 70220, parentPID: 1, command: executable, arguments: executable }];
      environment.commands.set(70220, `${executable} CODEX_HOME=${copilot}`);
      const canonicalNative = await canonicalCodexHome(native);
      expect(await codexHomeStatuses(environment, [
        { path: copilot, label: "Copilot" },
        { path: path.join(root, "missing"), label: "Missing" },
      ])).toEqual([
        { path: canonicalNative, status: "saved" },
        { path: copilot, status: "running" },
        { path: path.join(root, "missing"), status: "missing" },
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
