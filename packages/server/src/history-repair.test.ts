import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { FakeNativeHelper } from "./native-helper.js";
import { NativeSessionControls } from "./session-controls.js";
import type { RetainedHistoryResumeCapability } from "./retained-history.js";
import { SessionRepository, type DiscoveredProviderSession, type ProviderAdapter } from "./sessions.js";

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
      validateRepair: (_record, selection) => selection.executableRef === executable
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
});
