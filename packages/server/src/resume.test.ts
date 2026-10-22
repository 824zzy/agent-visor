import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import type {
  NativeHelperGhosttyResumeDispatch,
  NativeHelperGhosttyTerminalView,
} from "@agent-visor/protocol";
import { RetainedHistoryStore, type RetainedHistoryRecord } from "./retained-history.js";
import { ResumeAttemptStore, ResumeCoordinator, type ResumeNativeController } from "./resume.js";
import { FakeNativeHelper } from "./native-helper.js";
import { NativeSessionControls } from "./session-controls.js";
import { SessionRepository } from "./sessions.js";
import { ClaudeProvider } from "./providers/claude.js";
import { ClaudeResumeAdapter } from "./providers/claude-resume.js";
import type { FileStamp, GhosttyTerminalView, ProcessRecord, ProviderEnvironment } from "./providers/environment.js";
import type { ProcessProvenanceResult } from "./providers/process-provenance.js";
import { processInstanceToken } from "./providers/shared.js";

class RealClaudeResumeFixtureEnvironment implements ProviderEnvironment {
  readonly observedWindowMs = 42 * 60 * 60 * 1_000;
  readonly processStarted = new Map<number, Date>();
  readonly directories = new Map<string, string[]>();
  readonly files = new Map<string, string>();
  readonly stamps = new Map<string, FileStamp>();
  readonly headTails = new Map<string, { head: string; tail: string }>();
  readonly ghosttyViews: GhosttyTerminalView[] = [];
  processRows: ProcessRecord[] = [];
  processInventoryReads = 0;
  resumeReady = false;
  resumeNonce: string | undefined;
  currentProviderPID = 5_001;
  currentGhosttyPID = 7_001;
  readonly nowValue = new Date("2026-10-21T18:06:00.000Z");

  constructor(
    readonly home: string,
    readonly workingDirectory: string,
    readonly configRoot: string,
    readonly executable: string,
    readonly sessionID: string,
  ) {}

  now(): Date { return this.nowValue; }

  async processes(): Promise<ProcessRecord[]> {
    return structuredClone(this.processRows);
  }

  async processesFreshInventory() {
    this.processInventoryReads += 1;
    // The provider's exact UUID can lag the native receipt. Publish the
    // fixture process only on the third post-dispatch inventory read.
    const processes = this.resumeReady && this.processInventoryReads >= 5
      ? this.processRows : [];
    return {
      state: "authoritative" as const,
      observedAt: this.nowValue.toISOString(),
      processes: structuredClone(processes),
    };
  }

  async cwd(_pid: number): Promise<string | undefined> { return this.workingDirectory; }

  async processStartedAt(pid: number): Promise<Date | undefined> {
    return this.processStarted.get(pid);
  }

  async directory(directory: string): Promise<string[]> {
    return [...(this.directories.get(directory) ?? [])];
  }

  async isDirectory(directory: string): Promise<boolean> {
    return directory === this.home || directory === this.workingDirectory || directory === this.configRoot;
  }

  async stamp(file: string): Promise<FileStamp | undefined> {
    return this.stamps.get(file);
  }

  async read(file: string): Promise<string | undefined> {
    return this.files.get(file);
  }

  async readHeadTail(file: string): Promise<{ head: string; tail: string } | undefined> {
    return this.headTails.get(file);
  }

  async scanLinePrefixes(
    _file: string,
    _prefixBytes: number,
    _visit: (line: string) => void,
    startAt = 0,
  ): Promise<number> { return startAt; }

  async sqlite(_database: string, _sql: string): Promise<unknown[]> { return []; }

  async processProvenance(
    pid: number,
    _expected: "claude_code" | "codex_cli",
    processStartToken?: string,
  ): Promise<ProcessProvenanceResult> {
    const process = this.processRows.find((candidate) => candidate.pid === pid);
    if (!process || !processStartToken || process.processStartToken !== processStartToken) {
      return { state: "unavailable", reason: "process_missing" };
    }
    return {
      state: "available",
      value: {
        version: 1,
        pid,
        processStartToken,
        executableRef: this.executable,
        configRootRef: this.configRoot,
        profileState: "verified_absent",
        overrideNames: [],
        ...(this.resumeNonce ? { resumeNonce: this.resumeNonce } : {}),
        argvState: "complete",
        observedAt: this.nowValue.toISOString(),
      },
    };
  }

  readonly ghosttyTerminalViews = async (): Promise<GhosttyTerminalView[]> => {
    return structuredClone(this.ghosttyViews);
  };

