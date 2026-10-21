import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import type { NativeHelperGhosttyResumeDispatch, NativeHelperGhosttyTerminalView } from "@agent-visor/protocol";
import type { RetainedHistoryRecord } from "./retained-history.js";
import { ClaudeResumeAdapter } from "./providers/claude-resume.js";
import type { ProviderEnvironment } from "./providers/environment.js";
import { processInstanceToken } from "./providers/shared.js";

describe("ClaudeResumeAdapter", () => {
  it("rejects a transcript file that is not the exact UUID and cwd project record", () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-claude-resume-contract-"));
    const home = path.join(root, "home");
    const cwd = path.join(home, "project");
    const configRoot = path.join(home, ".claude");
    const executable = path.join(home, ".local", "share", "claude", "versions", "2.1.296");
    const sessionID = "11111111-1111-4111-8111-111111111111";
    const wrongTranscript = path.join(root, "wrong", `${sessionID}.jsonl`);
    mkdirSync(cwd, { recursive: true });
    mkdirSync(configRoot, { recursive: true });
    mkdirSync(path.dirname(executable), { recursive: true });
    mkdirSync(path.dirname(wrongTranscript), { recursive: true });
    writeFileSync(executable, "#!/bin/sh\n", { mode: 0o755 });
    writeFileSync(wrongTranscript, "{}\n");
    const executableRef = realpathSync(executable);
    const canonicalCwd = realpathSync(cwd);
    const canonicalConfigRoot = realpathSync(configRoot);
    const canonicalWrongTranscript = realpathSync(wrongTranscript);

    const record: RetainedHistoryRecord = {
      schemaVersion: 1,
      id: sessionID,
      canonicalId: sessionID,
      provider: "claude_code",
      title: "Exact transcript contract",
      subtitle: "Closed Claude conversation",
      project: "project",
      owner: "Ghostty",
      host: "Ghostty",
      cwd: canonicalCwd,
      transcriptPath: canonicalWrongTranscript,
      resume: {
        version: 1,
        provider: "claude_code",
        host: "Ghostty",
        executableRef,
        configRootRef: canonicalConfigRoot,
        profileState: "verified_absent",
        overrideNames: [],
        provenanceObservedAt: "2026-10-21T18:00:00.000Z",
      },
      updatedAt: "2026-10-21T18:00:00.000Z",
      observedAt: "2026-10-21T18:00:00.000Z",
      closedAt: "2026-10-21T18:01:00.000Z",
    };
    const environment = { home, now: () => new Date("2026-10-21T18:02:00.000Z") } as unknown as ProviderEnvironment;
    const adapter = new ClaudeResumeAdapter(environment, async () => [], () => "authoritative");

    try {
      expect(adapter.resumeTarget(record, "attempt-1", "0123456789abcdef0123456789abcdef")).toMatchObject({
        state: "unavailable",
      });
      expect(adapter.resumeTarget({ ...record, host: "cmux" }, "attempt-1", "0123456789abcdef0123456789abcdef")).toMatchObject({
        state: "unavailable",
        reason: "This Claude session was not observed in a supported Ghostty host.",
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("keeps resume unavailable when authoritative liveness still has a possible owner", async () => {
    const sessionID = "22222222-2222-4222-8222-222222222222";
    const environment = {
      home: "/tmp/agent-visor-claude-home",
      now: () => new Date("2026-10-21T18:02:00.000Z"),
      processesFreshInventory: async () => ({
        state: "authoritative" as const,
        observedAt: "2026-10-21T18:02:00.000Z",
        processes: [{
          pid: 4242,
          parentPID: 1,
          tty: "ttys42",
          command: "/usr/local/bin/claude",
          arguments: `/usr/local/bin/claude --resume ${sessionID}`,
        }],
      }),
    } as unknown as ProviderEnvironment;
    const adapter = new ClaudeResumeAdapter(environment, async () => [], () => "authoritative");
    const result = await adapter.resumeLiveness({
      schemaVersion: 1,
      id: sessionID,
      canonicalId: sessionID,
      provider: "claude_code",
      title: "Possible owner",
      subtitle: "Closed Claude conversation",
      project: "project",
      owner: "Ghostty",
      host: "Ghostty",
      cwd: "/tmp/project",
      updatedAt: "2026-10-21T18:00:00.000Z",
      observedAt: "2026-10-21T18:00:00.000Z",
      closedAt: "2026-10-21T18:01:00.000Z",
    });

    expect(result).toMatchObject({ state: "unknown" });
  });

  it("links the exact dispatched surface when another Ghostty view shares its cwd", async () => {
    const sessionID = "33333333-3333-4333-8333-333333333333";
    const cwd = "/tmp/agent-visor-claude-surface";
    const now = new Date("2026-10-21T18:02:00.000Z");
    const providerToken = processInstanceToken(5000, now)!;
    const ghosttyToken = processInstanceToken(7000, now)!;
    const capability = {
      version: 1 as const,
      provider: "claude_code" as const,
      host: "Ghostty" as const,
      executableRef: "/usr/local/bin/claude",
      configRootRef: "/tmp/agent-visor-claude-config",
      profileState: "verified_absent" as const,
      overrideNames: [],
      provenanceObservedAt: now.toISOString(),
    };
    const record: RetainedHistoryRecord = {
      schemaVersion: 1,
      id: sessionID,
      canonicalId: sessionID,
      provider: "claude_code",
      title: "Surface binding",
      subtitle: "Closed Claude conversation",
      project: "surface",
      owner: "Ghostty",
      host: "Ghostty",
      cwd,
      resume: capability,
      updatedAt: now.toISOString(),
      observedAt: now.toISOString(),
      closedAt: now.toISOString(),
    };
    const session = {
      id: sessionID,
      provider: "claude_code" as const,
      cwd,
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
          cwd,
        },
      },
      historyIdentity: { verified: true, resume: capability },
    };
    const views: NativeHelperGhosttyTerminalView[] = [
      {
        applicationPID: 7000,
        processStartToken: ghosttyToken,
        terminalId: "created-terminal",
        title: "Surface binding",
        cwd,
        viewMode: "conversation",
      },
      {
        applicationPID: 7000,
        processStartToken: ghosttyToken,
        terminalId: "other-terminal",
        title: "Another Claude",
        cwd,
        viewMode: "conversation",
      },
    ];
    const dispatch: NativeHelperGhosttyResumeDispatch = {
      attemptId: "attempt-surface",
      provider: "claude_code",
      sessionId: sessionID,
      applicationPID: 7000,
      processStartToken: ghosttyToken,
      windowId: "window",
      tabId: "tab",
      terminalId: "created-terminal",
      nonce: "0123456789abcdef0123456789abcdef",
      dispatchedAt: now.toISOString(),
    };
    let observedNonce = dispatch.nonce;
    const environment = {
      home: "/tmp/agent-visor-claude-home",
      now: () => now,
      processesFreshInventory: async () => ({
        state: "authoritative" as const,
        observedAt: now.toISOString(),
        processes: [
          { pid: 7000, parentPID: 1, processStartToken: ghosttyToken, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
          { pid: 5000, parentPID: 7000, processStartToken: providerToken, tty: "ttys42", command: "/usr/local/bin/claude", arguments: `claude --resume ${sessionID}` },
        ],
      }),
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
      ghosttyTerminalViews: async () => views,
    } as unknown as ProviderEnvironment;
    const adapter = new ClaudeResumeAdapter(environment, async () => [session], () => "authoritative");

    const result = await adapter.reconcileResume(record, dispatch);

    expect(result).toMatchObject({
      state: "matched",
      sessionId: sessionID,
      terminal: { terminalId: "created-terminal" },
    });

    observedNonce = "ffffffffffffffffffffffffffffffff";
    const wrongNonce = await adapter.reconcileResume(record, dispatch);
    expect(wrongNonce).toMatchObject({ state: "unknown" });
  });
});
