import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import type { NativeHelperGhosttyResumeDispatch, NativeHelperGhosttyTerminalView } from "@agent-visor/protocol";
import { FakeNativeHelper } from "../native-helper.js";
import { NativeSessionControls } from "../session-controls.js";
import { SessionRepository } from "../sessions.js";
import { CodexProvider } from "./codex.js";
import { LiveProviderEnvironment, type ProcessRecord } from "./environment.js";
import type { ProcessProvenanceResult } from "./process-provenance.js";

const threadID = "019f3931-ec11-7f31-8400-1c8624aa9e4d";
const observedAt = new Date("2026-10-21T19:00:00.000Z");
const codexPID = 702;
const ghosttyPID = 701;
const codexToken = "fixture-codex-start";
const ghosttyToken = "fixture-ghostty-start";

/** A production-shaped provider boundary with only synthetic external evidence. */
class ProductionCodexEnvironment extends LiveProviderEnvironment {
  readonly codexHome = path.join(this.home, ".codex");
  readonly cwdPath = path.join(this.home, "project");
  readonly executable = path.join(this.home, "bin", "codex");
  readonly database = path.join(this.codexHome, "sqlite", "state_5.sqlite");
  readonly rollout = path.join(this.codexHome, "sessions", "2026", "10", "21",
    `rollout-20261021T190000-${threadID}.jsonl`);
  live = true;
  resumeNonce: string | undefined;

  override readonly readCodexTuiBinding = async (pid: number, home: string) => {
    if (!this.live || pid !== codexPID || home !== this.codexHome) return undefined;
    return {
      sessionIds: [threadID],
      origin: "http://127.0.0.1:60119",
      socketPath: path.join(this.codexHome, "app-server-control.sock"),
      socketIdentity: "fixture-socket",
      inventory: { loaded: [threadID], roots: [{ id: threadID, path: this.rollout }] },
    };
  };

  override readonly codexTuiTransportCapability = async () => "supported" as const;

  constructor(root: string) {
    super(root, { now: () => new Date(observedAt) });
    mkdirSync(path.dirname(this.database), { recursive: true });
    mkdirSync(path.dirname(this.rollout), { recursive: true });
    mkdirSync(path.dirname(this.executable), { recursive: true });
    mkdirSync(this.cwdPath, { recursive: true });
    writeFileSync(this.database, "fixture database\n");
    writeFileSync(this.executable, "#!/bin/sh\n", { mode: 0o755 });
    writeFileSync(path.join(this.codexHome, "work.config.toml"), "profile = true\n");
    writeFileSync(this.rollout, [
      JSON.stringify({ type: "session_meta", payload: { id: threadID, originator: "codex_cli_rs" } }),
      JSON.stringify({ type: "event_msg", timestamp: observedAt.toISOString(), payload: { type: "task_complete" } }),
    ].join("\n") + "\n");
  }