  setProcessIdentity(providerPID: number, ghosttyPID: number): void {
    this.currentProviderPID = providerPID;
    this.currentGhosttyPID = ghosttyPID;
    const providerToken = processInstanceToken(providerPID, this.nowValue)!;
    const ghosttyToken = processInstanceToken(ghosttyPID, this.nowValue)!;
    this.processStarted.set(providerPID, this.nowValue);
    this.processStarted.set(ghosttyPID, this.nowValue);
    this.processRows = [
      {
        pid: ghosttyPID,
        parentPID: 1,
        processStartToken: ghosttyToken,
        command: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
        arguments: "ghostty",
      },
      {
        pid: providerPID,
        parentPID: ghosttyPID,
        processStartToken: providerToken,
        tty: "ttys-resume",
        command: this.executable,
        arguments: `${this.executable} --resume ${this.sessionID}`,
      },
    ];
    const metadataName = `${providerPID}.json`;
    const sessionsDirectory = path.join(this.home, ".claude", "sessions");
    const metadataPath = path.join(sessionsDirectory, metadataName);
    const metadata = JSON.stringify({
      sessionId: this.sessionID,
      cwd: this.workingDirectory,
      kind: "interactive",
      status: "idle",
      entrypoint: "cli",
      name: "Delayed real Claude resume",
    });
    this.directories.set(sessionsDirectory, [metadataName]);
    this.files.set(metadataPath, metadata);
    this.stamps.set(metadataPath, { modifiedAt: this.nowValue, size: metadata.length });
    this.ghosttyViews.splice(0, this.ghosttyViews.length, {
      applicationPID: ghosttyPID,
      processStartToken: ghosttyToken,
      terminalId: "delayed-resume-terminal",
      title: "Delayed real Claude resume",
      cwd: this.workingDirectory,
      viewMode: "conversation",
    });
  }
}

