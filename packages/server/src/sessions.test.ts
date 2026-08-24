import { mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  SessionRepository,
  type DiscoveredProviderSession,
  type HookSessionEvent,
  type ProviderAdapter,
} from "./sessions.js";

const live: DiscoveredProviderSession = {
  id: "pi-1",
  provider: "pi",
  title: "Migration",
  subtitle: "Active Pi session",
  cwd: "/Users/me/Codes/agent-visor",
  owner: "Ghostty",
  section: "working",
  updatedAt: "2026-08-22T08:00:00.000Z",
  canOpenOwner: true,
  canEnterChat: true,
  authority: 1,
};

class FakeProvider implements ProviderAdapter {
  readonly id = "pi";
  sessions = [live];
  hook?: HookSessionEvent;

  noteHook(event: HookSessionEvent): void {
    this.hook = structuredClone(event);
  }

  async discover(): Promise<DiscoveredProviderSession[]> {
    return structuredClone(this.sessions);
  }
}

describe("SessionRepository", () => {
  it("keeps a stable revision while provider data is unchanged", async () => {
    const provider = new FakeProvider();
    const repository = new SessionRepository([provider]);

    const first = await repository.refresh();
    const second = await repository.refresh();

    expect(first.revision).toBe(1);
    expect(second).toEqual(first);
  });

  it("increments once when normalized session content changes", async () => {
    const provider = new FakeProvider();
    const repository = new SessionRepository([provider]);
    await repository.refresh();
    provider.sessions[0] = { ...live, section: "ready", subtitle: "Ready" };

    const changed = await repository.refresh();

    expect(changed.revision).toBe(2);
    expect(changed.sessions[0]?.section).toBe("ready");
  });

  it("preserves the last provider snapshot after a transient read failure", async () => {
    const provider = new FakeProvider();
    const repository = new SessionRepository([provider]);
    const first = await repository.refresh();
    provider.discover = async () => { throw new Error("mid-write read"); };

    expect(await repository.refresh()).toEqual(first);
  });

  it("applies hook phases without replacing provider-specific names", async () => {
    const provider = new FakeProvider();
    const repository = new SessionRepository([provider]);
    await repository.refresh();

    const changed = repository.applyHook({
      sessionId: "pi-1",
      cwd: live.cwd,
      provider: "pi",
      event: "PermissionRequest",
      status: "waiting_for_approval",
      receivedAt: "2026-08-22T08:01:00.000Z",
      pid: 43,
      tty: "ttys001",
      sessionFile: "/Users/me/.pi/agent/sessions/pi-1.jsonl",
    });

    expect(provider.hook).toMatchObject({
      sessionId: "pi-1",
      pid: 43,
      tty: "ttys001",
    });
    repository.applyHook({
      sessionId: "pi-1",
      cwd: live.cwd,
      provider: "pi",
      event: "SessionEnd",
      status: "ended",
      receivedAt: "2026-08-22T08:00:30.000Z",
    });
    expect(provider.hook).toMatchObject({ pid: 43, tty: "ttys001" });
    expect(changed.sessions[0]).toMatchObject({
      title: "Migration",
      section: "needs_you",
      subtitle: "Approval required",
    });
  });

  it("keeps repeated idle heartbeats phase-neutral for an already Ready Pi session", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{ ...live, section: "ready", updatedAt: "2026-08-22T08:00:00.000Z" }];
    const repository = new SessionRepository([provider]);
    const before = await repository.refresh();

    const after = repository.applyHook(heartbeat({
      receivedAt: "2026-08-22T09:00:00.000Z",
      isIdle: true,
    }));

    expect(provider.hook?.event).toBe("SessionHeartbeat");
    expect(after).toEqual(before);
  });

  it("keeps busy Pi heartbeats phase-neutral", async () => {
    const provider = new FakeProvider();
    const repository = new SessionRepository([provider]);
    const before = await repository.refresh();

    const after = repository.applyHook(heartbeat({
      receivedAt: "2026-08-22T09:00:00.000Z",
      isIdle: false,
    }));

    expect(after).toEqual(before);
  });

  it("clears old stuck Pi work without announcing late attention", async () => {
    const transcript = temporaryTranscript("2026-08-22T08:00:00.000Z");
    try {
      const provider = new FakeProvider();
      const repository = new SessionRepository([provider]);
      await repository.refresh();

      const changed = repository.applyHook(heartbeat({
        receivedAt: "2026-08-22T08:20:00.000Z",
        isIdle: true,
        sessionFile: transcript.path,
      }));

      expect(changed.sessions[0]).toMatchObject({
        section: "history",
        updatedAt: "2026-08-22T08:00:00.000Z",
      });
    } finally {
      transcript.remove();
    }
  });

  it("repairs a fresh dropped Pi completion once", async () => {
    const transcript = temporaryTranscript("2026-08-22T08:00:50.000Z");
    try {
      const provider = new FakeProvider();
      const repository = new SessionRepository([provider]);
      await repository.refresh();
      const first = repository.applyHook(heartbeat({
        receivedAt: "2026-08-22T08:01:00.000Z",
        isIdle: true,
        sessionFile: transcript.path,
      }));
      const repeated = repository.applyHook(heartbeat({
        receivedAt: "2026-08-22T08:01:10.000Z",
        isIdle: true,
        sessionFile: transcript.path,
      }));

      expect(first.sessions[0]).toMatchObject({
        section: "ready",
        updatedAt: "2026-08-22T08:01:00.000Z",
      });
      expect(repeated).toEqual(first);
    } finally {
      transcript.remove();
    }
  });

  it("reattaches a heartbeat-only Pi session as History", () => {
    const transcript = temporaryTranscript("2026-08-22T08:00:00.000Z");
    try {
      const repository = new SessionRepository([]);
      const snapshot = repository.applyHook(heartbeat({
        receivedAt: "2026-08-22T10:00:00.000Z",
        isIdle: true,
        sessionFile: transcript.path,
      }));

      expect(snapshot.sessions[0]).toMatchObject({
        section: "history",
        updatedAt: "2026-08-22T08:00:00.000Z",
      });
    } finally {
      transcript.remove();
    }
  });

  it("ignores a same-process heartbeat after Pi ended", () => {
    const provider = new FakeProvider();
    provider.sessions = [];
    const repository = new SessionRepository([provider]);
    const ended = repository.applyHook({
      ...heartbeat(),
      event: "SessionEnd",
      status: "ended",
    });

    const repeated = repository.applyHook(heartbeat({
      receivedAt: "2026-08-22T08:02:00.000Z",
      isIdle: true,
    }));

    expect(provider.hook?.event).toBe("SessionEnd");
    expect(repeated).toEqual(ended);
  });

  it("ignores a Pi heartbeat without a liveness PID", () => {
    const repository = new SessionRepository([]);

    const snapshot = repository.applyHook(heartbeat({ pid: undefined, tty: undefined }));

    expect(snapshot.sessions).toEqual([]);
  });

  it("creates an Auggie row from its hook-only integration", () => {
    const repository = new SessionRepository([]);

    const snapshot = repository.applyHook({
      sessionId: "auggie-1",
      cwd: live.cwd,
      provider: "auggie",
      event: "SessionStart",
      status: "working",
      receivedAt: "2026-08-22T08:01:00.000Z",
    });

    expect(snapshot.sessions[0]).toMatchObject({
      id: "auggie-1",
      source: "Auggie",
      section: "working",
      canEnterChat: false,
    });
  });

  it("presents and answers Claude questions through the pending hook", async () => {
    const repository = new SessionRepository([]);
    repository.applyHook({
      sessionId: "claude-1",
      cwd: live.cwd,
      provider: "claude_code",
      event: "PermissionRequest",
      status: "waiting_for_approval",
      receivedAt: "2026-08-22T08:01:00.000Z",
      expectsResponse: true,
      tool: "AskUserQuestion",
      toolUseId: "question-1",
      toolInput: {
        questions: [{
          header: "Strategy",
          question: "Which strategy?",
          options: [{ label: "Minimal" }, { label: "Complete" }],
          multiSelect: false,
        }],
      },
    });
    let response: unknown;
    repository.registerHookResponder("claude-1", "question-1", (value) => { response = value; });

    expect((await repository.chatPage("claude-1")).pendingAction).toEqual({
      type: "question",
      toolUseId: "question-1",
      questions: [{
        id: "Which strategy?",
        question: "Which strategy?",
        choices: ["Minimal", "Complete"],
        multiple: false,
      }],
    });
    expect(await repository.chatAction({
      type: "respond_chat",
      id: "answer-1",
      sessionId: "claude-1",
      toolUseId: "question-1",
      decision: "answer",
      answers: { "Which strategy?": "Minimal" },
    })).toBeUndefined();
    expect(response).toMatchObject({
      decision: "allow",
      updated_input: { answers: { "Which strategy?": "Minimal" } },
    });
  });

  it("routes external Codex approvals through the shared Chat action", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{ ...live, provider: "codex", chatPath: "/tmp/codex.jsonl" }];
    const repository = new SessionRepository([provider]);
    await repository.refresh();
    let decision = "";
    repository.registerExternalAction("pi-1", {
      type: "approval", toolUseId: "codex-command-1", toolName: "Command",
      input: { command: "npm test" }, canPersist: true,
    }, async (message) => { decision = message.decision; });

    expect((await repository.chatPage("pi-1")).pendingAction).toMatchObject({
      type: "approval", toolUseId: "codex-command-1",
    });
    expect(repository.current().sessions[0]?.section).toBe("needs_you");
    expect(await repository.chatAction({
      type: "respond_chat", id: "response-1", sessionId: "pi-1",
      toolUseId: "codex-command-1", decision: "allow_always",
    })).toBeUndefined();
    expect(decision).toBe("allow_always");
  });

  it("routes focus and Chat through provider-owned control metadata", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...live,
      chatPath: "/tmp/pi.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: { application: "Ghostty", tty: "ttys012", cwd: live.cwd },
      },
    }];
    const repository = new SessionRepository([provider]);
    const calls: string[] = [];
    repository.setControls({
      focus: async (session) => { calls.push(`focus:${session.id}`); },
      send: async (session, text) => { calls.push(`send:${session.id}:${text}`); },
    });
    await repository.refresh();

    expect(await repository.focusSession("pi-1")).toBeUndefined();
    expect(await repository.chatAction({
      type: "send_chat", id: "send-1", sessionId: "pi-1", text: "Continue", images: [],
    })).toBeUndefined();
    expect(calls).toEqual(["focus:pi-1", "send:pi-1:Continue"]);
  });

  it("lets an authoritative host replace a duplicate provider row", async () => {
    const pi = new FakeProvider();
    pi.sessions = [{
      ...live,
      chatPath: "/tmp/pi.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: { application: "Ghostty", tty: "ttys012", cwd: live.cwd },
      },
    }];
    const zed: ProviderAdapter = {
      id: "zed",
      async discover() {
        return [{
          ...live,
          title: "Zed-owned title",
          owner: "Zed",
          authority: 2,
          controlTarget: {
            kind: "application",
            target: { pid: 52, bundleIdentifier: "dev.zed.Zed" },
          },
        }];
      },
    };
    const repository = new SessionRepository([pi, zed]);

    const snapshot = await repository.refresh();

    expect(snapshot.sessions).toHaveLength(1);
    expect(snapshot.sessions[0]?.title).toBe("Zed-owned title");
    expect(snapshot.sessions[0]?.owner).toBe("Zed");
    expect(repository.chatRecord("pi-1")).toMatchObject({
      owner: "Zed",
      controlTarget: {
        kind: "application",
        target: { pid: 52, bundleIdentifier: "dev.zed.Zed" },
      },
    });
    expect(repository.chatRecord("pi-1")?.messageTransport).toBeUndefined();
  });
});

function heartbeat(overrides: Partial<HookSessionEvent> = {}): HookSessionEvent {
  return {
    sessionId: "pi-1",
    cwd: live.cwd,
    provider: "pi",
    event: "SessionHeartbeat",
    status: "alive",
    receivedAt: "2026-08-22T08:01:00.000Z",
    pid: 43,
    tty: "ttys001",
    ...overrides,
  };
}

function temporaryTranscript(modifiedAt: string): { path: string; remove(): void } {
  const directory = mkdtempSync(path.join(tmpdir(), "agent-visor-heartbeat-"));
  const transcriptPath = path.join(directory, "session.jsonl");
  writeFileSync(transcriptPath, "{}\n");
  const date = new Date(modifiedAt);
  utimesSync(transcriptPath, date, date);
  return {
    path: transcriptPath,
    remove: () => rmSync(directory, { recursive: true, force: true }),
  };
}