  override async processes(): Promise<ProcessRecord[]> {
    if (!this.live) return [];
    return [
      { pid: ghosttyPID, parentPID: 1, processStartToken: ghosttyToken,
        command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
      { pid: codexPID, parentPID: ghosttyPID, processStartToken: codexToken,
        tty: "ttys-codex", command: this.executable,
        arguments: `codex resume ${threadID} --cd ${this.cwdPath} --profile work` },
    ];
  }

  override async processesFreshInventory() {
    return {
      state: "authoritative" as const,
      observedAt: observedAt.toISOString(),
      processes: await this.processes(),
    };
  }

  override async cwd(pid: number) { return pid === codexPID ? this.cwdPath : undefined; }
  override async processStartedAt(pid: number) { return pid === codexPID ? observedAt : undefined; }
  override async codexProcessHome(pid: number) { return pid === codexPID ? this.codexHome : undefined; }
  override async herdrCodexSurface() { return undefined; }
  override async directory() { return []; }
  override async read() { return undefined; }

  override async stamp(file: string) {
    if (file === this.database) return { modifiedAt: observedAt, size: 100 };
    if (file === this.rollout) return { modifiedAt: observedAt, size: readFileSync(file).byteLength };
    return undefined;
  }

  override async readHeadTail(file: string) {
    if (file !== this.rollout) return undefined;
    const content = readFileSync(file, "utf8");
    return { head: content, tail: content };
  }

  override async scanLinePrefixes(
    file: string,
    prefixBytes: number,
    visit: (line: string) => void,
    startAt = 0,
  ) {
    if (file !== this.rollout) return startAt;
    const bytes = Buffer.from(readFileSync(file));
    if (startAt >= bytes.length) return startAt;
    let offset = startAt;
    for (;;) {
      const end = bytes.indexOf(0x0a, offset);
      if (end < 0) return offset;
      visit(bytes.subarray(offset, Math.min(end, offset + prefixBytes)).toString("utf8"));
      offset = end + 1;
    }
  }

  override async sqlite(_database: string, _query: string) {
    return [{
      id: threadID,
      rollout_path: this.rollout,
      cwd: this.cwdPath,
      title: "Production-shaped Codex row",
      updated_at: observedAt.valueOf() / 1_000,
      archived: 0,
      source: "cli",
    }];
  }

  override async processProvenance(
    pid: number,
    expected: "claude_code" | "codex_cli",
    processStartToken?: string,
  ): Promise<ProcessProvenanceResult> {
    if (!this.live || expected !== "codex_cli" || pid !== codexPID || processStartToken !== codexToken) {
      return { state: "unavailable", reason: "process_missing" };
    }
    return {
      state: "available",
      value: {
        version: 1,
        pid,
        processStartToken: codexToken,
        executableRef: this.executable,
        executableVersion: "1.2.3",
        configRootRef: this.codexHome,
        profileRef: "work",
        profileState: "present",
        overrideNames: [],
        ...(this.resumeNonce ? { resumeNonce: this.resumeNonce } : {}),
        argvState: "complete",
        observedAt: observedAt.toISOString(),
      },
    };
  }

  override readonly ghosttyTerminalViews = async (): Promise<NativeHelperGhosttyTerminalView[]> => {
    if (!this.resumeNonce) return [];
    return [{
      applicationPID: ghosttyPID,
      processStartToken: ghosttyToken,
      terminalId: "codex-production-terminal",
      title: "Production-shaped Codex row",
      cwd: this.cwdPath,
      viewMode: "conversation",
    }];
  }
}

describe("Codex production-shaped retained resume", () => {
  it("observes, closes, reconstructs, and resumes through the real provider and repository", async () => {
    const root = realpathSync(mkdtempSync(path.join("/tmp", "agent-visor-codex-production-")));
    const historyPath = path.join(root, "retained-history.json");
    const environment = new ProductionCodexEnvironment(root);
    const canonicalId = `codex:native:${threadID}`;
    const terminal: NativeHelperGhosttyTerminalView = {
      applicationPID: ghosttyPID,
      processStartToken: ghosttyToken,
      terminalId: "codex-production-terminal",
      title: "Production-shaped Codex row",
      cwd: environment.cwdPath,
      viewMode: "conversation",
    };
    const helper = new FakeNativeHelper();
    helper.openGhosttyResume = async target => {
      helper.ghosttyResumeRequests.push(structuredClone(target));
      environment.live = true;
      environment.resumeNonce = target.nonce;
      const dispatch: NativeHelperGhosttyResumeDispatch = {
        attemptId: target.attemptId,
        provider: target.provider,
        sessionId: target.sessionId,
        applicationPID: terminal.applicationPID,
        processStartToken: terminal.processStartToken,
        windowId: "codex-production-window",
        tabId: "codex-production-tab",
        terminalId: terminal.terminalId,
        nonce: target.nonce,
        dispatchedAt: observedAt.toISOString(),
      };
      helper.ghosttyResumeDispatches.push(structuredClone(dispatch));
      return dispatch;
    };
    try {
      const initial = new SessionRepository([new CodexProvider(environment)], {
        now: () => observedAt,
        retainedHistoryPath: historyPath,
      });
      initial.setControls(new NativeSessionControls(helper));
      await initial.refresh();
      expect(initial.chatRecord(threadID)).toMatchObject({
        historyIdentity: {
          verified: true,
          current: true,
          canonicalId,
          configHome: environment.codexHome,
          resume: {
            provider: "codex_cli",
            executableRef: environment.executable,
            profileRef: "work",
            profileState: "present",
            overrideNames: [],
          },
        },
        controlTarget: { kind: "terminal", target: { application: "Ghostty", pid: codexPID } },
      });

      environment.live = false;
      await initial.refresh();

      const restarted = new SessionRepository([new CodexProvider(environment)], {
        now: () => observedAt,
        retainedHistoryPath: historyPath,
      });
      restarted.setControls(new NativeSessionControls(helper));
      await restarted.refresh();
      expect(restarted.historyPage().sessions).toContainEqual(expect.objectContaining({
        id: threadID,
        source: "Codex",
        resumeState: "eligible",
      }));

      await expect(restarted.resumeSession(threadID)).resolves.toMatchObject({
        state: "matched",
        sessionId: threadID,
      });
      expect(helper.ghosttyResumeRequests).toHaveLength(1);
      expect(helper.ghosttyResumeRequests[0]).toMatchObject({
        provider: "codex_cli",
        sessionId: threadID,
        cwd: environment.cwdPath,
        executable: environment.executable,
        configRoot: environment.codexHome,
        profileRef: "work",
      });
      expect(helper.ghosttyTerminalFocusRequests).toHaveLength(1);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
