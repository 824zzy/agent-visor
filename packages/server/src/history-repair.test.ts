import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { FakeNativeHelper } from "./native-helper.js";
import { NativeSessionControls } from "./session-controls.js";
import type { RetainedHistoryResumeCapability } from "./retained-history.js";
import { SessionRepository, type DiscoveredProviderSession, type ProviderAdapter } from "./sessions.js";
import { ClaudeProvider } from "./providers/claude.js";
import { LiveProviderEnvironment } from "./providers/environment.js";

const sessionID = "11111111-1111-4111-8111-111111111111";

describe("retained history provider repair", () => {
  it("validates and accepts one record without launching, then survives restart", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-history-repair-"));
    const historyPath = path.join(root, "retained-history.json");
    const executable = path.join(root, "bin", "claude");
    const configRoot = path.join(root, ".claude");
    const settingsFile = path.join(configRoot, "settings.json");
    const cwd = path.join(root, "project");
    const transcriptPath = path.join(configRoot, "projects", "-tmp-agent-visor-history-repair-project", `${sessionID}.jsonl`);
    mkdirSync(path.dirname(executable), { recursive: true });
    mkdirSync(configRoot, { recursive: true });
    mkdirSync(cwd, { recursive: true });
    mkdirSync(path.dirname(transcriptPath), { recursive: true });
    writeFileSync(executable, "#!/bin/sh\n", { mode: 0o755 });
    writeFileSync(settingsFile, "{}\n");
    writeFileSync(transcriptPath, `${JSON.stringify({ sessionId: sessionID, cwd })}\n`);
    const capability: RetainedHistoryResumeCapability = {
      version: 1,
      provider: "claude_code",
      host: "Ghostty",
      executableRef: path.join(root, "missing-claude"),
      configRootRef: configRoot,
      settingsFileRef: settingsFile,
      profileState: "verified_absent",
      overrideNames: [],
      provenanceObservedAt: "2026-10-21T18:00:00.000Z",
    };
    let open = true;
    const session: DiscoveredProviderSession = {
      id: sessionID,
      provider: "claude_code",
      title: "Repair me",
      subtitle: "Closed conversation",
      project: "project",
      cwd,
      owner: "Ghostty",
      host: "Ghostty",
      section: "ready",
      conversationState: "open",
      updatedAt: "2026-10-21T18:00:00.000Z",
      canOpenOwner: true,
      canEnterChat: false,
      chatPath: transcriptPath,
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 4242,
          processStartToken: "repair-fixture",
          tty: "ttys42",
          cwd,
        },
      },
      historyIdentity: {
        verified: true,
        current: true,
        canonicalId: sessionID,
        host: "Ghostty",
        configHome: configRoot,
        resume: capability,
        resumeUnavailableReason: "missing_executable",
      },
    };
    const provider: ProviderAdapter = {
      id: "claude_code",
      discover: async () => open ? [structuredClone(session)] : [],
      validateRepair: (_record, selection) => selection.kind === "provider"
        && selection.executableRef === executable
        ? { state: "valid", capability: { ...capability, executableRef: executable } }
        : { state: "unavailable", reason: "The selected Claude executable is invalid." },
    };
    const repository = new SessionRepository([provider], { retainedHistoryPath: historyPath });
    const helper = new FakeNativeHelper();
    repository.setControls(new NativeSessionControls(helper));
    try {
      await repository.refresh();
      open = false;
      await repository.refresh();
      const before = readFileSync(historyPath, "utf8");
      await expect(repository.repairHistorySession(sessionID, null)).resolves.toMatchObject({ state: "cancelled" });
      expect(readFileSync(historyPath, "utf8")).toBe(before);
      await expect(repository.repairHistorySession(sessionID, { kind: "provider" })).resolves.toMatchObject({
        state: "rejected",
      });
      expect(readFileSync(historyPath, "utf8")).toBe(before);
      await expect(repository.repairHistorySession(sessionID, {
        kind: "provider",
        executableRef: executable,
      })).resolves.toMatchObject({ state: "accepted" });
      expect((helper as FakeNativeHelper & { ghosttyResumeRequests: unknown[] }).ghosttyResumeRequests)
        .toHaveLength(0);
      const restarted = new SessionRepository([provider], { retainedHistoryPath: historyPath });
      expect(restarted.historyPage().sessions[0]).toMatchObject({
        id: sessionID,
        resumeState: "eligible",
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("rejects a changed Claude folder with a concrete unsupported-relocation reason", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-claude-working-directory-"));
    const historyPath = path.join(root, "retained-history.json");
    const home = path.join(root, "home");
    const configRoot = path.join(home, ".claude");
    const executable = path.join(home, ".local", "share", "claude", "versions", "2.1.296");
    const oldCwd = path.join(root, "old-project");
    const selectedCwd = path.join(root, "new-project");
    mkdirSync(path.dirname(executable), { recursive: true });
    mkdirSync(configRoot, { recursive: true });
    mkdirSync(selectedCwd, { recursive: true });
    writeFileSync(executable, "#!/bin/sh\n", { mode: 0o755 });
    const observedAt = "2026-10-21T19:00:00.000Z";
    const capability = {
      version: 1 as const,
      provider: "claude_code" as const,
      host: "Ghostty" as const,
      executableRef: executable,
      configRootRef: configRoot,
      profileState: "verified_absent" as const,
      overrideNames: [],
      provenanceObservedAt: observedAt,
    };
    const record = {
      schemaVersion: 1 as const,
      id: sessionID,
      canonicalId: sessionID,
      title: "Moved Claude conversation",
      subtitle: "Closed conversation",
      project: "old-project",
      owner: "Ghostty",
      host: "Ghostty" as const,
      cwd: oldCwd,
      configHome: configRoot,
      resume: capability,
      resumeUnavailableReason: "missing_working_directory" as const,
      updatedAt: observedAt,
      observedAt,
      closedAt: observedAt,
      provider: "claude_code" as const,
    };
    writeFileSync(historyPath, JSON.stringify({ schemaVersion: 1, records: [record], tombstones: [] }));
    const environment = new LiveProviderEnvironment(home, { now: () => new Date(observedAt) });
    const provider = new ClaudeProvider(environment);
    const repository = new SessionRepository([provider], {
      now: () => new Date(observedAt),
      retainedHistoryPath: historyPath,
    });
    const helper = new FakeNativeHelper();
    repository.setControls(new NativeSessionControls(helper));
    const before = readFileSync(historyPath, "utf8");
    try {
      expect(repository.historyPage().sessions).toContainEqual(expect.objectContaining({
        id: sessionID,
        repairKind: "working_directory",
      }));
      await expect(repository.repairHistorySession(sessionID, {
        kind: "working_directory",
        cwd: selectedCwd,
      })).resolves.toMatchObject({
        state: "rejected",
        reason: "Claude Code cannot prove that this saved conversation belongs to the selected folder; the provider does not expose a supported relocation mapping.",
      });
      expect(readFileSync(historyPath, "utf8")).toBe(before);
      expect(helper.ghosttyResumeRequests).toHaveLength(0);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
