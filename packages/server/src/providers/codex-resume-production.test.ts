import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import type { NativeHelperGhosttyResumeDispatch, NativeHelperGhosttyTerminalView } from "@agent-visor/protocol";
import { FakeNativeHelper } from "../native-helper.js";
import { NativeSessionControls } from "../session-controls.js";
import { SessionRepository } from "../sessions.js";
import { CodexProvider } from "./codex.js";
import { CodexResumeAdapter } from "./codex-resume.js";
import { LiveProviderEnvironment, type ProcessRecord } from "./environment.js";
import type { ProcessProvenanceResult } from "./process-provenance.js";
import type { RetainedHistoryRecord } from "../retained-history.js";

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
  sourceRowCwd = this.cwdPath;
  readonly executable = path.join(this.home, "bin", "codex");
  readonly database = path.join(this.codexHome, "sqlite", "state_5.sqlite");
  readonly rollout = path.join(this.codexHome, "sessions", "2026", "10", "21",
    `rollout-20261021T190000-${threadID}.jsonl`);
  sourceRowRollout = this.rollout;
  sourceRowSource = "cli";
  sourceRowArchived = 0;
  sqliteCallCount = 0;
  blockSqliteCall?: number;
  sqliteBlocked?: () => void;
  sqliteRelease?: Promise<void>;
  readonly repairExecutable = path.join(this.home, ".local", "bin", "codex");
  readonly repairProfilePath = path.join(this.codexHome, "repair.config.toml");
  live = true;
  resumeNonce: string | undefined;
  activeExecutable = this.executable;
  activeProfile = "work";

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
    mkdirSync(path.dirname(this.repairExecutable), { recursive: true });
    mkdirSync(this.cwdPath, { recursive: true });
    writeFileSync(this.database, "fixture database\n");
    writeFileSync(this.executable, "#!/bin/sh\n", { mode: 0o755 });
    writeFileSync(this.repairExecutable, "#!/bin/sh\n", { mode: 0o755 });
    writeFileSync(path.join(this.codexHome, "work.config.toml"), "profile = true\n");
    writeFileSync(this.repairProfilePath, "profile = true\n");
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
        tty: "ttys-codex", command: this.activeExecutable,
        arguments: `codex resume ${threadID} --cd ${this.cwdPath} --profile ${this.activeProfile}` },
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
    const call = this.sqliteCallCount++;
    if (call === this.blockSqliteCall) {
      this.sqliteBlocked?.();
      await this.sqliteRelease;
    }
    return [{
      id: threadID,
      rollout_path: this.sourceRowRollout,
      cwd: this.sourceRowCwd,
      title: "Production-shaped Codex row",
      updated_at: observedAt.valueOf() / 1_000,
      archived: this.sourceRowArchived,
      source: this.sourceRowSource,
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
        executableRef: this.activeExecutable,
        executableVersion: "1.2.3",
        configRootRef: this.codexHome,
        profileRef: this.activeProfile,
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
      environment.activeExecutable = environment.repairExecutable;
      environment.activeProfile = "repair";
      rmSync(environment.executable);
      rmSync(path.join(environment.codexHome, "work.config.toml"));

      const restarted = new SessionRepository([new CodexProvider(environment)], {
        now: () => observedAt,
        retainedHistoryPath: historyPath,
      });
      restarted.setControls(new NativeSessionControls(helper));
      await restarted.refresh();
      expect(restarted.historyPage().sessions).toContainEqual(expect.objectContaining({
        id: threadID,
        source: "Codex",
        resumeState: "unavailable",
        repairKind: "provider",
        repairFields: ["executable", "profile"],
      }));

      const beforeRepair = readFileSync(historyPath, "utf8");
      const malformedProfile = path.join(environment.codexHome, "broken.config.toml");
      writeFileSync(malformedProfile, "not a Codex profile\n");
      await expect(restarted.repairHistorySession(threadID, {
        kind: "provider",
        profileFileRef: malformedProfile,
      })).resolves.toMatchObject({ state: "rejected" });
      expect(readFileSync(historyPath, "utf8")).toBe(beforeRepair);
      await expect(restarted.repairHistorySession(threadID, null)).resolves.toMatchObject({ state: "cancelled" });
      expect(readFileSync(historyPath, "utf8")).toBe(beforeRepair);
      await expect(restarted.repairHistorySession(threadID, {
        kind: "provider",
        executableRef: environment.repairExecutable,
        profileFileRef: environment.repairProfilePath,
      })).resolves.toMatchObject({ state: "accepted" });
      expect(helper.ghosttyResumeRequests).toHaveLength(0);

      const repaired = new SessionRepository([new CodexProvider(environment)], {
        now: () => observedAt,
        retainedHistoryPath: historyPath,
      });
      repaired.setControls(new NativeSessionControls(helper));
      await repaired.refresh();
      expect(repaired.historyPage().sessions).toContainEqual(expect.objectContaining({
        id: threadID,
        source: "Codex",
        resumeState: "eligible",
      }));
      await expect(repaired.resumeSession(threadID)).resolves.toMatchObject({
        state: "matched",
        sessionId: threadID,
      });
      expect(helper.ghosttyResumeRequests).toHaveLength(1);
      expect(helper.ghosttyResumeRequests[0]).toMatchObject({
        provider: "codex_cli",
        sessionId: threadID,
        cwd: environment.cwdPath,
        executable: environment.repairExecutable,
        configRoot: environment.codexHome,
        profileRef: "repair",
      });
      expect(helper.ghosttyTerminalFocusRequests).toHaveLength(1);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("accepts an explicit profile clear and rejects a malformed selected profile", () => {
    const root = realpathSync(mkdtempSync(path.join("/tmp", "agent-visor-codex-repair-")));
    const environment = new ProductionCodexEnvironment(root);
    const capability = {
      version: 1 as const,
      provider: "codex_cli" as const,
      host: "Ghostty" as const,
      executableRef: environment.executable,
      executableVersion: "1.2.3",
      configRootRef: environment.codexHome,
      profileRef: "work",
      profileState: "present" as const,
      overrideNames: [],
      provenanceObservedAt: observedAt.toISOString(),
    };
    const record = {
      id: canonicalThreadID(threadID),
      canonicalId: `codex:native:${threadID}`,
      provider: "codex" as const,
      host: "Ghostty" as const,
      cwd: environment.cwdPath,
      configHome: environment.codexHome,
      transcriptPath: environment.rollout,
      resume: capability,
    } as RetainedHistoryRecord;
    const adapter = new CodexResumeAdapter(environment, async () => [], () => "authoritative");
    const malformed = path.join(environment.codexHome, "broken.config.toml");
    writeFileSync(malformed, "not a profile\n");
    try {
      expect(adapter.validateRepair(record, { kind: "provider", profileState: "verified_absent" }).state)
        .toBe("valid");
      expect(adapter.validateRepair(record, { kind: "provider", profileFileRef: malformed }).state)
        .toBe("unavailable");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("repairs a missing cwd from the exact Codex source row without launching", async () => {
    const root = realpathSync(mkdtempSync(path.join("/tmp", "agent-visor-codex-working-directory-")));
    const historyPath = path.join(root, "retained-history.json");
    const environment = new ProductionCodexEnvironment(root);
    const selectedCwd = path.join(root, "relocated-project");
    mkdirSync(selectedCwd, { recursive: true });
    const helper = new FakeNativeHelper();
    const initial = new SessionRepository([new CodexProvider(environment)], {
      now: () => observedAt,
      retainedHistoryPath: historyPath,
    });
    initial.setControls(new NativeSessionControls(helper));
    try {
      await initial.refresh();
      environment.live = false;
      await initial.refresh();
      rmSync(environment.cwdPath, { recursive: true, force: true });
      environment.sourceRowCwd = realpathSync(selectedCwd);

      expect(initial.historyPage().sessions).toContainEqual(expect.objectContaining({
        id: threadID,
        resumeState: "unavailable",
        repairKind: "working_directory",
        resumeReason: "Resume unavailable: the original working directory is unavailable.",
      }));

      const before = JSON.parse(readFileSync(historyPath, "utf8")) as {
        records: Array<Record<string, unknown>>;
      };
      const repaired = new SessionRepository([new CodexProvider(environment)], {
        now: () => observedAt,
        retainedHistoryPath: historyPath,
      });
      repaired.setControls(new NativeSessionControls(helper));
      await repaired.refresh();
      await expect(repaired.repairHistorySession(threadID, {
        kind: "working_directory",
        cwd: selectedCwd,
      })).resolves.toMatchObject({ state: "accepted" });
      expect(helper.ghosttyResumeRequests).toHaveLength(0);

      const after = JSON.parse(readFileSync(historyPath, "utf8")) as {
        records: Array<Record<string, unknown>>;
      };
      expect(after.records).toHaveLength(1);
      expect(after.records[0]).toEqual({
        ...before.records[0],
        cwd: realpathSync(selectedCwd),
      });
      expect(environment.sourceRowCwd).toBe(realpathSync(selectedCwd));

      const restarted = new SessionRepository([new CodexProvider(environment)], {
        now: () => observedAt,
        retainedHistoryPath: historyPath,
      });
      restarted.setControls(new NativeSessionControls(helper));
      await restarted.refresh();
      expect(restarted.historyPage().sessions).toContainEqual(expect.objectContaining({
        id: threadID,
        cwd: realpathSync(selectedCwd),
        resumeState: "eligible",
      }));
      await expect(restarted.resumeSession(threadID)).resolves.toMatchObject({
        state: "uncertain",
      });
      expect(helper.ghosttyResumeRequests).toHaveLength(1);
      expect(helper.ghosttyResumeRequests[0]).toMatchObject({
        provider: "codex_cli",
        sessionId: threadID,
        cwd: realpathSync(selectedCwd),
        executable: environment.executable,
        configRoot: environment.codexHome,
        profileRef: "work",
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("cancels and rejects invalid or mismatched folder repairs without mutation", async () => {
    const root = realpathSync(mkdtempSync(path.join("/tmp", "agent-visor-codex-working-directory-reject-")));
    const historyPath = path.join(root, "retained-history.json");
    const environment = new ProductionCodexEnvironment(root);
    const selectedCwd = path.join(root, "relocated-project");
    const invalidCwd = path.join(root, "missing-project");
    mkdirSync(selectedCwd, { recursive: true });
    const helper = new FakeNativeHelper();
    const initial = new SessionRepository([new CodexProvider(environment)], {
      now: () => observedAt,
      retainedHistoryPath: historyPath,
    });
    initial.setControls(new NativeSessionControls(helper));
    try {
      await initial.refresh();
      environment.live = false;
      await initial.refresh();
      rmSync(environment.cwdPath, { recursive: true, force: true });
      environment.sourceRowCwd = realpathSync(selectedCwd);

      const repaired = new SessionRepository([new CodexProvider(environment)], {
        now: () => observedAt,
        retainedHistoryPath: historyPath,
      });
      repaired.setControls(new NativeSessionControls(helper));
      await repaired.refresh();
      const before = readFileSync(historyPath, "utf8");

      await expect(repaired.repairHistorySession(threadID, null)).resolves.toMatchObject({ state: "cancelled" });
      expect(readFileSync(historyPath, "utf8")).toBe(before);

      await expect(repaired.repairHistorySession(threadID, {
        kind: "working_directory",
        cwd: invalidCwd,
      })).resolves.toMatchObject({
        state: "rejected",
        reason: "The selected Codex working directory is unavailable.",
      });
      expect(readFileSync(historyPath, "utf8")).toBe(before);

      environment.sourceRowCwd = environment.cwdPath;
      await expect(repaired.repairHistorySession(threadID, {
        kind: "working_directory",
        cwd: selectedCwd,
      })).resolves.toMatchObject({
        state: "rejected",
        reason: "Codex cannot prove this UUID belongs to the selected folder from its saved source row.",
      });
      expect(readFileSync(historyPath, "utf8")).toBe(before);

      environment.sourceRowCwd = realpathSync(selectedCwd);
      environment.sourceRowRollout = path.join(root, "other-rollout.jsonl");
      await expect(repaired.repairHistorySession(threadID, {
        kind: "working_directory",
        cwd: selectedCwd,
      })).resolves.toMatchObject({
        state: "rejected",
        reason: "Codex source metadata does not match the retained conversation transcript.",
      });
      expect(readFileSync(historyPath, "utf8")).toBe(before);
      expect(helper.ghosttyResumeRequests).toHaveLength(0);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("rejects a removal racing async source validation without dispatch", async () => {
    const root = realpathSync(mkdtempSync(path.join("/tmp", "agent-visor-codex-working-directory-race-")));
    const historyPath = path.join(root, "retained-history.json");
    const environment = new ProductionCodexEnvironment(root);
    const selectedCwd = path.join(root, "relocated-project");
    mkdirSync(selectedCwd, { recursive: true });
    const helper = new FakeNativeHelper();
    const initial = new SessionRepository([new CodexProvider(environment)], {
      now: () => observedAt,
      retainedHistoryPath: historyPath,
    });
    initial.setControls(new NativeSessionControls(helper));
    let releaseValidation: () => void = () => {};
    const validationBlocked = new Promise<void>((resolve) => {
      environment.sqliteBlocked = resolve;
    });
    environment.sqliteRelease = new Promise<void>((resolve) => {
      releaseValidation = resolve;
    });
    try {
      await initial.refresh();
      environment.live = false;
      await initial.refresh();
      rmSync(environment.cwdPath, { recursive: true, force: true });
      environment.sourceRowCwd = realpathSync(selectedCwd);

      const repaired = new SessionRepository([new CodexProvider(environment)], {
        now: () => observedAt,
        retainedHistoryPath: historyPath,
      });
      repaired.setControls(new NativeSessionControls(helper));
      await repaired.refresh();
      environment.sqliteCallCount = 0;
      environment.blockSqliteCall = 1;
      const repair = repaired.repairHistorySession(threadID, {
        kind: "working_directory",
        cwd: selectedCwd,
      });
      await validationBlocked;
      await expect(repaired.removeHistorySession(threadID)).resolves.toBeUndefined();
      releaseValidation();
      await expect(repair).resolves.toMatchObject({
        state: "rejected",
        reason: "The retained session is no longer available.",
      });
      expect(helper.ghosttyResumeRequests).toHaveLength(0);
    } finally {
      releaseValidation();
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("rejects a source-row change between validation and the atomic repair", async () => {
    const root = realpathSync(mkdtempSync(path.join("/tmp", "agent-visor-codex-working-directory-source-race-")));
    const historyPath = path.join(root, "retained-history.json");
    const environment = new ProductionCodexEnvironment(root);
    const selectedCwd = path.join(root, "relocated-project");
    mkdirSync(selectedCwd, { recursive: true });
    const helper = new FakeNativeHelper();
    const initial = new SessionRepository([new CodexProvider(environment)], {
      now: () => observedAt,
      retainedHistoryPath: historyPath,
    });
    initial.setControls(new NativeSessionControls(helper));
    let releaseValidation: () => void = () => {};
    const validationBlocked = new Promise<void>((resolve) => {
      environment.sqliteBlocked = resolve;
    });
    environment.sqliteRelease = new Promise<void>((resolve) => {
      releaseValidation = resolve;
    });
    try {
      await initial.refresh();
      environment.live = false;
      await initial.refresh();
      rmSync(environment.cwdPath, { recursive: true, force: true });
      environment.sourceRowCwd = realpathSync(selectedCwd);

      const repaired = new SessionRepository([new CodexProvider(environment)], {
        now: () => observedAt,
        retainedHistoryPath: historyPath,
      });
      repaired.setControls(new NativeSessionControls(helper));
      await repaired.refresh();
      const before = readFileSync(historyPath, "utf8");
      environment.sqliteCallCount = 0;
      environment.blockSqliteCall = 1;
      const repair = repaired.repairHistorySession(threadID, {
        kind: "working_directory",
        cwd: selectedCwd,
      });
      await validationBlocked;
      environment.sourceRowCwd = environment.cwdPath;
      releaseValidation();
      await expect(repair).resolves.toMatchObject({
        state: "rejected",
        reason: "Codex cannot prove this UUID belongs to the selected folder from its saved source row.",
      });
      expect(readFileSync(historyPath, "utf8")).toBe(before);
      expect(helper.ghosttyResumeRequests).toHaveLength(0);
    } finally {
      releaseValidation();
      rmSync(root, { recursive: true, force: true });
    }
  });
});

function canonicalThreadID(threadID: string): string {
  return `codex:native:${threadID}`;
}
