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
  requiresHook = false;

  noteHook(event: HookSessionEvent): void {
    this.hook = structuredClone(event);
  }

  async discover(): Promise<DiscoveredProviderSession[]> {
    return structuredClone(this.sessions.map((session) => this.requiresHook && !this.hook
      ? {
          ...session,
          owner: "Pi",
          canOpenOwner: false,
          controlTarget: undefined,
          messageTransport: undefined,
        }
      : session));
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

  it("does not publish Codex hooks without an authoritative thread", async () => {
    const repository = new SessionRepository([]);
    const sessionId = "01a03c62-72e0-78b0-8768-7d7d13167e6c";

    const snapshot = repository.applyHook({
      sessionId,
      cwd: "/Users/me/Codes",
      provider: "codex",
      event: "Stop",
      status: "waiting_for_input",
      receivedAt: "2026-08-25T21:46:38.000Z",
      pid: 40758,
    });

    expect(snapshot.sessions).toEqual([]);
    expect(await repository.focusSession(sessionId)).toBe(
      "Exact session focus is unavailable.",
    );
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

  it("returns only accepted exact Ghostty Pi restoration candidates", async () => {
    const transcript = temporaryTranscript("2026-08-22T08:00:00.000Z");
    const cwd = path.dirname(transcript.path);
    try {
      const provider = new FakeProvider();
      provider.sessions = [{
        ...live,
        cwd,
        chatPath: transcript.path,
        controlTarget: {
          kind: "terminal",
          target: { application: "Ghostty", tty: "ttys001", cwd },
        },
      }];
      const repository = new SessionRepository([provider]);
      await repository.refresh();

      repository.applyHook({
        sessionId: "pi-1",
        cwd,
        provider: "pi",
        event: "SessionHeartbeat",
        status: "alive",
        receivedAt: "2026-08-22T08:01:00.000Z",
        pid: 43,
        tty: "ttys001",
        sessionFile: transcript.path,
      });

      expect(repository.piRestorationUpdate()).toEqual({
        candidates: [{
          sessionId: "pi-1",
          sessionFile: transcript.path,
          cwd,
          sessionName: "Migration",
          pid: 43,
          tty: "ttys001",
        }],
        liveSessionIds: ["pi-1"],
        removeCandidateSessionIds: [],
        cleanTermination: false,
      });

      provider.sessions = [{
        ...live,
        cwd,
        owner: "iTerm2",
        chatPath: transcript.path,
        controlTarget: {
          kind: "terminal",
          target: { application: "iTerm2", tty: "ttys001", cwd },
        },
      }];
      await repository.refresh();
      expect(repository.piRestorationUpdate()).toEqual({
        candidates: [],
        liveSessionIds: ["pi-1"],
        removeCandidateSessionIds: ["pi-1"],
        cleanTermination: false,
      });

      repository.applyHook({
        sessionId: "pi-1",
        cwd,
        provider: "pi",
        event: "SessionEnd",
        status: "ended",
        receivedAt: "2026-08-22T08:02:00.000Z",
      });
      expect(repository.piRestorationUpdate()).toEqual({
        candidates: [],
        liveSessionIds: [],
        removeCandidateSessionIds: ["pi-1"],
        cleanTermination: false,
      });
    } finally {
      transcript.remove();
    }
  });

  it("removes restoration authority when the exact session file disappears", async () => {
    const transcript = temporaryTranscript("2026-08-22T08:00:00.000Z");
    const cwd = path.dirname(transcript.path);
    const provider = new FakeProvider();
    provider.sessions = [{
      ...live,
      cwd,
      chatPath: transcript.path,
      controlTarget: {
        kind: "terminal",
        target: { application: "Ghostty", tty: "ttys001", cwd },
      },
    }];
    const repository = new SessionRepository([provider]);
    await repository.refresh();
    repository.applyHook(heartbeat({ cwd, sessionFile: transcript.path }));

    transcript.remove();

    expect(repository.piRestorationUpdate()).toMatchObject({
      candidates: [],
      liveSessionIds: ["pi-1"],
      removeCandidateSessionIds: ["pi-1"],
    });
  });

  it("publishes phase-neutral Pi restoration changes", async () => {
    const transcript = temporaryTranscript("2026-08-22T08:00:00.000Z");
    const cwd = path.dirname(transcript.path);
    try {
      const provider = new FakeProvider();
      provider.sessions = [{
        ...live,
        cwd,
        chatPath: transcript.path,
        controlTarget: {
          kind: "terminal",
          target: { application: "Ghostty", tty: "ttys001", cwd },
        },
      }];
      const repository = new SessionRepository([provider]);
      await repository.refresh();
      const updates: ReturnType<SessionRepository["piRestorationUpdate"]>[] = [];
      repository.subscribePiRestoration((update) => updates.push(update));

      repository.applyHook({
        ...heartbeat({ cwd, sessionFile: transcript.path }),
        receivedAt: "2026-08-22T08:02:00.000Z",
      });

      expect(repository.current().revision).toBe(1);
      expect(updates.at(-1)?.candidates).toMatchObject([{ sessionId: "pi-1" }]);
    } finally {
      transcript.remove();
    }
  });

  it("replaces an old Pi restoration identity on exact same-process SessionStart", async () => {
    const transcript = temporaryTranscript("2026-08-22T08:00:00.000Z");
    const cwd = path.dirname(transcript.path);
    const replacementFile = path.join(cwd, "replacement.jsonl");
    writeFileSync(replacementFile, "{}\n");
    try {
      const provider = new FakeProvider();
      provider.sessions = [{
        ...live,
        id: "pi-old",
        cwd,
        chatPath: transcript.path,
        controlTarget: {
          kind: "terminal",
          target: { application: "Ghostty", tty: "ttys001", cwd },
        },
      }];
      const repository = new SessionRepository([provider]);
      await repository.refresh();
      repository.applyHook({
        ...heartbeat({ sessionId: "pi-old", cwd, sessionFile: transcript.path }),
        event: "SessionStart",
      });

      repository.applyHook({
        ...heartbeat({ sessionId: "pi-new", cwd, sessionFile: replacementFile }),
        event: "SessionStart",
        receivedAt: "2026-08-22T08:02:00.000Z",
      });

      expect(repository.piRestorationUpdate()).toMatchObject({
        candidates: [],
        liveSessionIds: ["pi-new"],
        removeCandidateSessionIds: ["pi-old"],
      });
    } finally {
      transcript.remove();
    }
  });

  it("maps Pi's settled Stop event to Ready", () => {
    const repository = new SessionRepository([]);

    const snapshot = repository.applyHook({
      ...heartbeat(),
      event: "Stop",
      status: "waiting_for_input",
    });

    expect(snapshot.sessions[0]).toMatchObject({
      section: "ready",
      subtitle: "Ready to continue",
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

  it("removes an abandoned Claude approval when its responder disconnects", async () => {
    const repository = new SessionRepository([]);
    repository.applyHook({
      sessionId: "claude-abandoned",
      cwd: live.cwd,
      provider: "claude_code",
      event: "PermissionRequest",
      status: "waiting_for_approval",
      receivedAt: "2026-08-22T08:01:00.000Z",
      expectsResponse: true,
      tool: "Bash",
      toolUseId: "tool-abandoned",
      toolInput: { command: "echo stale" },
    });
    const unregister = repository.registerHookResponder(
      "claude-abandoned",
      "tool-abandoned",
      () => undefined,
    );

    unregister();

    expect((await repository.refresh()).sessions).toEqual([]);
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

    expect(repository.pendingAction("pi-1")).toMatchObject({
      type: "approval", toolUseId: "codex-command-1",
    });
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

  it("reattaches exact Pi focus after a same-boot repository restart", async () => {
    const transcript = temporaryTranscript("2026-08-22T08:00:00.000Z");
    const statePath = path.join(path.dirname(transcript.path), "pi-runtime.json");
    const bootSessionUUID = "7715CBA2-964F-4562-9F25-67CCF1DD8C22";
    const session = {
      ...live,
      cwd: path.dirname(transcript.path),
      chatPath: transcript.path,
      controlTarget: {
        kind: "terminal" as const,
        target: {
          application: "Ghostty" as const,
          tty: "ttys012",
          cwd: path.dirname(transcript.path),
        },
      },
    };
    try {
      const firstProvider = new FakeProvider();
      firstProvider.requiresHook = true;
      firstProvider.sessions = [session];
      const first = new SessionRepository(
        [firstProvider],
        { piRuntimeStatePath: statePath, bootSessionUUID },
      );
      first.applyHook(heartbeat({
        cwd: session.cwd,
        tty: "ttys012",
        sessionFile: transcript.path,
      }));
      await first.refresh();

      const restartedProvider = new FakeProvider();
      restartedProvider.requiresHook = true;
      restartedProvider.sessions = [session];
      const restarted = new SessionRepository(
        [restartedProvider],
        { piRuntimeStatePath: statePath, bootSessionUUID },
      );
      const focused: string[] = [];
      restarted.setControls({
        focus: async (record) => { focused.push(record.id); },
        send: async () => undefined,
      });

      await restarted.refresh();

      expect(await restarted.focusSession("pi-1")).toBeUndefined();
      expect(focused).toEqual(["pi-1"]);

      const wrongBootProvider = new FakeProvider();
      wrongBootProvider.requiresHook = true;
      wrongBootProvider.sessions = [session];
      const wrongBoot = new SessionRepository(
        [wrongBootProvider],
        {
          piRuntimeStatePath: statePath,
          bootSessionUUID: "6333390E-5726-479B-B8D5-F9AB4D4FAE29",
        },
      );
      wrongBoot.setControls({ focus: async () => undefined, send: async () => undefined });
      await wrongBoot.refresh();
      expect(await wrongBoot.focusSession("pi-1")).toBe("Exact session focus is unavailable.");

      restarted.applyHook({
        sessionId: "pi-1",
        cwd: session.cwd,
        provider: "pi",
        event: "SessionEnd",
        status: "ended",
        receivedAt: "2026-08-22T08:02:00.000Z",
      });
      const endedProvider = new FakeProvider();
      endedProvider.requiresHook = true;
      endedProvider.sessions = [session];
      const ended = new SessionRepository(
        [endedProvider],
        { piRuntimeStatePath: statePath, bootSessionUUID },
      );
      ended.setControls({ focus: async () => undefined, send: async () => undefined });
      await ended.refresh();
      expect(await ended.focusSession("pi-1")).toBe("Exact session focus is unavailable.");
    } finally {
      transcript.remove();
    }
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
