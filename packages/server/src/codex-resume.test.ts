import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import type { NativeHelperGhosttyResumeDispatch, NativeHelperGhosttyTerminalView } from "@agent-visor/protocol";
import type { RetainedHistoryRecord } from "./retained-history.js";
import { FakeNativeHelper } from "./native-helper.js";
import { NativeSessionControls } from "./session-controls.js";
import { SessionRepository, type DiscoveredProviderSession, type ProviderAdapter } from "./sessions.js";
import { CodexResumeAdapter } from "./providers/codex-resume.js";
import type { ProviderEnvironment } from "./providers/environment.js";

const threadID = "019f3931-ec11-7f31-8400-1c8624aa9e4d";

describe("Codex CLI closed-terminal resume", () => {
  it("resumes a retained Codex row through the public repository action", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-codex-resume-red-"));
    const home = path.join(root, ".codex");
    const cwd = path.join(root, "project");
    const executable = path.join(root, "codex");
    const historyPath = path.join(root, "retained-history.json");
    mkdirSync(home, { recursive: true });
    mkdirSync(cwd, { recursive: true });
    const canonicalHome = realpathSync(home);
    const canonicalCwd = realpathSync(cwd);
    mkdirSync(path.dirname(executable), { recursive: true });
    writeFileSync(executable, "#!/bin/sh\n", { mode: 0o755 });
    const executableRef = realpathSync(executable);
    const transcriptPath = path.join(canonicalHome, "sessions", `${threadID}.jsonl`);
    mkdirSync(path.dirname(transcriptPath), { recursive: true });
    writeFileSync(transcriptPath,
      `${JSON.stringify({ type: "session_meta", payload: { id: threadID, originator: "codex-tui" } })}\n`);
    const canonicalId = `codex:${"a".repeat(64)}:${threadID}`;
    const now = "2026-10-21T19:00:00.000Z";
    const resume = {
      version: 1 as const,
      provider: "codex_cli" as const,
      host: "Ghostty" as const,
      executableRef,
      configRootRef: canonicalHome,
      profileState: "verified_absent" as const,
      overrideNames: [],
      provenanceObservedAt: now,
    };
    const terminal: NativeHelperGhosttyTerminalView = {
      applicationPID: 7001,
      processStartToken: "fixture-ghostty-start",
      terminalId: "codex-resumed-terminal",
      title: "Codex retained row",
      cwd: canonicalCwd,
      viewMode: "conversation",
    };
    let current = true;
    const observed: DiscoveredProviderSession = {
      id: canonicalId,
      provider: "codex",
      title: "Codex retained row",
      subtitle: "Codex CLI session",
      project: "project",
      cwd: canonicalCwd,
      owner: "Codex CLI",
      section: "ready",
      updatedAt: now,
      canOpenOwner: true,
      canEnterChat: true,
      conversationState: "open",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 5001,
          processStartToken: "fixture-codex-start",
          tty: "ttys-codex",
          cwd: canonicalCwd,
        },
      },
      chatPath: realpathSync(transcriptPath),
      historyIdentity: {
        verified: true,
        current: true,
        canonicalId,
        host: "Ghostty",
        configHome: canonicalHome,
        resume: resume as never,
      },
    };
    const provider = {
      id: "codex" as const,
      discover: async () => current ? [structuredClone(observed)] : [],
      resumeLiveness: async () => ({ state: "stopped" as const }),
      resumeTarget: (_record: unknown, attemptId: string, nonce: string) => ({
        state: "eligible" as const,
        target: {
          attemptId,
          provider: "codex_cli",
          sessionId: threadID,
          cwd: canonicalCwd,
          executable: executableRef,
          configRoot: canonicalHome,
          profileState: "verified_absent",
          nonce,
        },
      }),
      reconcileResume: async () => ({
        state: "matched" as const,
        sessionId: canonicalId,
        terminal,
      }),
    } as unknown as ProviderAdapter;
    const helper = new FakeNativeHelper();
    helper.openGhosttyResume = async (target) => {
      helper.ghosttyResumeRequests.push(structuredClone(target));
      const dispatch: NativeHelperGhosttyResumeDispatch = {
        attemptId: target.attemptId,
        provider: target.provider,
        sessionId: target.sessionId,
        applicationPID: terminal.applicationPID,
        processStartToken: terminal.processStartToken,
        windowId: "codex-resumed-window",
        tabId: "codex-resumed-tab",
        terminalId: terminal.terminalId,
        nonce: target.nonce,
        dispatchedAt: now,
      } as NativeHelperGhosttyResumeDispatch;
      helper.ghosttyResumeDispatches.push(structuredClone(dispatch));
      return dispatch;
    };

    try {
      const initial = new SessionRepository([provider], { retainedHistoryPath: historyPath });
      initial.setControls(new NativeSessionControls(helper));
      await initial.refresh();
      current = false;
      await initial.refresh();

      const restarted = new SessionRepository([provider], { retainedHistoryPath: historyPath });
      restarted.setControls(new NativeSessionControls(helper));
      await restarted.refresh();
      expect(restarted.historyPage().sessions).toContainEqual(expect.objectContaining({
        id: canonicalId,
        source: "Codex",
        resumeState: "eligible",
      }));

      await expect(restarted.resumeSession(canonicalId)).resolves.toMatchObject({
        state: "matched",
        sessionId: canonicalId,
      });
      expect(helper.ghosttyResumeRequests).toHaveLength(1);
      expect(helper.ghosttyResumeRequests[0]).toMatchObject({
        provider: "codex_cli",
        sessionId: threadID,
        cwd: canonicalCwd,
        configRoot: canonicalHome,
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("builds a full UUIDv7 target from the selected home and profile", () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-codex-target-"));
    const home = path.join(root, ".codex-work");
    const cwd = path.join(root, "project");
    const executable = path.join(root, "codex");
    const thread = "019f3931-ec11-7f31-8400-1c8624aa9e4d";
    mkdirSync(path.join(home, "sessions"), { recursive: true });
    mkdirSync(cwd, { recursive: true });
    mkdirSync(path.dirname(executable), { recursive: true });
    writeFileSync(executable, "#!/bin/sh\n", { mode: 0o755 });
    writeFileSync(path.join(home, "work.config.toml"), "profile = true\n");
    const canonicalHome = realpathSync(home);
    const canonicalCwd = realpathSync(cwd);
    const executableRef = realpathSync(executable);
    const transcriptPath = path.join(canonicalHome, "sessions", `${thread}.jsonl`);
    writeFileSync(transcriptPath,
      `${JSON.stringify({ type: "session_meta", payload: { id: thread, originator: "codex-tui" } })}\n`);
    const capability = {
      version: 1 as const,
      provider: "codex_cli" as const,
      host: "Ghostty" as const,
      executableRef,
      configRootRef: canonicalHome,
      profileRef: "work",
      profileState: "present" as const,
      overrideNames: [],
      provenanceObservedAt: "2026-10-21T19:00:00.000Z",
    };
    const record: RetainedHistoryRecord = {
      schemaVersion: 1,
      id: `codex:${"a".repeat(64)}:${thread}`,
      canonicalId: `codex:${"a".repeat(64)}:${thread}`,
      provider: "codex",
      title: "Codex",
      subtitle: "Closed Codex CLI",
      project: "project",
      owner: "Codex CLI",
      host: "Ghostty",
      cwd: canonicalCwd,
      configHome: canonicalHome,
      transcriptPath,
      resume: capability,
      updatedAt: capability.provenanceObservedAt,
      observedAt: capability.provenanceObservedAt,
      closedAt: capability.provenanceObservedAt,
    };
    const adapter = new CodexResumeAdapter(
      { home: root, now: () => new Date(capability.provenanceObservedAt) } as unknown as ProviderEnvironment,
      async () => [],
      () => "authoritative",
    );
    try {
      expect(adapter.resumeTarget(record, "attempt", "0123456789abcdef0123456789abcdef")).toMatchObject({
        state: "eligible",
        target: {
          provider: "codex_cli",
          sessionId: thread,
          cwd: canonicalCwd,
          executable: executableRef,
          configRoot: canonicalHome,
          profileRef: "work",
          profileState: "present",
        },
      });
      expect(adapter.resumeTarget({ ...record, configHome: path.join(root, "wrong") }, "attempt", "0123456789abcdef0123456789abcdef")).toMatchObject({
        state: "unavailable",
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("rejects a retained Codex row when any provider override name was captured", () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-codex-override-"));
    const home = path.join(root, ".codex");
    const cwd = path.join(root, "project");
    const executable = path.join(root, "codex");
    mkdirSync(path.join(home, "sessions"), { recursive: true });
    mkdirSync(cwd, { recursive: true });
    writeFileSync(executable, "#!/bin/sh\n", { mode: 0o755 });
    const canonicalHome = realpathSync(home);
    const canonicalCwd = realpathSync(cwd);
    const executableRef = realpathSync(executable);
    const transcriptPath = path.join(canonicalHome, "sessions", `${threadID}.jsonl`);
    writeFileSync(transcriptPath, `${JSON.stringify({ type: "session_meta", payload: { id: threadID, originator: "codex-tui" } })}\n`);
    const observedAt = "2026-10-21T19:00:00.000Z";
    const record: RetainedHistoryRecord = {
      schemaVersion: 1,
      id: `codex:${"a".repeat(64)}:${threadID}`,
      canonicalId: `codex:${"a".repeat(64)}:${threadID}`,
      provider: "codex",
      title: "Codex",
      subtitle: "Closed Codex CLI",
      project: "project",
      owner: "Codex CLI",
      host: "Ghostty",
      cwd: canonicalCwd,
      configHome: canonicalHome,
      transcriptPath,
      resume: {
        version: 1,
        provider: "codex_cli",
        host: "Ghostty",
        executableRef,
        configRootRef: canonicalHome,
        profileState: "verified_absent",
        overrideNames: ["OPENAI_BASE_URL"],
        provenanceObservedAt: observedAt,
      },
      updatedAt: observedAt,
      observedAt,
      closedAt: observedAt,
    };
    const adapter = new CodexResumeAdapter(
      { home: root, now: () => new Date(observedAt) } as unknown as ProviderEnvironment,
      async () => [],
      () => "authoritative",
    );
    try {
      expect(adapter.resumeTarget(record, "attempt", "0123456789abcdef0123456789abcdef")).toMatchObject({
        state: "unavailable",
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("accepts a real Codex rollout filename only when bounded metadata proves its UUID", () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-codex-rollout-"));
    const home = path.join(root, ".codex");
    const cwd = path.join(root, "project");
    const executable = path.join(root, "codex");
    mkdirSync(path.join(home, "sessions", "2026", "10", "21"), { recursive: true });
    mkdirSync(cwd, { recursive: true });
    writeFileSync(executable, "#!/bin/sh\n", { mode: 0o755 });
    const canonicalHome = realpathSync(home);
    const canonicalCwd = realpathSync(cwd);
    const executableRef = realpathSync(executable);
    const transcriptPath = path.join(canonicalHome, "sessions", "2026", "10", "21",
      `rollout-20261021T190000-${threadID}.jsonl`);
    writeFileSync(transcriptPath, `${JSON.stringify({ type: "session_meta", payload: { id: threadID, originator: "codex-tui" } })}\n`);
    const observedAt = "2026-10-21T19:00:00.000Z";
    const record: RetainedHistoryRecord = {
      schemaVersion: 1,
      id: `codex:${"a".repeat(64)}:${threadID}`,
      canonicalId: `codex:${"a".repeat(64)}:${threadID}`,
      provider: "codex",
      title: "Codex",
      subtitle: "Closed Codex CLI",
      project: "project",
      owner: "Codex CLI",
      host: "Ghostty",
      cwd: canonicalCwd,
      configHome: canonicalHome,
      transcriptPath,
      resume: {
        version: 1,
        provider: "codex_cli",
        host: "Ghostty",
        executableRef,
        configRootRef: canonicalHome,
        profileState: "verified_absent",
        overrideNames: [],
        provenanceObservedAt: observedAt,
      },
      updatedAt: observedAt,
      observedAt,
      closedAt: observedAt,
    };
    const adapter = new CodexResumeAdapter(
      { home: root, now: () => new Date(observedAt) } as unknown as ProviderEnvironment,
      async () => [],
      () => "authoritative",
    );
    try {
      expect(adapter.resumeTarget(record, "attempt", "0123456789abcdef0123456789abcdef")).toMatchObject({
        state: "eligible",
        target: { sessionId: threadID, configRoot: canonicalHome },
      });
      writeFileSync(transcriptPath,
        `${JSON.stringify({ type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111", originator: "codex-tui" } })}\n`);
      expect(adapter.resumeTarget(record, "attempt", "0123456789abcdef0123456789abcdef")).toMatchObject({
        state: "unavailable",
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("keeps modern Codex server liveness unknown when exact client identity is absent", async () => {
    const record: RetainedHistoryRecord = {
      schemaVersion: 1,
      id: "019f3931-ec11-7f31-8400-1c8624aa9e4d",
      canonicalId: "codex:native:019f3931-ec11-7f31-8400-1c8624aa9e4d",
      provider: "codex",
      title: "Modern server",
      subtitle: "Closed Codex CLI",
      project: "project",
      owner: "Codex CLI",
      host: "Ghostty",
      cwd: "/fixture/project",
      configHome: "/fixture/.codex",
      updatedAt: "2026-10-21T19:00:00.000Z",
      observedAt: "2026-10-21T19:00:00.000Z",
      closedAt: "2026-10-21T19:01:00.000Z",
    };
    const environment = {
      home: "/fixture",
      now: () => new Date("2026-10-21T19:02:00.000Z"),
      processesFreshInventory: async () => ({
        state: "authoritative" as const,
        observedAt: "2026-10-21T19:02:00.000Z",
        processes: [{ pid: 88, parentPID: 1, tty: "?", command: "/usr/local/bin/codex", arguments: "codex app-server --listen stdio://" }],
      }),
      cwd: async () => "/another/project",
      codexProcessHome: async () => "/fixture/.codex",
    } as unknown as ProviderEnvironment;
    const adapter = new CodexResumeAdapter(environment, async () => [], () => "authoritative");
    await expect(adapter.resumeLiveness(record)).resolves.toMatchObject({ state: "unknown" });
  });
});