describe("ResumeCoordinator", () => {
  it("rechecks durable History intent after cold liveness before dispatch", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-resume-intent-"));
    const home = path.join(root, "home");
    const cwd = path.join(root, "project");
    const configRoot = path.join(home, ".claude");
    const executable = path.join(home, ".local", "share", "claude", "versions", "2.1.296");
    const sessionID = "44444444-4444-4444-8444-444444444444";
    mkdirSync(cwd, { recursive: true });
    mkdirSync(configRoot, { recursive: true });
    mkdirSync(path.dirname(executable), { recursive: true });
    writeFileSync(executable, "#!/bin/sh\n", { mode: 0o755 });
    const canonicalCwd = realpathSync(cwd);
    const canonicalConfigRoot = realpathSync(configRoot);
    const project = canonicalCwd.replaceAll("/", "-").replaceAll(".", "-").replaceAll("_", "-");
    const transcriptPath = path.join(canonicalConfigRoot, "projects", project, `${sessionID}.jsonl`);
    mkdirSync(path.dirname(transcriptPath), { recursive: true });
    writeFileSync(transcriptPath, `${JSON.stringify({ sessionId: sessionID, cwd: canonicalCwd })}\n`);
    const now = new Date("2026-10-21T18:02:00.000Z");
    const capability = {
      version: 1 as const,
      provider: "claude_code" as const,
      host: "Ghostty" as const,
      executableRef: realpathSync(executable),
      configRootRef: canonicalConfigRoot,
      profileState: "verified_absent" as const,
      overrideNames: [],
      provenanceObservedAt: now.toISOString(),
    };
    const observation: Omit<RetainedHistoryRecord, "schemaVersion" | "closedAt"> = {
      id: sessionID,
      canonicalId: sessionID,
      provider: "claude_code",
      title: "Intent recheck",
      subtitle: "Closed Claude conversation",
      project: "project",
      owner: "Ghostty",
      host: "Ghostty",
      cwd: canonicalCwd,
      transcriptPath: realpathSync(transcriptPath),
      resume: capability,
      updatedAt: now.toISOString(),
      observedAt: now.toISOString(),
    };
    let releaseScan!: () => void;
    let scanStarted!: () => void;
    const scanReady = new Promise<void>((resolve) => { scanStarted = resolve; });
    const scanRelease = new Promise<void>((resolve) => { releaseScan = resolve; });
    const environment = {
      home,
      now: () => now,
      processesFreshInventory: async () => {
        scanStarted();
        await scanRelease;
        return { state: "authoritative" as const, observedAt: now.toISOString(), processes: [] };
      },
    } as unknown as ProviderEnvironment;
    const provider = new ClaudeResumeAdapter(environment, async () => [], () => "authoritative");
    const historyPath = path.join(root, "retained-history.json");
    const attemptsPath = path.join(root, "resume-attempts.json");
    const history = new RetainedHistoryStore({ path: historyPath, now: () => now });
    history.observe(observation);
    history.closeMissing(new Set(), "claude_code");
    const attempts = new ResumeAttemptStore(attemptsPath, () => now);
    let dispatches = 0;
    const helper: ResumeNativeController = {
      openGhosttyResume: async () => {
        dispatches += 1;
        throw new Error("dispatch should have been blocked");
      },
      focusGhosttyTerminal: async (_target: NativeHelperGhosttyTerminalView) => undefined,
    };
    const coordinator = new ResumeCoordinator({
      history,
      provider,
      helper,
      attempts,
      focusLive: async () => undefined,
    });

    try {
      const resultPromise = coordinator.resumeSession(sessionID);
      await scanReady;
      expect(history.remove(sessionID, "agent_visor")).toBe("removed");
      releaseScan();
      await expect(resultPromise).resolves.toMatchObject({
        state: "unavailable",
        sessionId: sessionID,
      });
      expect(dispatches).toBe(0);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("reconstructs a closed Claude row through the real adapter, durable claim, receipt, and exact focus", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-resume-real-flow-"));
    const home = path.join(root, "home");
    const cwd = path.join(root, "project");
    const configRoot = path.join(home, ".claude");
    const executable = path.join(home, ".local", "share", "claude", "versions", "2.1.296");
    const sessionID = "55555555-5555-4555-8555-555555555555";
    const now = new Date("2026-10-21T18:04:00.000Z");
    mkdirSync(cwd, { recursive: true });
    mkdirSync(configRoot, { recursive: true });
    mkdirSync(path.dirname(executable), { recursive: true });
    writeFileSync(executable, "#!/bin/sh\n", { mode: 0o755 });
    const canonicalCwd = realpathSync(cwd);
    const canonicalConfigRoot = realpathSync(configRoot);
    const project = canonicalCwd.replaceAll("/", "-").replaceAll(".", "-").replaceAll("_", "-");
    const transcriptPath = path.join(canonicalConfigRoot, "projects", project, `${sessionID}.jsonl`);
    mkdirSync(path.dirname(transcriptPath), { recursive: true });
    writeFileSync(transcriptPath, `${JSON.stringify({ sessionId: sessionID, cwd: canonicalCwd })}\n`);
    const capability = {
      version: 1 as const,
      provider: "claude_code" as const,
      host: "Ghostty" as const,
      executableRef: realpathSync(executable),
      configRootRef: canonicalConfigRoot,
      profileState: "verified_absent" as const,
      overrideNames: [],
      provenanceObservedAt: now.toISOString(),
    };
    const observation: Omit<RetainedHistoryRecord, "schemaVersion" | "closedAt"> = {
      id: sessionID,
      canonicalId: sessionID,
      provider: "claude_code",
      title: "Real resume flow",
      subtitle: "Closed Claude conversation",
      project: "project",
      owner: "Ghostty",
      host: "Ghostty",
      cwd: canonicalCwd,
      transcriptPath: realpathSync(transcriptPath),
      resume: capability,
      updatedAt: now.toISOString(),
      observedAt: now.toISOString(),
    };
    const providerToken = processInstanceToken(5000, now)!;
    const ghosttyToken = processInstanceToken(7000, now)!;
    const session = {
      id: sessionID,
      provider: "claude_code" as const,
      cwd: canonicalCwd,
      owner: "Ghostty",
      section: "ready" as const,
      updatedAt: now.toISOString(),
      canOpenOwner: true,
      canEnterChat: true,
      conversationState: "open" as const,
      controlTarget: {
        kind: "terminal" as const,
        target: {
          application: "Ghostty" as const,
          pid: 5000,
          processStartToken: providerToken,
          tty: "ttys42",
          cwd: canonicalCwd,
        },
      },
      historyIdentity: { verified: true, resume: capability },
    };
    let discoveryCalls = 0;
    let inventoryCalls = 0;
    let observedNonce = "";
    const terminal: NativeHelperGhosttyTerminalView = {
      applicationPID: 7000,
      processStartToken: ghosttyToken,
      terminalId: "created-terminal",
      title: "Real resume flow",
      cwd: canonicalCwd,
      viewMode: "conversation",
    };
    const environment = {
      home,
      now: () => now,
      processesFreshInventory: async () => {
        inventoryCalls += 1;
        if (inventoryCalls === 1) {
          return { state: "authoritative" as const, observedAt: now.toISOString(), processes: [] };
        }
        return {
          state: "authoritative" as const,
          observedAt: now.toISOString(),
          processes: [
            { pid: 7000, parentPID: 1, processStartToken: ghosttyToken, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
            { pid: 5000, parentPID: 7000, processStartToken: providerToken, tty: "ttys42", command: capability.executableRef, arguments: `claude --resume ${sessionID}` },
          ],
        };
      },
      processProvenance: async () => ({
        state: "available" as const,
        value: {
          version: 1 as const,
          pid: 5000,
          processStartToken: providerToken,
          executableRef: capability.executableRef,
          configRootRef: capability.configRootRef,
          profileState: "verified_absent" as const,
          overrideNames: [],
          resumeNonce: observedNonce,
          argvState: "complete" as const,
          observedAt: now.toISOString(),
        },
      }),
      ghosttyTerminalViews: async () => [terminal],
    } as unknown as ProviderEnvironment;
    const historyPath = path.join(root, "retained-history.json");
    const attemptsPath = path.join(root, "resume-attempts.json");
    const history = new RetainedHistoryStore({ path: historyPath, now: () => now });
    history.observe(observation);
    history.closeMissing(new Set(), "claude_code");
    const attempts = new ResumeAttemptStore(attemptsPath, () => now);
    let dispatches = 0;
    let focused: NativeHelperGhosttyTerminalView | undefined;
    const helper: ResumeNativeController = {
      openGhosttyResume: async (target) => {
        dispatches += 1;
        observedNonce = target.nonce;
        const dispatch: NativeHelperGhosttyResumeDispatch = {
          attemptId: target.attemptId,
          provider: target.provider,
          sessionId: target.sessionId,
          applicationPID: 7000,
          processStartToken: ghosttyToken,
          windowId: "window",
          tabId: "tab",
          terminalId: terminal.terminalId,
          nonce: target.nonce,
          dispatchedAt: now.toISOString(),
        };
        return dispatch;
      },
      focusGhosttyTerminal: async (target) => { focused = target; },
    };
    const provider = new ClaudeResumeAdapter(
      environment,
      async () => {
        discoveryCalls += 1;
        // A newly-created Claude process can be visible in the native
        // receipt before its exact conversation identity reaches discovery.
        // Keep the fixture authoritative but delayed so the coordinator must
        // reconcile the same dispatch again without launching a second one.
        return discoveryCalls < 4 ? [] : [session];
      },
      () => "authoritative",
    );
    const coordinator = new ResumeCoordinator({
      history,
      provider,
      helper,
      attempts,
      focusLive: async () => undefined,
    });

    try {
      await expect(coordinator.resumeSession(sessionID)).resolves.toMatchObject({
        state: "matched",
        sessionId: sessionID,
      });
      expect(dispatches).toBe(1);
      expect(discoveryCalls).toBe(4);
      expect(focused).toMatchObject({ terminalId: terminal.terminalId, cwd: canonicalCwd });
      expect(attempts.get(sessionID)).toMatchObject({ state: "matched", dispatch: { sessionId: sessionID } });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("reopens through a reconstructed SessionRepository and real ClaudeProvider after delayed UUID discovery", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-resume-session-repository-"));
    const home = path.join(root, "home");
    const cwd = path.join(root, "project");
    const configRoot = path.join(home, ".claude");
    const executable = path.join(home, ".local", "share", "claude", "versions", "2.1.296");
    const sessionID = "66666666-6666-4666-8666-666666666666";
    const historyPath = path.join(root, "retained-history.json");
    mkdirSync(cwd, { recursive: true });
    mkdirSync(configRoot, { recursive: true });
    mkdirSync(path.dirname(executable), { recursive: true });
    writeFileSync(executable, "#!/bin/sh\n", { mode: 0o755 });
    const canonicalCwd = realpathSync(cwd);
    const canonicalConfigRoot = realpathSync(configRoot);
    const project = canonicalCwd.replaceAll("/", "-").replaceAll(".", "-").replaceAll("_", "-");
    const transcriptPath = path.join(canonicalConfigRoot, "projects", project, `${sessionID}.jsonl`);
    mkdirSync(path.dirname(transcriptPath), { recursive: true });
    const firstUser = JSON.stringify({
      sessionId: sessionID,
      cwd: canonicalCwd,
      type: "user",
      uuid: "real-repository-user",
      timestamp: "2026-10-21T18:05:00.000Z",
      message: { role: "user", content: "Resume through the real repository" },
    });
    writeFileSync(transcriptPath, `${firstUser}\n`);
    const environment = new RealClaudeResumeFixtureEnvironment(
      realpathSync(home), canonicalCwd, canonicalConfigRoot, realpathSync(executable), sessionID,
    );
    environment.stamps.set(transcriptPath, { modifiedAt: environment.nowValue, size: firstUser.length + 1 });
    environment.headTails.set(transcriptPath, { head: `${firstUser}\n`, tail: `${firstUser}\n` });
    environment.setProcessIdentity(5_001, 7_001);
    const first = new SessionRepository([new ClaudeProvider(environment)], { retainedHistoryPath: historyPath });
    const helper = new FakeNativeHelper();
    const openGhosttyResume = helper.openGhosttyResume.bind(helper);
    helper.openGhosttyResume = async (target) => {
      environment.resumeReady = true;
      environment.resumeNonce = target.nonce;
      environment.setProcessIdentity(5_002, 7_002);
      const processStartToken = processInstanceToken(7_002, environment.nowValue)!;
      helper.ghosttyResumeDispatch = {
        attemptId: target.attemptId,
        provider: target.provider,
        sessionId: target.sessionId,
        applicationPID: 7_002,
        processStartToken,
        windowId: "delayed-window",
        tabId: "delayed-tab",
        terminalId: "delayed-resume-terminal",
        nonce: target.nonce,
        dispatchedAt: environment.nowValue.toISOString(),
      };
      return openGhosttyResume(target);
    };
    first.setControls(new NativeSessionControls(helper));

    try {
      expect((await first.refresh()).sessions).toContainEqual(expect.objectContaining({
        id: sessionID,
        owner: "Ghostty",
        canOpenOwner: true,
      }));
      environment.processRows = [];
      await first.refresh();

      const restarted = new SessionRepository([new ClaudeProvider(environment)], { retainedHistoryPath: historyPath });
      restarted.setControls(new NativeSessionControls(helper));
      await restarted.refresh();
      expect(restarted.historyPage().sessions).toContainEqual(expect.objectContaining({
        id: sessionID,
        resumeState: "eligible",
        ambientEligible: false,
      }));

      await expect(restarted.resumeSession(sessionID)).resolves.toMatchObject({
        state: "matched",
        sessionId: sessionID,
      });
      const dispatch = helper.ghosttyResumeDispatch;
      expect(dispatch).toBeDefined();
      if (!dispatch) throw new Error("The fixture did not retain its Ghostty dispatch receipt.");
      expect(environment.resumeNonce).toBe(dispatch.nonce);
      expect(dispatch.processStartToken).toBe(
        processInstanceToken(environment.currentGhosttyPID, environment.nowValue),
      );
      expect(environment.ghosttyViews).toContainEqual(expect.objectContaining({
        applicationPID: dispatch.applicationPID,
        processStartToken: dispatch.processStartToken,
        terminalId: dispatch.terminalId,
        cwd: canonicalCwd,
        viewMode: "conversation",
      }));
      await expect(environment.processProvenance(
        environment.currentProviderPID,
        "claude_code",
        environment.processRows.find((process) => process.pid === environment.currentProviderPID)
          ?.processStartToken,
      )).resolves.toMatchObject({
        state: "available",
        value: {
          pid: environment.currentProviderPID,
          resumeNonce: dispatch.nonce,
          executableRef: realpathSync(executable),
        },
      });
      expect(helper.ghosttyResumeRequests).toHaveLength(1);
      expect(helper.ghosttyResumeRequests[0]).toMatchObject({
        sessionId: sessionID,
        cwd: canonicalCwd,
        nonce: dispatch.nonce,
      });
      expect(helper.ghosttyTerminalFocusRequests).toMatchObject([{
        terminalId: "delayed-resume-terminal",
        cwd: canonicalCwd,
      }]);
      expect(environment.processInventoryReads).toBe(6);
      expect(restarted.current().sessions).not.toContainEqual(expect.objectContaining({
        id: sessionID,
        section: "working",
      }));
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

describe("Claude provider repair validation", () => {
  it("requires executable permission and bounded transcript UUID proof", () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-claude-repair-"));
    const home = path.join(root, "home");
    const cwd = path.join(root, "project");
    const configRoot = path.join(home, ".claude");
    const executable = path.join(home, ".local", "share", "claude", "versions", "2.1.296");
    const sessionID = "77777777-7777-4777-8777-777777777777";
    mkdirSync(cwd, { recursive: true });
    mkdirSync(configRoot, { recursive: true });
    mkdirSync(path.dirname(executable), { recursive: true });
    writeFileSync(executable, "#!/bin/sh\n", { mode: 0o755 });
    const selectedExecutable = path.join(home, ".local", "bin", "claude");
    mkdirSync(path.dirname(selectedExecutable), { recursive: true });
    symlinkSync(executable, selectedExecutable);
    const canonicalCwd = realpathSync(cwd);
    const canonicalConfigRoot = realpathSync(configRoot);
    const project = canonicalCwd.replaceAll("/", "-").replaceAll(".", "-").replaceAll("_", "-");
    const transcriptPath = path.join(canonicalConfigRoot, "projects", project, `${sessionID}.jsonl`);
    const settingsFile = path.join(canonicalConfigRoot, "settings.json");
    mkdirSync(path.dirname(transcriptPath), { recursive: true });
    const capability = {
      version: 1 as const,
      provider: "claude_code" as const,
      host: "Ghostty" as const,
      executableRef: realpathSync(executable),
      configRootRef: canonicalConfigRoot,
      profileState: "verified_absent" as const,
      overrideNames: [],
      provenanceObservedAt: "2026-10-21T18:07:00.000Z",
    };
    const record = {
      id: sessionID,
      canonicalId: sessionID,
      provider: "claude_code" as const,
      host: "Ghostty" as const,
      cwd: canonicalCwd,
      configHome: canonicalConfigRoot,
      transcriptPath,
      resume: capability,
    } as RetainedHistoryRecord;
    const environment = new RealClaudeResumeFixtureEnvironment(
      realpathSync(home), canonicalCwd, canonicalConfigRoot, realpathSync(executable), sessionID,
    );
    const adapter = new ClaudeResumeAdapter(environment, async () => [], () => "authoritative");
    const selection = { kind: "provider" as const, executableRef: selectedExecutable };
    try {
      writeFileSync(transcriptPath, `${JSON.stringify({ sessionId: sessionID, cwd: canonicalCwd })}\n`);
      expect(adapter.validateRepair(record, selection).state).toBe("valid");
      writeFileSync(settingsFile, "{}\n");
      expect(adapter.validateRepair(record, { ...selection, settingsFileRef: settingsFile }).state).toBe("valid");
      writeFileSync(settingsFile, "not-json\n");
      expect(adapter.validateRepair(record, { ...selection, settingsFileRef: settingsFile }).state).toBe("unavailable");

      writeFileSync(transcriptPath, `${JSON.stringify({ sessionId: "88888888-8888-4888-8888-888888888888", cwd: canonicalCwd })}\n`);
      expect(adapter.validateRepair(record, selection).state).toBe("unavailable");
      writeFileSync(transcriptPath, "");
      expect(adapter.validateRepair(record, selection).state).toBe("unavailable");

      writeFileSync(transcriptPath, `${JSON.stringify({ sessionId: sessionID, cwd: canonicalCwd })}\n`);
      chmodSync(executable, 0o644);
      expect(adapter.validateRepair(record, selection).state).toBe("unavailable");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

describe("ResumeAttemptStore", () => {
  it("fails closed when no durable path or an unreadable journal is available", () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-resume-journal-"));
    const corrupt = path.join(root, "corrupt.json");
    writeFileSync(corrupt, "not-json\n");
    try {
      expect(new ResumeAttemptStore(undefined).claim("session", "canonical")).toMatchObject({
        state: "unavailable",
      });
      expect(new ResumeAttemptStore(corrupt).claim("session", "canonical")).toMatchObject({
        state: "unavailable",
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("initializes an absent journal and blocks a duplicate after reload", () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-resume-journal-"));
    const journal = path.join(root, "attempts.json");
    try {
      const first = new ResumeAttemptStore(journal, () => new Date("2026-10-21T18:02:00.000Z"));
      const claim = first.claim("session", "canonical");
      expect(claim.state).toBe("created");
      const second = new ResumeAttemptStore(journal, () => new Date("2026-10-21T18:03:00.000Z"));
      expect(second.claim("session", "canonical")).toMatchObject({ state: "blocked" });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
