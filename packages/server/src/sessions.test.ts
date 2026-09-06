import { mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it, vi } from "vitest";
import {
  MAX_CHAT_ACTIONS_PER_SESSION,
  EXTERNAL_APPROVAL_RESPONSE_TIMEOUT_MS,
  MAX_EXTERNAL_APPROVAL_RECORDS,
  SessionRepository,
  type DiscoveredProviderSession,
  type HookSessionEvent,
  type ProviderAdapter,
  type SessionRouteProbeResult,
} from "./sessions.js";
import type { ChatPage } from "@agent-visor/protocol";
import { processInstanceToken } from "./providers/shared.js";
import { FakeNativeHelper } from "./native-helper.js";
import { NativeSessionControls } from "./session-controls.js";
import type { CodexRouteEvent } from "./codex-turn.js";

const live: DiscoveredProviderSession = {
  id: "pi-1",
  provider: "pi",
  title: "Migration",
  subtitle: "Active Pi session",
  cwd: "/Users/me/Codes/agent-visor",
  owner: "Ghostty",
  section: "working",
  turnState: "working",
  updatedAt: "2026-08-22T08:00:00.000Z",
  canOpenOwner: true,
  canEnterChat: true,
  authority: 1,
};

const readyLive: DiscoveredProviderSession = {
  ...live,
  section: "ready",
  turnState: "ready",
  conversationState: "open",
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
    const repository = new SessionRepository([provider], {
      now: () => new Date("2026-08-23T00:00:00.000Z"),
    });
    await repository.refresh();
    provider.sessions[0] = { ...live, section: "ready", subtitle: "Ready" };

    const changed = await repository.refresh();

    expect(changed.revision).toBe(2);
    expect(changed.sessions[0]?.section).toBe("ready");
  });

  it("keeps automation searchable but outside Ready attention", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...live,
      provider: "codex",
      owner: "Codex",
      title: "Current message from an automation prompt",
      section: "ready",
      sessionClass: "automation",
    }];
    const repository = new SessionRepository([provider]);

    const snapshot = await repository.refresh();

    expect(snapshot.sessions[0]).toMatchObject({
      id: "pi-1",
      title: "Current message from an automation prompt",
      sessionClass: "automation",
      section: "ready",
      attentionTier: "history",
    });
  });

  it("keeps automation Chat capabilities read only when actions are pending", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...live,
      provider: "codex",
      owner: "Codex",
      sessionClass: "automation",
      chatPath: "/tmp/automation.jsonl",
    }];
    const repository = new SessionRepository([provider]);
    await repository.refresh();
    repository.registerExternalAction("pi-1", {
      type: "approval", toolUseId: "automation-approval", toolName: "Command",
      input: { command: "echo private" }, canPersist: false,
    }, async () => undefined);
    repository.registerExternalAction("pi-1", {
      type: "question", toolUseId: "automation-question",
      questions: [{ id: "continue", question: "Continue?", choices: ["Yes"], multiple: false }],
    }, async () => undefined);

    const page = await repository.chatPage("pi-1");

    expect(page.pendingActions).toHaveLength(2);
    expect(page.capabilities).toMatchObject({
      canSendText: false,
      canSendImages: false,
      canCancel: false,
      canApprove: false,
      canAnswer: false,
      readOnlyReason: "Automation sessions are read only.",
    });
  });

  it("preserves the last provider snapshot after a transient read failure", async () => {
    const provider = new FakeProvider();
    const repository = new SessionRepository([provider]);
    const first = await repository.refresh();
    provider.discover = async () => { throw new Error("mid-write read"); };

    expect(await repository.refresh()).toEqual(first);
  });

  it("keeps an exact opened Codex chat addressable after ambient discovery ages it out", async () => {
    const sessionId = "opened-old-codex";
    const session: DiscoveredProviderSession = {
      ...live,
      id: sessionId,
      provider: "codex",
      owner: "Codex",
      section: "history",
      conversationState: "open",
      turnState: "ready",
      routeState: "available",
      chatPath: "/tmp/opened-old-codex.jsonl",
      messageTransport: "codex_app_server",
      controlTarget: { kind: "url", url: `codex://threads/${sessionId}` },
    };
    let exactResolutions = 0;
    const provider: ProviderAdapter = {
      id: "codex",
      discover: async () => [],
      resolve: async (id) => {
        exactResolutions += 1;
        return id === sessionId ? structuredClone(session) : undefined;
      },
    };
    const repository = new SessionRepository([provider], {
      chatPageReader: async () => ({ ...testChatPage("old-entry"), sessionId }),
    });
    const focused: string[] = [];
    repository.setControls({
      focus: async (record) => { focused.push(record.id); },
      send: async () => undefined,
    });

    expect((await repository.refresh()).sessions).toEqual([]);
    expect((await repository.chatPage(sessionId)).capabilities).toMatchObject({
      canSendText: true,
    });
    expect((await repository.refresh()).sessions).toEqual([]);
    expect((await repository.chatPage(sessionId)).capabilities).toMatchObject({
      canSendText: true,
    });
    expect(await repository.focusSession(sessionId)).toBeUndefined();
    expect(focused).toEqual([sessionId]);
    expect(exactResolutions).toBeGreaterThanOrEqual(2);
  });

  it("keeps a cached transcript readable while exact Codex resolution is unavailable", async () => {
    const sessionId = "unresolved-codex";
    const session: DiscoveredProviderSession = {
      ...live,
      id: sessionId,
      provider: "codex",
      owner: "Codex",
      section: "ready",
      conversationState: "open",
      turnState: "ready",
      routeState: "available",
      chatPath: "/tmp/unresolved-codex.jsonl",
      messageTransport: "codex_app_server",
      controlTarget: { kind: "url", url: `codex://threads/${sessionId}` },
    };
    const provider: ProviderAdapter = {
      id: "codex",
      discover: async () => [structuredClone(session)],
      resolve: async () => undefined,
    };
    let sends = 0;
    const repository = new SessionRepository([provider], {
      chatPageReader: async () => ({ ...testChatPage("cached-entry"), sessionId }),
    });
    repository.setControls({
      focus: async () => undefined,
      send: async () => { sends += 1; },
    });

    await repository.refresh();
    const page = await repository.chatPage(sessionId);
    expect(page.items).toMatchObject([{ id: "cached-entry", kind: "user" }]);
    expect(page.sessionState).toMatchObject({
      conversation: "open",
      route: "unavailable",
      unavailableReason: "provider_unavailable",
    });
    expect(page.capabilities).toMatchObject({
      canSendText: false,
      unavailableReason: "provider_unavailable",
    });
    await repository.refresh();
    expect((await repository.chatPage(sessionId)).capabilities.canSendText).toBe(false);
    expect(await repository.chatAction({
      type: "send_chat",
      id: "must-not-send",
      sessionId,
      generation: 1,
      deliveryId: "must-not-deliver",
      text: "must remain read only",
      images: [],
    })).toContain("unavailable");
    expect(sends).toBe(0);
  });

  it("preserves Codex Chat entry and control permissions when history becomes Ready", async () => {
    const directory = mkdtempSync(path.join(tmpdir(), "codex-chat-entry-"));
    const transcript = path.join(directory, "rollout.jsonl");
    writeFileSync(transcript, `${JSON.stringify({
      type: "response_item",
      payload: {
        type: "message", id: "user-1", role: "user",
        content: [{ type: "input_text", text: "Existing conversation" }],
      },
    })}\n`);
    try {
      const provider = new FakeProvider();
      provider.sessions = [{
        ...live, provider: "codex", owner: "Codex", section: "history",
        canEnterChat: true, chatPath: transcript, messageTransport: "codex_app_server",
      }];
      const repository = new SessionRepository([provider]);
      expect((await repository.refresh()).sessions[0]).toMatchObject({
        section: "history", canEnterChat: true,
      });
      const previousCapabilities = (await repository.chatPage(live.id)).capabilities;
      const snapshot = repository.applyHook({
        sessionId: live.id, provider: "codex", cwd: live.cwd,
        event: "Stop", status: "waiting_for_input", receivedAt: live.updatedAt,
      });

      expect(snapshot.sessions[0]?.canEnterChat).toBe(true);
      const page = await repository.chatPage(live.id);
      expect(page.items).toMatchObject([{ kind: "user", text: "Existing conversation" }]);
      expect(page.capabilities).toEqual(previousCapabilities);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it.each([
    { provider: "codex" as const, owner: "Codex", chatPath: undefined },
    { provider: "codex" as const, owner: "Zed", chatPath: "/tmp/zed.jsonl" },
    { provider: "cursor" as const, owner: "Cursor", chatPath: "/tmp/cursor.jsonl" },
  ])("preserves provider Chat entry restrictions for $provider owned by $owner", async (record) => {
    const provider = new FakeProvider();
    provider.sessions = [{ ...live, ...record, section: "ready", canEnterChat: false }];
    const repository = new SessionRepository([provider]);

    expect((await repository.refresh()).sessions[0]?.canEnterChat).toBe(false);
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

  it("does not publish non-terminal Claude hooks without an authoritative session", () => {
    const repository = new SessionRepository([]);
    const hook = {
      sessionId: "claude-sdk",
      cwd: "/Users/me/Codes",
      provider: "claude_code" as const,
      event: "Stop",
      status: "waiting_for_input",
      receivedAt: "2026-08-26T16:35:09.008Z",
      pid: 63462,
    };

    expect(repository.applyHook(hook).sessions).toEqual([]);
    expect(repository.applyHook({
      ...hook,
      sessionId: "claude-cli",
      tty: "/dev/ttys001",
    }).sessions).toMatchObject([{
      id: "claude-cli",
      source: "Claude Code",
      owner: "Terminal",
    }]);
  });

  it("does not publish Pi hooks before provider validation", () => {
    const repository = new SessionRepository([]);

    const snapshot = repository.applyHook({
      sessionId: "pi-ephemeral",
      cwd: "/Users/me/Codes",
      provider: "pi",
      event: "Stop",
      status: "waiting_for_input",
      receivedAt: "2026-08-26T17:32:00.587Z",
      pid: 71333,
      tty: "ttys087",
    });

    expect(snapshot.sessions).toEqual([]);
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

  it("maps Pi's settled Stop event to Ready", async () => {
    const provider = new FakeProvider();
    const repository = new SessionRepository([provider]);
    await repository.refresh();

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

  it("expires stale Pi Ready hook evidence through provider rediscovery", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...live,
      owner: "Pi",
      section: "history",
      subtitle: "From Pi history",
      canOpenOwner: false,
    }];
    let now = new Date("2026-08-22T08:01:00.000Z");
    const repository = new SessionRepository([provider], { now: () => now });
    await repository.refresh();
    const ready = repository.applyHook({
      ...heartbeat(),
      event: "Stop",
      status: "waiting_for_input",
      receivedAt: now.toISOString(),
    });
    expect(ready.sessions[0]).toMatchObject({
      section: "ready",
      subtitle: "Ready to continue",
    });

    now = new Date("2026-08-22T08:31:01.000Z");
    const expired = await repository.refresh();

    expect(expired.sessions[0]).toMatchObject({
      section: "history",
      subtitle: "From Pi history",
      canOpenOwner: false,
    });
  });

  it("expires stale Pi Ready while preserving live owner navigation", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...live,
      section: "history",
      subtitle: "Pi session",
    }];
    let now = new Date("2026-08-22T08:01:00.000Z");
    const repository = new SessionRepository([provider], { now: () => now });
    await repository.refresh();
    repository.applyHook({
      ...heartbeat(),
      event: "Stop",
      status: "waiting_for_input",
      receivedAt: now.toISOString(),
    });

    now = new Date("2026-08-22T08:31:01.000Z");
    const expired = await repository.refresh();

    expect(expired.sessions[0]).toMatchObject({
      section: "history",
      subtitle: "Pi session",
      owner: "Ghostty",
      canOpenOwner: true,
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

  it("keeps Claude idle-prompt notifications phase-neutral for a Ready session", () => {
    const repository = new SessionRepository([]);
    const hook = {
      sessionId: "claude-cli",
      cwd: "/Users/me/Codes",
      provider: "claude_code" as const,
      pid: 63462,
      tty: "/dev/ttys001",
    };
    const ready = repository.applyHook({
      ...hook, event: "Stop", status: "waiting_for_input", receivedAt: "2026-09-11T20:00:00.000Z",
    });
    expect(ready.sessions[0]).toMatchObject({
      section: "ready",
      subtitle: "Ready to continue",
      updatedAt: "2026-09-11T20:00:00.000Z",
    });

    // Claude Code repeats this notification about every minute while it
    // waits for the user. It must not read as an approval request.
    const after = repository.applyHook({
      ...hook, event: "Notification", status: "waiting_for_input", receivedAt: "2026-09-11T20:01:00.000Z",
    });
    expect(after).toEqual(ready);
  });

  it("keeps Claude notifications phase-neutral while the agent is working", () => {
    const repository = new SessionRepository([]);
    const hook = {
      sessionId: "claude-cli",
      cwd: "/Users/me/Codes",
      provider: "claude_code" as const,
      pid: 63462,
      tty: "/dev/ttys001",
    };
    const working = repository.applyHook({
      ...hook, event: "PreToolUse", status: "processing", receivedAt: "2026-09-11T20:00:00.000Z",
    });
    expect(working.sessions[0]).toMatchObject({ section: "working" });

    const after = repository.applyHook({
      ...hook, event: "Notification", status: "notification", receivedAt: "2026-09-11T20:00:30.000Z",
    });
    expect(after).toEqual(working);
  });

  it("presents a lone Claude idle-prompt notification as Ready, not as an approval", () => {
    const repository = new SessionRepository([]);
    const snapshot = repository.applyHook({
      sessionId: "claude-cli",
      cwd: "/Users/me/Codes",
      provider: "claude_code",
      event: "Notification",
      status: "waiting_for_input",
      receivedAt: "2026-09-11T20:01:00.000Z",
      pid: 63462,
      tty: "/dev/ttys001",
    });
    expect(snapshot.sessions[0]).toMatchObject({
      section: "ready",
      subtitle: "Ready to continue",
      updatedAt: "2026-09-11T20:01:00.000Z",
    });
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

  it("reattaches a heartbeat-only Pi session as History", async () => {
    const transcript = temporaryTranscript("2026-08-22T08:00:00.000Z");
    try {
      const provider = new FakeProvider();
      provider.requiresHook = true;
      const repository = new SessionRepository([provider]);
      repository.applyHook(heartbeat({
        receivedAt: "2026-08-22T10:00:00.000Z",
        isIdle: true,
        sessionFile: transcript.path,
      }));
      const snapshot = await repository.refresh();

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

  it("exposes and routes Claude permission cycling through exact mode and generation", async () => {
    const transcript = temporaryTranscript("2026-08-23T00:00:00.000Z");
    const claude: DiscoveredProviderSession = {
      ...readyLive,
      id: "claude-cycle",
      provider: "claude_code",
      chatPath: transcript.path,
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    };
    const provider: ProviderAdapter = {
      id: "claude_code",
      discover: async () => [structuredClone(claude)],
    };
    let mode = "default";
    let cycles = 0;
    const repository = new SessionRepository([provider], {
      chatPageReader: async (session) => ({
        type: "chat_page",
        sessionId: session.id,
        items: [],
        hasMoreBefore: false,
        metadata: { permissionMode: mode },
        capabilities: {
          canSendText: true,
          canSendImages: true,
          canCancel: false,
          canApprove: false,
          canAnswer: false,
          canCyclePermissionMode: true,
        },
        pendingAction: null,
      }),
    });
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      canCyclePermissionMode: () => true,
      cyclePermissionMode: async () => {
        cycles += 1;
        mode = "acceptEdits";
      },
    });
    try {
      await repository.refresh();
      expect((await repository.chatPage("claude-cycle")).capabilities.canCyclePermissionMode)
        .toBe(true);
      expect(await repository.chatAction({
        type: "cycle_permission_mode",
        id: "cycle-1",
        sessionId: "claude-cycle",
        generation: 1,
        expectedMode: "default",
      })).toBeUndefined();
      expect(cycles).toBe(1);
      expect(await repository.chatAction({
        type: "cycle_permission_mode",
        id: "cycle-stale",
        sessionId: "claude-cycle",
        generation: 1,
        expectedMode: "default",
      })).toContain("changed");
      expect(cycles).toBe(1);
    } finally {
      transcript.remove();
    }
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

  it("rejects automation cancellation and approval/question responses", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...live,
      provider: "codex",
      owner: "Codex",
      section: "working",
      sessionClass: "automation",
      chatPath: "/tmp/automation.jsonl",
    }];
    const repository = new SessionRepository([provider]);
    let cancelCalls = 0;
    let responseCalls = 0;
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      canCancel: () => true,
      cancel: async () => { cancelCalls += 1; },
    });
    await repository.refresh();
    repository.registerExternalAction("pi-1", {
      type: "approval", toolUseId: "automation-approval", toolName: "Command",
      input: { command: "echo private" }, canPersist: false,
    }, async () => { responseCalls += 1; });
    repository.registerExternalAction("pi-1", {
      type: "question", toolUseId: "automation-question",
      questions: [{ id: "continue", question: "Continue?", choices: ["Yes"], multiple: false }],
    }, async () => { responseCalls += 1; });

    await expect(repository.chatAction({
      type: "cancel_chat", id: "cancel-automation", sessionId: "pi-1", generation: 1,
      deliveryId: "delivery-automation",
    })).resolves.toBe("Automation sessions are read only.");
    await expect(repository.chatAction({
      type: "respond_chat", id: "respond-approval", sessionId: "pi-1",
      toolUseId: "automation-approval", decision: "allow",
    })).resolves.toBe("Automation sessions are read only.");
    await expect(repository.chatAction({
      type: "respond_chat", id: "respond-question", sessionId: "pi-1",
      toolUseId: "automation-question", decision: "answer", answers: { continue: "Yes" },
    })).resolves.toBe("Automation sessions are read only.");

    expect(cancelCalls).toBe(0);
    expect(responseCalls).toBe(0);
    expect(repository.pendingActions("pi-1")).toHaveLength(2);
  });

  it("keeps concurrent approvals separate and routes each exact approval out of order", async () => {
    const repository = new SessionRepository([]);
    const decisions: string[] = [];
    repository.registerExternalAction("approval-session", {
      type: "approval", toolUseId: "tool-a", approvalId: "approval-a",
      toolName: "Command", input: { command: "echo a" }, canPersist: false,
    }, async (message) => { decisions.push(`a:${message.decision}`); });
    repository.registerExternalAction("approval-session", {
      type: "approval", toolUseId: "tool-b", approvalId: "approval-b",
      toolName: "Command", input: { command: "echo b" }, canPersist: false,
    }, async (message) => { decisions.push(`b:${message.decision}`); });

    expect(repository.pendingActions("approval-session").map((action) => action.approvalId))
      .toEqual(["approval-a", "approval-b"]);
    await repository.chatAction({
      type: "respond_chat", id: "response-b", sessionId: "approval-session",
      toolUseId: "tool-b", approvalId: "approval-b", decision: "deny",
    });
    await repository.chatAction({
      type: "respond_chat", id: "response-a", sessionId: "approval-session",
      toolUseId: "tool-a", approvalId: "approval-a", decision: "allow",
    });

    expect(decisions).toEqual(["b:deny", "a:allow"]);
    expect(repository.pendingActions("approval-session")).toEqual([]);
  });

  it("coalesces an exact approval response and caches the result while rejecting conflicts", async () => {
    const repository = new SessionRepository([]);
    let calls = 0;
    let release!: () => void;
    const blocked = new Promise<void>((resolve) => { release = resolve; });
    repository.registerExternalAction("approval-session", {
      type: "approval", toolUseId: "tool-a", approvalId: "approval-a",
      toolName: "Command", input: {}, canPersist: false,
    }, async () => { calls += 1; await blocked; });
    const message = {
      type: "respond_chat" as const, id: "response-a", sessionId: "approval-session",
      toolUseId: "tool-a", approvalId: "approval-a", decision: "allow" as const,
    };
    const first = repository.chatAction(message);
    const duplicate = repository.chatAction({ ...message, id: "response-a-replay" });
    await Promise.resolve();
    expect(repository.pendingActions("approval-session")[0]).toMatchObject({
      approvalId: "approval-a", responding: true,
    });
    const conflict = await repository.chatAction({ ...message, id: "response-conflict", decision: "deny" });
    expect(conflict).toMatch(/already responding|different response/i);
    expect(calls).toBe(1);
    release();
    await expect(first).resolves.toBeUndefined();
    await expect(duplicate).resolves.toBeUndefined();
    await expect(repository.chatAction({ ...message, id: "response-a-lost-reply" })).resolves.toBeUndefined();
    expect(calls).toBe(1);
  });

  it("turns a thrown approval response into a cached terminal error", async () => {
    const repository = new SessionRepository([]);
    let calls = 0;
    repository.registerExternalAction("approval-session", {
      type: "approval", toolUseId: "tool-a", approvalId: "approval-a",
      toolName: "Command", input: {}, canPersist: false,
    }, async () => { calls += 1; throw new Error("provider disconnected"); });
    const message = {
      type: "respond_chat" as const, id: "response-a", sessionId: "approval-session",
      toolUseId: "tool-a", approvalId: "approval-a", decision: "allow" as const,
    };

    await expect(repository.chatAction(message)).resolves.toBe("provider disconnected");
    await expect(repository.chatAction({ ...message, id: "response-a-replay" }))
      .resolves.toBe("provider disconnected");
    expect(calls).toBe(1);
    expect(repository.pendingActions("approval-session")).toEqual([]);
  });

  it("settles a timed-out approval once and retains the terminal result for replay", async () => {
    vi.useFakeTimers();
    try {
      const repository = new SessionRepository([]);
      let calls = 0;
      repository.registerExternalAction("approval-session", {
        type: "approval", toolUseId: "tool-timeout", approvalId: "approval-timeout",
        toolName: "Command", input: {}, canPersist: false,
      }, async () => {
        calls += 1;
        await new Promise<void>(() => undefined);
      });
      const message = {
        type: "respond_chat" as const, id: "response-timeout", sessionId: "approval-session",
        toolUseId: "tool-timeout", approvalId: "approval-timeout", decision: "allow" as const,
      };
      const result = repository.chatAction(message);
      await vi.advanceTimersByTimeAsync(EXTERNAL_APPROVAL_RESPONSE_TIMEOUT_MS);
      await expect(result).resolves.toBe("The provider approval response timed out.");
      await expect(repository.chatAction({ ...message, id: "response-timeout-replay" }))
        .resolves.toBe("The provider approval response timed out.");
      expect(calls).toBe(1);
      expect(repository.pendingActions("approval-session")).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("retains at most the approval record cap without replacing actionable records", () => {
    const repository = new SessionRepository([]);
    for (let index = 0; index < MAX_EXTERNAL_APPROVAL_RECORDS + 1; index += 1) {
      repository.registerExternalAction("approval-session", {
        type: "approval", toolUseId: `tool-${index}`, approvalId: `approval-${index}`,
        toolName: "Command", input: { index }, canPersist: false,
      }, async () => undefined);
    }
    const actions = repository.pendingActions("approval-session");
    expect(actions).toHaveLength(MAX_EXTERNAL_APPROVAL_RECORDS);
    expect(actions.at(-1)).toMatchObject({ approvalId: `approval-${MAX_EXTERNAL_APPROVAL_RECORDS - 1}` });
    expect(actions[0]).toMatchObject({ approvalId: "approval-0" });
  });

  it("rejects a response from a stale approval generation", async () => {
    const repository = new SessionRepository([]);
    let calls = 0;
    repository.registerExternalAction("approval-session", {
      type: "approval", toolUseId: "tool-a", approvalId: "approval-a",
      toolName: "Command", input: {}, canPersist: false,
    }, async () => { calls += 1; });

    await expect(repository.chatAction({
      type: "respond_chat", id: "response-stale", sessionId: "approval-session",
      toolUseId: "tool-a", approvalId: "approval-a", generation: 2, decision: "allow",
    })).resolves.toMatch(/stale|generation|no longer/i);
    expect(calls).toBe(0);
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
      ...readyLive,
      chatPath: "/tmp/pi.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
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
      type: "send_chat", id: "send-1", sessionId: "pi-1", generation: 1,
      deliveryId: "delivery-1", text: "Continue", images: [],
    })).toBeUndefined();
    expect(calls).toEqual(["focus:pi-1", "send:pi-1:Continue"]);
  });

  it("loads Codex settings only when opening Chat and forwards validated next-turn choices", async () => {
    const catalog = {
      models: [{
        id: "gpt-6-astra", displayName: "GPT-6 Astra", description: "Fast model",
        reasoningEfforts: [
          { value: "low", description: "Fast" },
          { value: "high", description: "Deep" },
        ],
        defaultReasoningEffort: "high", supportsImages: true, isDefault: true,
      }, {
        id: "gpt-5.3-codex-spark", displayName: "GPT-5.3 Codex Spark", description: "Text only",
        reasoningEfforts: [{ value: "high", description: "Deep" }],
        defaultReasoningEffort: "high", supportsImages: false, isDefault: false,
      }],
      permissionProfiles: [{ id: ":workspace", displayName: "Workspace", allowed: true }],
    };
    const codexSession: DiscoveredProviderSession = {
      ...readyLive,
      provider: "codex",
      owner: "Codex",
      chatPath: "/tmp/codex-settings.jsonl",
      messageTransport: "codex_app_server",
      routeState: "available",
    };
    let discoveries = 0;
    let settingsReads = 0;
    let selected: unknown;
    const provider: ProviderAdapter = {
      id: "codex",
      discover: async () => { discoveries += 1; return [structuredClone(codexSession)]; },
      chatSettings: async () => { settingsReads += 1; return catalog; },
    };
    const repository = new SessionRepository([provider], {
      chatPageReader: async (session) => ({
        type: "chat_page", sessionId: session.id, items: [], hasMoreBefore: false,
        metadata: { modelId: "gpt-5.3-codex-spark", reasoningEffort: "high", permissionProfile: ":workspace" },
        capabilities: {
          canSendText: true, canSendImages: true, canCancel: false,
          canApprove: false, canAnswer: false,
        },
        pendingAction: null,
      }),
    });
    repository.setControls({
      focus: async () => undefined,
      send: async (_session, _text, _images, _delivery, _evidence, _isCurrent, settings) => {
        selected = settings;
      },
    });

    await repository.refresh();
    expect(discoveries).toBe(1);
    expect(settingsReads).toBe(0);

    const page = await repository.chatPage(codexSession.id);
    expect(settingsReads).toBe(1);
    expect(page.chatSettings).toMatchObject({
      provider: "codex",
      current: { modelId: "gpt-5.3-codex-spark", reasoningEffort: "high", permissionProfile: ":workspace" },
      appliesTo: "next_turn",
    });

    await repository.refresh();
    await repository.chatPage(codexSession.id);
    expect(settingsReads).toBe(1);
    expect(await repository.chatAction({
      type: "send_chat", id: "codex-settings-send", sessionId: codexSession.id, generation: 1,
      deliveryId: "codex-settings-delivery", text: "Continue", images: [],
      settings: { modelId: "gpt-6-astra", reasoningEffort: "high", permissionProfile: ":workspace" },
    })).toBeUndefined();
    expect(selected).toEqual({
      modelId: "gpt-6-astra", reasoningEffort: "high", permissionProfile: ":workspace",
    });
    expect(await repository.chatAction({
      type: "send_chat", id: "codex-current-reasoning", sessionId: codexSession.id, generation: 1,
      deliveryId: "codex-current-reasoning-delivery", text: "Do not send", images: [],
      settings: { reasoningEffort: "low" },
    })).toContain("unavailable");
    expect(await repository.chatAction({
      type: "send_chat", id: "codex-current-image", sessionId: codexSession.id, generation: 1,
      deliveryId: "codex-current-image-delivery", text: "Image", images: [{
        name: "pixel.png", mimeType: "image/png", byteLength: 8, data: "iVBORw0KGgo=",
      }],
    })).toContain("does not support images");
    expect(await repository.chatAction({
      type: "send_chat", id: "codex-invalid-settings", sessionId: codexSession.id, generation: 1,
      deliveryId: "codex-invalid-delivery", text: "Do not send", images: [],
      settings: { permissionProfile: ":danger-full-access" },
    })).toContain("unavailable");
    expect(selected).toEqual({
      modelId: "gpt-6-astra", reasoningEffort: "high", permissionProfile: ":workspace",
    });
  });

  it("pushes a settings-only update when the lazy Codex catalog misses the first-open bound", async () => {
    const catalog = {
      models: [{
        id: "gpt-6-astra", displayName: "GPT-6 Astra", description: "Fast model",
        reasoningEfforts: [{ value: "high", description: "Deep" }],
        defaultReasoningEffort: "high", supportsImages: true, isDefault: true,
      }],
      permissionProfiles: [{ id: ":workspace", displayName: "Workspace", allowed: true }],
    };
    const codexSession: DiscoveredProviderSession = {
      ...live,
      provider: "codex",
      owner: "Codex",
      chatPath: "/tmp/codex-lazy-settings.jsonl",
      messageTransport: "codex_app_server",
    };
    let resolveCatalog!: (value: typeof catalog) => void;
    const catalogPromise = new Promise<typeof catalog>((resolve) => { resolveCatalog = resolve; });
    const provider: ProviderAdapter = {
      id: "codex",
      discover: async () => [structuredClone(codexSession)],
      chatSettings: async () => catalogPromise,
    };
    const repository = new SessionRepository([provider], {
      chatPageReader: async (session) => ({
        type: "chat_page", sessionId: session.id, items: [], hasMoreBefore: false,
        metadata: { modelId: "gpt-6-astra", reasoningEffort: "high" },
        capabilities: {
          canSendText: true, canSendImages: true, canCancel: false,
          canApprove: false, canAnswer: false,
        },
        pendingAction: null,
      }),
    });
    const updates: unknown[] = [];
    repository.subscribeChatSettings?.((update) => updates.push(update));
    await repository.refresh();

    const firstPage = await repository.chatPage(codexSession.id);
    expect(firstPage.chatSettings).toBeUndefined();

    resolveCatalog(catalog);
    await expect.poll(() => updates).toHaveLength(1);
    expect(updates[0]).toMatchObject({
      type: "chat_settings_update",
      sessionId: codexSession.id,
      generation: 1,
      settings: {
        current: { modelId: "gpt-6-astra", reasoningEffort: "high" },
        models: [{ id: "gpt-6-astra" }],
      },
    });
  });

  it("refreshes an expired settings catalog before delivering a staged send", async () => {
    const now = vi.spyOn(Date, "now").mockReturnValue(1_000);
    try {
      const catalog = {
        models: [{
          id: "gpt-6-astra", displayName: "GPT-6 Astra", description: "Fast model",
          reasoningEfforts: [{ value: "high", description: "Deep" }],
          defaultReasoningEffort: "high", supportsImages: true, isDefault: true,
        }],
        permissionProfiles: [{ id: ":workspace", displayName: "Workspace", allowed: true }],
      };
      const codexSession: DiscoveredProviderSession = {
        ...readyLive,
        provider: "codex",
        owner: "Codex",
        chatPath: "/tmp/codex-expired-settings.jsonl",
        messageTransport: "codex_app_server",
        routeState: "available",
      };
      let settingsReads = 0;
      const provider: ProviderAdapter = {
        id: "codex",
        discover: async () => [structuredClone(codexSession)],
        chatSettings: async () => { settingsReads += 1; return catalog; },
      };
      let sentSettings: unknown;
      const repository = new SessionRepository([provider], {
        chatPageReader: async (session) => ({
          type: "chat_page", sessionId: session.id, items: [], hasMoreBefore: false,
          metadata: { modelId: "gpt-6-astra", reasoningEffort: "high" },
          capabilities: {
            canSendText: true, canSendImages: true, canCancel: false,
            canApprove: false, canAnswer: false,
          },
          pendingAction: null,
        }),
      });
      repository.setControls({
        focus: async () => undefined,
        send: async (_session, _text, _images, _delivery, _evidence, _isCurrent, settings) => {
          sentSettings = settings;
        },
      });
      await repository.refresh();
      await repository.chatPage(codexSession.id);
      expect(settingsReads).toBe(1);
      now.mockReturnValue(61_001);
      expect(await repository.chatAction({
        type: "send_chat", id: "codex-expired-send", sessionId: codexSession.id, generation: 1,
        deliveryId: "codex-expired-delivery", text: "Continue", images: [],
        settings: { modelId: "gpt-6-astra", permissionProfile: ":workspace" },
      })).toBeUndefined();
      expect(settingsReads).toBe(2);
      expect(sentSettings).toEqual({ modelId: "gpt-6-astra", permissionProfile: ":workspace" });
    } finally {
      now.mockRestore();
    }
  });

  it("attaches a catalog that finishes during optional usage loading before returning the page", async () => {
    const catalog = {
      models: [{
        id: "gpt-6-astra", displayName: "GPT-6 Astra", description: "Fast model",
        reasoningEfforts: [{ value: "high", description: "Deep" }],
        defaultReasoningEffort: "high", supportsImages: true, isDefault: true,
      }],
      permissionProfiles: [],
    };
    const codexSession: DiscoveredProviderSession = {
      ...live,
      provider: "codex",
      owner: "Codex",
      chatPath: "/tmp/codex-usage-settings.jsonl",
      messageTransport: "codex_app_server",
    };
    let resolveCatalog!: (value: typeof catalog) => void;
    let resolveUsage!: (value: undefined) => void;
    let usageStarted = false;
    const catalogPromise = new Promise<typeof catalog>((resolve) => { resolveCatalog = resolve; });
    const usagePromise = new Promise<undefined>((resolve) => { resolveUsage = resolve; });
    const provider: ProviderAdapter = {
      id: "codex",
      discover: async () => [structuredClone(codexSession)],
      chatSettings: async () => catalogPromise,
    };
    const repository = new SessionRepository([provider], {
      chatPageReader: async (session) => ({
        type: "chat_page", sessionId: session.id, items: [], hasMoreBefore: false,
        metadata: { modelId: "gpt-6-astra", reasoningEffort: "high" },
        capabilities: {
          canSendText: true, canSendImages: true, canCancel: false,
          canApprove: false, canAnswer: false,
        },
        pendingAction: null,
      }),
      chatUsageGlance: async () => {
        usageStarted = true;
        return usagePromise;
      },
    });
    await repository.refresh();
    const pagePromise = repository.chatPage(codexSession.id);
    await expect.poll(() => usageStarted).toBe(true);
    resolveCatalog(catalog);
    resolveUsage(undefined);
    const page = await pagePromise;
    expect(page.chatSettings).toMatchObject({
      current: { modelId: "gpt-6-astra", reasoningEffort: "high" },
      models: [{ id: "gpt-6-astra" }],
    });
  });

  it("revalidates the live generation after an async evidence read before writing", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...readyLive,
      chatPath: "/tmp/pi.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    }];
    let evidenceStarted!: () => void;
    let releaseEvidence!: (page: ChatPage) => void;
    const started = new Promise<void>((resolve) => { evidenceStarted = resolve; });
    const evidence = new Promise<ChatPage>((resolve) => { releaseEvidence = resolve; });
    let writes = 0;
    const repository = new SessionRepository([provider], {
      chatPageReader: async (session) => {
        evidenceStarted();
        return evidence;
      },
    });
    repository.setControls({
      focus: async () => undefined,
      send: async () => { writes += 1; },
    });
    await repository.refresh();
    const request = repository.chatAction({
      type: "send_chat", id: "async-send", sessionId: "pi-1", generation: 1,
      deliveryId: "delivery-async", text: "must not write", images: [],
    });
    await started;
    provider.sessions[0] = {
      ...provider.sessions[0]!, section: "working", turnState: "working",
    };
    await repository.refresh();
    releaseEvidence({
      type: "chat_page", sessionId: "pi-1", items: [], hasMoreBefore: false,
      capabilities: { canSendText: true, canSendImages: true, canCancel: false, canApprove: false, canAnswer: false },
      pendingAction: null,
    });

    expect(await request).toContain("changed");
    expect(writes).toBe(0);
  });

  it("does not reconcile a stale latest page after a newer earlier page begins", async () => {
    const provider = new FakeProvider();
    const target = {
      kind: "terminal" as const,
      target: {
        application: "Ghostty" as const,
        pid: 42,
        processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
        tty: "ttys012",
        cwd: live.cwd,
      },
    };
    provider.sessions = [{
      ...readyLive,
      chatPath: "/tmp/pi-page-order.jsonl",
      messageTransport: "terminal",
      controlTarget: target,
    }];
    const reads: Array<{ before?: number; resolve: (page: ChatPage) => void }> = [];
    const repository = new SessionRepository([provider], {
      chatPageReader: async (_session, before) => new Promise<ChatPage>((resolve) => {
        reads.push({ before, resolve });
      }),
    });
    const reconciled: Array<{ latest: boolean; page: ChatPage }> = [];
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      reconcileChatPage: (_session, page, latest) => {
        reconciled.push({ latest, page });
      },
      activeCancelDeliveryId: () => "delivery-live",
      canCancel: () => true,
    });
    await repository.refresh();

    const latestRequest = repository.chatPage("pi-1");
    await expect.poll(() => reads).toHaveLength(1);
    const earlierRequest = repository.chatPage("pi-1", 100);
    await expect.poll(() => reads).toHaveLength(2);

    reads[1]!.resolve(testChatPage("earlier"));
    const earlier = await earlierRequest;
    expect(earlier.items[0]).toMatchObject({ id: "earlier" });
    reads[0]!.resolve(testChatPage("stale-latest"));
    const latest = await latestRequest;

    // Earlier pages are never authoritative native-delivery evidence, and
    // the older latest read must lose the monotonic reservation as soon as
    // the newer read begins.
    expect(reconciled).toEqual([]);
    expect(latest.capabilities.cancelDeliveryId).toBeUndefined();
  });

  it("does not let a forgotten session read mutate state after same-ID reuse", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...readyLive,
      chatPath: "/tmp/pi-page-reuse.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    }];
    let releaseOld!: (page: ChatPage) => void;
    let oldRead = true;
    const reconciled: string[] = [];
    const repository = new SessionRepository([provider], {
      chatPageReader: async () => {
        if (oldRead) return new Promise<ChatPage>((resolve) => { releaseOld = resolve; });
        return testChatPage("new-session");
      },
    });
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      reconcileChatPage: (_session, page) => { reconciled.push(page.items[0]?.id ?? "empty"); },
    });
    await repository.refresh();

    const oldRequest = repository.chatPage("pi-1");
    await expect.poll(() => releaseOld !== undefined).toBe(true);
    provider.sessions = [];
    await repository.refresh();
    provider.sessions = [{
      ...readyLive,
      chatPath: "/tmp/pi-page-reuse.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 43,
          processStartToken: processInstanceToken(43, "2026-08-23T00:01:00.000Z"),
          tty: "ttys013",
          cwd: live.cwd,
        },
      },
    }];
    await repository.refresh();
    oldRead = false;
    releaseOld(testChatPage("stale-old-session"));
    await oldRequest;
    await repository.chatPage("pi-1");

    expect(reconciled).toEqual(["new-session"]);
  });

  it("lets a newer delivery baseline supersede an in-flight page read", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...readyLive,
      chatPath: "/tmp/pi-page-baseline.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    }];
    const reads: Array<(page: ChatPage) => void> = [];
    const repository = new SessionRepository([provider], {
      chatPageReader: async () => new Promise<ChatPage>((resolve) => { reads.push(resolve); }),
    });
    const reconciled: string[] = [];
    let sends = 0;
    repository.setControls({
      focus: async () => undefined,
      send: async () => { sends += 1; },
      reconcileChatPage: (_session, page) => { reconciled.push(page.items[0]?.id ?? "empty"); },
    });
    await repository.refresh();

    const stalePage = repository.chatPage("pi-1");
    await expect.poll(() => reads).toHaveLength(1);
    const send = repository.chatAction({
      type: "send_chat", id: "baseline-request", sessionId: "pi-1", generation: 1,
      deliveryId: "baseline-delivery", text: "send after baseline", images: [],
    });
    await expect.poll(() => reads).toHaveLength(2);
    reads[0]!(testChatPage("stale-page"));
    await stalePage;
    reads[1]!(testChatPage("baseline", { authoritative: true }));

    expect(await send).toBeUndefined();
    expect(sends).toBe(1);
    expect(reconciled).toEqual([]);
  });

  it("stales a deferred send baseline when a newer latest page starts", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...readyLive,
      chatPath: "/tmp/pi-page-baseline-r2.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    }];
    const reads: Array<{ before?: number; resolve: (page: ChatPage) => void }> = [];
    const repository = new SessionRepository([provider], {
      chatPageReader: async (_session, before) => new Promise<ChatPage>((resolve) => {
        reads.push({ before, resolve });
      }),
    });
    const reconciled: string[] = [];
    let sends = 0;
    repository.setControls({
      focus: async () => undefined,
      send: async () => { sends += 1; },
      reconcileChatPage: (_session, page) => {
        reconciled.push(page.items[0]?.id ?? "empty");
      },
    });
    await repository.refresh();

    const send = repository.chatAction({
      type: "send_chat", id: "baseline-send-s", sessionId: "pi-1", generation: 1,
      deliveryId: "baseline-delivery-s", text: "must not send", images: [],
    });
    await expect.poll(() => reads).toHaveLength(1);

    const latest = repository.chatPage("pi-1");
    await expect.poll(() => reads).toHaveLength(2);

    // The old baseline resolves after R2 has claimed the page-read boundary.
    // It is no longer safe to register S's delivery from that page.
    reads[0]!.resolve(testChatPage("old-baseline", { authoritative: true }));
    await expect(send).resolves.toContain("changed");
    expect(sends).toBe(0);

    reads[1]!.resolve(testChatPage("latest-r2", { authoritative: true }));
    await expect(latest).resolves.toMatchObject({
      items: [{ id: "latest-r2" }],
    });
    expect(reconciled).toEqual(["latest-r2"]);
  });

  it("stops a queued send when a newer latest page invalidates its baseline", async () => {
    const provider = new FakeProvider();
    const terminalSession: DiscoveredProviderSession = {
      ...readyLive,
      chatPath: "/tmp/pi-queued-baseline.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    };
    provider.sessions = [terminalSession];
    const helper = new FakeNativeHelper();
    const controlsRoot = mkdtempSync(path.join(tmpdir(), "agent-visor-queued-controls-"));
    const controls = new NativeSessionControls(helper, controlsRoot);
    let releaseFocus!: () => void;
    let focusStarted!: () => void;
    const focusGate = new Promise<void>((resolve) => { releaseFocus = resolve; });
    const focusStartedPromise = new Promise<void>((resolve) => { focusStarted = resolve; });
    helper.focusTerminal = async (target) => {
      helper.terminalFocusRequests.push(structuredClone(target));
      focusStarted();
      await focusGate;
    };
    const reads: Array<{ before?: number; resolve: (page: ChatPage) => void }> = [];
    const repository = new SessionRepository([provider], {
      chatPageReader: async (_session, before) => new Promise<ChatPage>((resolve) => {
        reads.push({ before, resolve });
      }),
    });
    let sendCalls = 0;
    repository.setControls({
      focus: (...args) => controls.focus(...args),
      send: (...args) => {
        sendCalls += 1;
        return controls.send(...args);
      },
    });
    try {
      await repository.refresh();
      const blocked = controls.focus(terminalSession);
      await focusStartedPromise;

      const send = repository.chatAction({
        type: "send_chat", id: "queued-baseline-s", sessionId: "pi-1", generation: 1,
        deliveryId: "queued-baseline-delivery", text: "must not send", images: [],
      });
      await expect.poll(() => reads).toHaveLength(1);
      reads[0]!.resolve(testChatPage("old-baseline", { authoritative: true, complete: true }));
      await expect.poll(() => sendCalls).toBe(1);

      const latest = repository.chatPage("pi-1");
      await expect.poll(() => reads).toHaveLength(2);
      releaseFocus();

      await expect(send).resolves.toMatch(/changed|current/i);
      expect(helper.terminalSendRequests).toEqual([]);
      controls.reconcileChatPage(
        terminalSession,
        testChatPage("queued-canonical", { authoritative: true, complete: true }),
      );
      expect(controls.activeCancelDeliveryId(terminalSession)).toBeUndefined();

      reads[1]!.resolve(testChatPage("latest-r2", { authoritative: true, complete: true }));
      await expect(latest).resolves.toMatchObject({ items: [{ id: "latest-r2" }] });
      await blocked;
    } finally {
      rmSync(controlsRoot, { recursive: true, force: true });
    }
  });

  it("allows a send whose baseline resolves before a newer latest page starts", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...readyLive,
      chatPath: "/tmp/pi-page-baseline-inverse.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    }];
    const reads: Array<{ before?: number; resolve: (page: ChatPage) => void }> = [];
    const repository = new SessionRepository([provider], {
      chatPageReader: async (_session, before) => new Promise<ChatPage>((resolve) => {
        reads.push({ before, resolve });
      }),
    });
    const reconciled: string[] = [];
    let sends = 0;
    repository.setControls({
      focus: async () => undefined,
      send: async () => { sends += 1; },
      reconcileChatPage: (_session, page) => {
        reconciled.push(page.items[0]?.id ?? "empty");
      },
    });
    await repository.refresh();

    const send = repository.chatAction({
      type: "send_chat", id: "baseline-send-inverse", sessionId: "pi-1", generation: 1,
      deliveryId: "baseline-delivery-inverse", text: "send normally", images: [],
    });
    await expect.poll(() => reads).toHaveLength(1);
    reads[0]!.resolve(testChatPage("baseline", { authoritative: true }));
    await expect(send).resolves.toBeUndefined();
    expect(sends).toBe(1);

    const latest = repository.chatPage("pi-1");
    await expect.poll(() => reads).toHaveLength(2);
    reads[1]!.resolve(testChatPage("latest-r2", { authoritative: true }));
    await expect(latest).resolves.toMatchObject({
      items: [{ id: "latest-r2" }],
    });
    expect(reconciled).toEqual(["latest-r2"]);
  });

  it("keeps an authoritative earlier page fail-closed for native reconciliation", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...readyLive,
      chatPath: "/tmp/pi-earlier-authority.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    }];
    const repository = new SessionRepository([provider], {
      chatPageReader: async () => testChatPage("earlier-authoritative", { authoritative: true }),
    });
    const reconciled: boolean[] = [];
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      reconcileChatPage: (_session, _page, latest) => { reconciled.push(latest); },
    });
    await repository.refresh();

    await repository.chatPage("pi-1", 100);

    expect(reconciled).toEqual([]);
  });

  it("rejects overlapping terminal sends before they reach the provider queue", async () => {
    const provider = new FakeProvider();
    const terminalSession: DiscoveredProviderSession = {
      ...readyLive,
      chatPath: "/tmp/pi-queue-cap.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-22T08:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    };
    provider.sessions = [terminalSession];
    let releaseEvidence!: () => void;
    const evidenceGate = new Promise<void>((resolve) => { releaseEvidence = resolve; });
    let evidenceReads = 0;
    let writes = 0;
    const repository = new SessionRepository([provider], {
      chatPageReader: async () => {
        evidenceReads += 1;
        await evidenceGate;
        return {
          type: "chat_page",
          sessionId: "pi-1",
          items: [],
          hasMoreBefore: false,
          capabilities: {
            canSendText: true, canSendImages: true, canCancel: false,
            canApprove: false, canAnswer: false,
          },
          pendingAction: null,
        };
      },
    });
    repository.setControls({
      focus: async () => undefined,
      send: async () => { writes += 1; },
    });
    await repository.refresh();

    const operations = Array.from({ length: MAX_CHAT_ACTIONS_PER_SESSION }, (_, index) =>
      repository.chatAction({
        type: "send_chat", id: `queue-request-${index}`, sessionId: "pi-1", generation: 1,
        deliveryId: `queue-delivery-${index}`, text: `queued-${index}`, images: [],
      }));
    // Terminal admission reserves one next-turn slot synchronously. Only the
    // first request may reach transcript evidence; later requests wait rather
    // than queueing a competing provider turn.
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    expect(evidenceReads).toBe(1);
    expect(await repository.chatAction({
      type: "send_chat", id: "queue-request-over", sessionId: "pi-1", generation: 1,
      deliveryId: "queue-delivery-over", text: "must reject", images: [],
    })).toContain("Wait for this turn to finish");
    expect(evidenceReads).toBe(1);
    expect(writes).toBe(0);

    releaseEvidence();
    const results = await Promise.all(operations);
    expect(results[0]).toBeUndefined();
    expect(results.slice(1).every((result) => result?.includes("Wait for this turn to finish"))).toBe(true);
    expect(writes).toBe(1);
  }, 10_000);

  it("bounds repository focus reservations per session and releases them on forget and throw", async () => {
    const provider = new FakeProvider();
    const focusTarget = {
      kind: "terminal" as const,
      target: {
        application: "Ghostty" as const,
        pid: 42,
        processStartToken: processInstanceToken(42, "2026-08-22T08:00:00.000Z"),
        tty: "ttys012",
        cwd: live.cwd,
      },
    };
    const otherSession: DiscoveredProviderSession = {
      ...live,
      id: "pi-2",
      controlTarget: focusTarget,
    };
    const targetSession: DiscoveredProviderSession = {
      ...live,
      controlTarget: focusTarget,
    };
    provider.sessions = [targetSession, otherSession];
    let release!: () => void;
    let signalStarted!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const started = new Promise<void>((resolve) => { signalStarted = resolve; });
    let failFocus = false;
    const focusCalls: string[] = [];
    const repository = new SessionRepository([provider]);
    repository.setControls({
      focus: async (session) => {
        focusCalls.push(session.id);
        if (failFocus) throw new Error("focus failed");
        if (session.id === "pi-1") {
          signalStarted();
          await gate;
        }
      },
      send: async () => undefined,
    });
    await repository.refresh();

    const head = repository.focusSession("pi-1");
    await started;
    const admitted = Array.from({ length: MAX_CHAT_ACTIONS_PER_SESSION - 1 }, () =>
      repository.focusSession("pi-1"));
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    expect(focusCalls.filter((id) => id === "pi-1")).toHaveLength(MAX_CHAT_ACTIONS_PER_SESSION);
    await expect(repository.focusSession("pi-1")).resolves.toContain("Too many chat actions");

    // Admission is scoped by session: another session still reaches its
    // provider control while pi-1's head remains blocked.
    await expect(repository.focusSession("pi-2")).resolves.toBeUndefined();
    expect(focusCalls).toContain("pi-2");

    // Removing the session invalidates the admitted work. Releasing the head
    // must still release every operation-owned reservation before ID reuse.
    provider.sessions = [otherSession];
    await repository.refresh();
    release();
    await expect(Promise.all([head, ...admitted])).resolves.toEqual(
      [undefined, ...Array.from({ length: MAX_CHAT_ACTIONS_PER_SESSION - 1 }, () => undefined)],
    );
    provider.sessions = [targetSession, otherSession];
    await repository.refresh();
    await expect(repository.focusSession("pi-1")).resolves.toBeUndefined();

    // Provider errors also release their reservation rather than slowly
    // filling the bounded set with failed operations.
    failFocus = true;
    const failed: Array<string | undefined> = [];
    for (let index = 0; index < MAX_CHAT_ACTIONS_PER_SESSION + 1; index += 1) {
      failed.push(await repository.focusSession("pi-1"));
    }
    expect(failed.every((result) => result === "focus failed")).toBe(true);
  }, 10_000);

  it("bounds repository cancellation reservations, preserves other sessions, and reuses after forget", async () => {
    const provider = new FakeProvider();
    const terminalSession: DiscoveredProviderSession = {
      ...live,
      chatPath: "/tmp/pi-queue-cancel.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-22T08:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    };
    const otherSession: DiscoveredProviderSession = {
      ...terminalSession,
      id: "pi-2",
      controlTarget: {
        kind: "terminal",
        target: {
          ...terminalSession.controlTarget!.target,
          pid: 43,
          processStartToken: processInstanceToken(43, "2026-08-22T08:00:01.000Z"),
          tty: "ttys013",
        },
      },
    };
    provider.sessions = [terminalSession, otherSession];
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let cancelCalls = 0;
    const canceledSessions: string[] = [];
    const page = (sessionId: string): ChatPage => ({
      type: "chat_page", sessionId, items: [], hasMoreBefore: false,
      capabilities: {
        canSendText: true, canSendImages: true, canCancel: true,
        canApprove: false, canAnswer: false,
      },
      pendingAction: null,
    });
    const repository = new SessionRepository([provider], {
      chatPageReader: async (session) => page(session.id),
    });
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      canCancel: () => true,
      reconcileChatPage: () => undefined,
      cancel: async (session) => {
        cancelCalls += 1;
        canceledSessions.push(session.id);
        await gate;
      },
      clear: () => undefined,
    });
    await repository.refresh();

    const makeCancel = (sessionId: string, index: number) => repository.chatAction({
      type: "cancel_chat", id: `cancel-queue-${sessionId}-${index}`,
      sessionId, generation: 1, deliveryId: `delivery-queue-${sessionId}-${index}`,
    });
    const admitted = Array.from({ length: MAX_CHAT_ACTIONS_PER_SESSION }, (_, index) =>
      makeCancel("pi-1", index));
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    expect(cancelCalls).toBe(MAX_CHAT_ACTIONS_PER_SESSION);
    await expect(makeCancel("pi-1", MAX_CHAT_ACTIONS_PER_SESSION))
      .resolves.toContain("Too many chat actions");
    expect(cancelCalls).toBe(MAX_CHAT_ACTIONS_PER_SESSION);

    // A separate session has an independent reservation set and can invoke
    // its provider control even while pi-1 is saturated.
    const other = makeCancel("pi-2", 0);
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    expect(canceledSessions).toContain("pi-2");

    provider.sessions = [otherSession];
    await repository.refresh();
    release();
    await Promise.all(admitted);
    await other;

    // The old session ID can be reused only after its in-flight reservations
    // settle; the fresh generation is not blocked by the prior cap.
    provider.sessions = [terminalSession, otherSession];
    await repository.refresh();
    const reused = makeCancel("pi-1", 99);
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    expect(cancelCalls).toBe(MAX_CHAT_ACTIONS_PER_SESSION + 2);
    release();
    await expect(reused).resolves.toBeUndefined();
  }, 10_000);

  it("keeps a deferred send stale through 513 forgets and same-ID reuse", async () => {
    const provider = new FakeProvider();
    const terminalSession: DiscoveredProviderSession = {
      ...readyLive,
      chatPath: "/tmp/pi-chat.jsonl",
      messageTransport: "terminal",
      controlTarget: { kind: "terminal", target: {
        application: "Ghostty",
        pid: 42,
        processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
        tty: "ttys012",
        cwd: live.cwd,
      } },
    };
    provider.sessions = [terminalSession];
    let releaseEvidence!: (page: ChatPage) => void;
    let evidenceStarted!: () => void;
    const started = new Promise<void>((resolve) => { evidenceStarted = resolve; });
    const evidence = new Promise<ChatPage>((resolve) => { releaseEvidence = resolve; });
    let writes = 0;
    const emptyPage = (): ChatPage => ({
      type: "chat_page", sessionId: "pi-1", items: [], hasMoreBefore: false,
      capabilities: { canSendText: true, canSendImages: true, canCancel: false, canApprove: false, canAnswer: false },
      pendingAction: null,
    });
    const repository = new SessionRepository([provider], {
      chatPageReader: async () => {
        evidenceStarted();
        return evidence;
      },
    });
    repository.setControls({
      focus: async () => undefined,
      send: async () => { writes += 1; },
    });
    await repository.refresh();
    const message = {
      type: "send_chat" as const, id: "reused-request", sessionId: "pi-1", generation: 1,
      deliveryId: "reused-delivery", text: "send once", images: [],
    };
    const old = repository.chatAction(message);
    await started;

    provider.sessions = [];
    await repository.refresh();
    provider.sessions = Array.from({ length: 513 }, (_, index) => ({
      ...terminalSession, id: `unrelated-${index}`, chatPath: undefined,
    }));
    await repository.refresh();
    provider.sessions = [];
    await repository.refresh();
    provider.sessions = [terminalSession];
    await repository.refresh();

    expect(await repository.chatAction(message)).toContain("still settling");
    releaseEvidence(emptyPage());
    expect(await old).toContain("changed");
    expect(writes).toBe(0);

    // Once the stale operation releases, the same identity may be used by
    // the new authoritative session and performs exactly one fresh send.
    expect(await repository.chatAction(message)).toBeUndefined();
    expect(writes).toBe(1);
  }, 30_000);

  it("does not let a stale send failure clear a reused delivery", async () => {
    const provider = new FakeProvider();
    const terminalSession: DiscoveredProviderSession = {
      ...readyLive,
      chatPath: "/tmp/pi-chat-reused-delivery.jsonl",
      messageTransport: "terminal",
      controlTarget: { kind: "terminal", target: {
        application: "Ghostty",
        pid: 42,
        processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
        tty: "ttys012",
        cwd: live.cwd,
      } },
    };
    provider.sessions = [terminalSession];
    const emptyPage = (): ChatPage => ({
      type: "chat_page", sessionId: "pi-1", items: [], hasMoreBefore: false,
      capabilities: { canSendText: true, canSendImages: true, canCancel: false, canApprove: false, canAnswer: false },
      pendingAction: null,
    });
    let rejectOld!: (error: Error) => void;
    let oldStarted!: () => void;
    const oldStartedPromise = new Promise<void>((resolve) => { oldStarted = resolve; });
    const oldFailure = new Promise<void>((_resolve, reject) => { rejectOld = reject; });
    let sendCalls = 0;
    const retainedDeliveries = new Set<string>();
    let clearCalls = 0;
    const repository = new SessionRepository([provider], {
      chatPageReader: async () => emptyPage(),
    });
    repository.setControls({
      focus: async () => undefined,
      send: async (_session, _text, _images, deliveryId) => {
        sendCalls += 1;
        if (sendCalls === 1) {
          oldStarted();
          await oldFailure;
          return;
        }
        if (deliveryId) retainedDeliveries.add(deliveryId);
      },
      clear: (_sessionId, deliveryId) => {
        clearCalls += 1;
        if (deliveryId) retainedDeliveries.delete(deliveryId);
      },
    });
    await repository.refresh();

    const old = repository.chatAction({
      type: "send_chat", id: "old-reused-request", sessionId: "pi-1", generation: 1,
      deliveryId: "reused-delivery", text: "old", images: [],
    });
    await oldStartedPromise;

    provider.sessions = [];
    await repository.refresh();
    provider.sessions = [terminalSession];
    await repository.refresh();

    const replacement = repository.chatAction({
      type: "send_chat", id: "new-reused-request", sessionId: "pi-1", generation: 1,
      deliveryId: "reused-delivery", text: "new", images: [],
    });
    await expect(replacement).resolves.toBeUndefined();
    expect(retainedDeliveries).toContain("reused-delivery");

    rejectOld(new Error("old provider failure"));
    await expect(old).resolves.toContain("changed");
    expect(clearCalls).toBe(0);
    expect(retainedDeliveries).toContain("reused-delivery");
  });

  it("does not let a deferred cancel mutate a reused session after 513 forgets", async () => {
    const provider = new FakeProvider();
    const terminalSession: DiscoveredProviderSession = {
      ...live,
      chatPath: "/tmp/pi-chat.jsonl",
      messageTransport: "terminal",
      controlTarget: { kind: "terminal", target: {
        application: "Ghostty",
        pid: 42,
        processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
        tty: "ttys012",
        cwd: live.cwd,
      } },
    };
    provider.sessions = [terminalSession];
    let releaseCancel!: () => void;
    let cancelStarted!: () => void;
    const started = new Promise<void>((resolve) => { cancelStarted = resolve; });
    const gate = new Promise<void>((resolve) => { releaseCancel = resolve; });
    let cancelCalls = 0;
    let clearCalls = 0;
    const repository = new SessionRepository([provider]);
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      canCancel: () => true,
      cancel: async () => {
        cancelCalls += 1;
        if (cancelCalls === 1) {
          cancelStarted();
          await gate;
        }
      },
      clear: () => { clearCalls += 1; },
    });
    await repository.refresh();
    const message = {
      type: "cancel_chat" as const, id: "cancel-reused", sessionId: "pi-1", generation: 1,
      deliveryId: "delivery-reused",
    };
    const old = repository.chatAction(message);
    await started;

    provider.sessions = [];
    await repository.refresh();
    provider.sessions = Array.from({ length: 513 }, (_, index) => ({
      ...terminalSession, id: `cancel-unrelated-${index}`, chatPath: undefined,
    }));
    await repository.refresh();
    provider.sessions = [];
    await repository.refresh();
    provider.sessions = [terminalSession];
    await repository.refresh();

    releaseCancel();
    expect(await old).toContain("changed");
    expect(clearCalls).toBe(0);
    expect(await repository.chatAction(message)).toBeUndefined();
    expect(cancelCalls).toBe(2);
    expect(clearCalls).toBe(1);
  });

  it("deduplicates a replay after the original action response is lost", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...readyLive,
      chatPath: "/tmp/pi.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    }];
    let release!: () => void;
    let startedResolve!: () => void;
    const started = new Promise<void>((resolve) => { startedResolve = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let writes = 0;
    const repository = new SessionRepository([provider]);
    repository.setControls({
      focus: async () => undefined,
      send: async () => { writes += 1; startedResolve(); await gate; },
    });
    await repository.refresh();
    const message = {
      type: "send_chat" as const, id: "lost-response", sessionId: "pi-1", generation: 1,
      deliveryId: "delivery-lost", text: "send once", images: [],
    };
    const first = repository.chatAction(message);
    await started;
    const replay = repository.chatAction(message);
    release();
    expect(await first).toBeUndefined();
    expect(await replay).toBeUndefined();
    expect(await repository.chatAction(message)).toBeUndefined();
    expect(writes).toBe(1);
  });

  it("rejects conflicting request and delivery identity reuse symmetrically", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...readyLive,
      chatPath: "/tmp/pi.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    }];
    let writes = 0;
    const repository = new SessionRepository([provider]);
    repository.setControls({
      focus: async () => undefined,
      send: async () => { writes += 1; },
    });
    await repository.refresh();
    const base = {
      type: "send_chat" as const, sessionId: "pi-1", generation: 1,
      text: "send once", images: [],
    };
    expect(await repository.chatAction({ ...base, id: "request-one", deliveryId: "delivery-one" }))
      .toBeUndefined();
    // Exact replay is safe even after the provider call has completed.
    expect(await repository.chatAction({ ...base, id: "request-one", deliveryId: "delivery-one" }))
      .toBeUndefined();
    expect(await repository.chatAction({ ...base, id: "request-one", deliveryId: "delivery-two" }))
      .toContain("request ID");
    expect(await repository.chatAction({ ...base, id: "request-two", deliveryId: "delivery-one" }))
      .toContain("delivery ID");
    expect(writes).toBe(1);
  });

  it("does not let a future open or send generation poison the live chat scope", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{ ...readyLive, chatPath: "/tmp/pi.jsonl", messageTransport: "terminal",
      controlTarget: { kind: "terminal", target: {
        application: "Ghostty", pid: 42,
        processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
        tty: "ttys012", cwd: live.cwd,
      } } }];
    let writes = 0;
    const repository = new SessionRepository([provider]);
    repository.setControls({ focus: async () => undefined, send: async () => { writes += 1; } });
    await repository.refresh();

    // The authoritative initial scope is generation 1. A crafted future open
    // is rejected and cannot move the send generation forward.
    expect((await repository.chatPage("pi-1", undefined, undefined, 99)).capabilities.canSendText)
      .toBe(false);
    expect(await repository.chatAction({
      type: "send_chat", id: "future", sessionId: "pi-1", generation: 99,
      deliveryId: "future-delivery", text: "must not send", images: [],
    })).toContain("generation");
    expect(await repository.chatAction({
      type: "send_chat", id: "valid", sessionId: "pi-1", generation: 1,
      deliveryId: "valid-delivery", text: "send", images: [],
    })).toBeUndefined();
    expect(writes).toBe(1);
  });

  it("advances generation only through a bounded authoritative open transition", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{ ...readyLive, chatPath: "/tmp/pi.jsonl", messageTransport: "terminal",
      controlTarget: { kind: "terminal", target: {
        application: "Ghostty", pid: 42,
        processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
        tty: "ttys012", cwd: live.cwd,
      } } }];
    let writes = 0;
    const repository = new SessionRepository([provider]);
    repository.setControls({ focus: async () => undefined, send: async () => { writes += 1; } });
    await repository.refresh();
    expect((await repository.chatPage("pi-1", undefined, undefined, 2)).capabilities.canSendText)
      .toBe(true);
    expect(await repository.chatAction({
      type: "send_chat", id: "next", sessionId: "pi-1", generation: 2,
      deliveryId: "next-delivery", text: "send next", images: [],
    })).toBeUndefined();
    expect(writes).toBe(1);
    expect(await repository.chatAction({
      type: "send_chat", id: "old", sessionId: "pi-1", generation: 1,
      deliveryId: "old-delivery", text: "must not send", images: [],
    })).toContain("older");
  });

  it("forgets send reservations and results when a live session is removed", async () => {
    const provider = new FakeProvider();
    const terminalSession = {
      ...readyLive,
      chatPath: "/tmp/pi.jsonl",
      messageTransport: "terminal" as const,
      controlTarget: { kind: "terminal" as const, target: {
        application: "Ghostty" as const,
        pid: 42,
        processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
        tty: "ttys012",
        cwd: live.cwd,
      } },
    };
    provider.sessions = [terminalSession];
    let writes = 0;
    const repository = new SessionRepository([provider]);
    repository.setControls({ focus: async () => undefined, send: async () => { writes += 1; } });
    await repository.refresh();
    const message = {
      type: "send_chat" as const, id: "reused-request", sessionId: "pi-1", generation: 1,
      deliveryId: "reused-delivery", text: "send again", images: [],
    };
    expect(await repository.chatAction(message)).toBeUndefined();
    provider.sessions = [];
    await repository.refresh();
    provider.sessions = [terminalSession];
    await repository.refresh();
    expect(await repository.chatAction(message)).toBeUndefined();
    expect(writes).toBe(2);
  });

  it("publishes only the live active delivery identity for Chat cancellation", async () => {
    const provider = new FakeProvider();
    const transcript = temporaryTranscript("2026-08-23T00:00:00.000Z");
    provider.sessions = [{
      ...live,
      chatPath: transcript.path,
      messageTransport: "codex_app_server",
      provider: "codex",
    }];
    const repository = new SessionRepository([provider]);
    let activeDelivery: string | undefined = "delivery-codex";
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      activeCancelDeliveryId: () => activeDelivery,
      canCancel: (_session, deliveryId) => deliveryId === activeDelivery,
    });
    try {
      await repository.refresh();
      expect((await repository.chatPage("pi-1")).capabilities).toMatchObject({
        canCancel: true,
        cancelDeliveryId: "delivery-codex",
      });

      activeDelivery = undefined;
      expect((await repository.chatPage("pi-1")).capabilities).toMatchObject({ canCancel: false });
      expect((await repository.chatPage("pi-1")).capabilities.cancelDeliveryId).toBeUndefined();
    } finally {
      transcript.remove();
    }
  });

  it("captures a terminal baseline and rechecks the latest canonical turn before cancel", async () => {
    const transcript = temporaryTranscript("2026-08-23T00:00:00.000Z");
    const provider = new FakeProvider();
    provider.sessions = [{
      ...readyLive,
      chatPath: transcript.path,
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    }];
    let sentEvidence: unknown;
    let active = false;
    let cancelCalls = 0;
    const repository = new SessionRepository([provider], {
      now: () => new Date("2026-08-23T00:00:00.000Z"),
    });
    repository.setControls({
      focus: async () => undefined,
      send: async (...args) => { sentEvidence = args[4]; },
      reconcileChatPage: (_session, page) => {
        const users = page.items.filter((item) => item.kind === "user");
        active = users.at(-1)?.id === "after";
      },
      activeCancelDeliveryId: () => active ? "delivery-1" : undefined,
      canCancel: (_session, deliveryId) => active && deliveryId === "delivery-1",
      cancel: async () => { cancelCalls += 1; },
    });
    try {
      writeFileSync(transcript.path, `${piUserLine("before", "Same prompt")}\n`);
      await repository.refresh();
      expect(await repository.chatAction({
        type: "send_chat", id: "request-1", sessionId: "pi-1", generation: 1,
        deliveryId: "delivery-1", text: "Same prompt", images: [],
      })).toBeUndefined();
      expect(sentEvidence).toEqual({
        baselineUserEntryIds: ["before"],
        baselineComplete: true,
        submittedText: "Same prompt",
        requestId: "request-1",
        generation: 1,
        authoritativeComplete: true,
        submittedAt: "2026-08-23T00:00:00.000Z",
        baselineSourceTimestamp: "2026-08-23T00:00:00.000Z",
      });
      expect((await repository.chatPage("pi-1")).capabilities).toMatchObject({
        canCancel: false,
      });

      writeFileSync(transcript.path, `${piUserLine("before", "Same prompt")}\n${piUserLine("after", "Same prompt")}\n`);
      expect((await repository.chatPage("pi-1")).capabilities).toMatchObject({
        canCancel: true, cancelDeliveryId: "delivery-1",
      });

      // A later same-target turn must invalidate the old delivery before Escape.
      writeFileSync(transcript.path, `${piUserLine("before", "Same prompt")}\n${piUserLine("after", "Same prompt")}\n${piUserLine("external", "Other turn")}\n`);
      expect(await repository.chatAction({
        type: "cancel_chat", id: "cancel-1", sessionId: "pi-1", generation: 1,
        deliveryId: "delivery-1",
      })).toContain("unavailable");
      expect(cancelCalls).toBe(0);
    } finally {
      transcript.remove();
    }
  });

  it("reconciles native controls from authoritative lifecycle and target snapshots", async () => {
    const provider = new FakeProvider();
    const transcript = temporaryTranscript("2026-08-23T00:00:00.000Z");
    provider.sessions = [{
      ...live,
      chatPath: transcript.path,
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: { application: "Ghostty", tty: "ttys012", cwd: live.cwd },
      },
    }];
    const repository = new SessionRepository([provider]);
    const reconciled: DiscoveredProviderSession[] = [];
    const cleared: Array<{ sessionId: string; deliveryId?: string }> = [];
    const forgotten: string[] = [];
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      reconcile: (session) => { reconciled.push(structuredClone(session)); },
      clear: (sessionId, deliveryId) => { cleared.push({ sessionId, deliveryId }); },
      forget: (sessionId) => { forgotten.push(sessionId); },
    });
    try {
      await repository.refresh();
      expect(reconciled.at(-1)).toMatchObject({
        id: "pi-1", section: "working",
        controlTarget: { kind: "terminal", target: { tty: "ttys012" } },
      });

      provider.sessions[0] = { ...provider.sessions[0]!, section: "ready" };
      await repository.refresh();
      expect(reconciled.at(-1)?.section).toBe("ready");

      provider.sessions[0] = {
        ...provider.sessions[0]!,
        section: "working",
        controlTarget: {
          kind: "terminal",
          target: { application: "Ghostty", tty: "ttys013", cwd: live.cwd },
        },
      };
      await repository.refresh();
      expect(reconciled.at(-1)).toMatchObject({
        section: "working",
        controlTarget: { kind: "terminal", target: { tty: "ttys013" } },
      });

      const reconciledBeforePage = reconciled.length;
      await repository.chatPage("pi-1");
      expect(reconciled.length).toBe(reconciledBeforePage + 1);

      provider.sessions = [];
      await repository.refresh();
      expect(forgotten).toContain("pi-1");
      expect(cleared).not.toContainEqual({ sessionId: "pi-1" });
    } finally {
      transcript.remove();
    }
  });

  it("re-checks live send capabilities and section before dispatching crafted messages", async () => {
    const provider = new FakeProvider();
    const target = {
      kind: "terminal" as const,
      target: {
        application: "Ghostty" as const,
        pid: 42,
        processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
        tty: "ttys012",
        cwd: live.cwd,
      },
    };
    provider.sessions = [{
      ...readyLive, chatPath: "/tmp/pi.jsonl", messageTransport: "terminal", controlTarget: target,
    }];
    const repository = new SessionRepository([provider]);
    const sends: unknown[][] = [];
    repository.setControls({
      focus: async () => undefined,
      send: async (...args) => { sends.push(args); },
    });
    await repository.refresh();

    const validImage = {
      name: "pixel.png",
      mimeType: "image/png" as const,
      byteLength: 8,
      data: "iVBORw0KGgo=",
    };
    expect(await repository.chatAction({
      type: "send_chat", id: "send-working", sessionId: "pi-1", generation: 1,
      deliveryId: "delivery-working", text: "Continue", images: [],
    })).toBeUndefined();
    expect(sends).toHaveLength(1);

    const settleTurn = async (updatedAt: string) => {
      provider.sessions[0] = {
        ...provider.sessions[0]!, section: "working", turnState: "working", updatedAt,
      };
      await repository.refresh();
      provider.sessions[0] = {
        ...provider.sessions[0]!, section: "ready", turnState: "ready",
        updatedAt: new Date(Date.parse(updatedAt) + 1_000).toISOString(),
      };
      await repository.refresh();
    };
    await settleTurn("2026-08-23T00:00:01.000Z");

    for (const section of ["ready", "history"] as const) {
      provider.sessions[0] = {
        ...provider.sessions[0]!, section, turnState: "ready", conversationState: "open",
      };
      await repository.refresh();
      expect(await repository.chatAction({
        type: "send_chat", id: `send-${section}`, sessionId: "pi-1", generation: 1,
        deliveryId: `delivery-${section}`, text: "Continue", images: [],
      })).toBeUndefined();
      await settleTurn(section === "ready"
        ? "2026-08-23T00:00:02.000Z"
        : "2026-08-23T00:00:04.000Z");
    }

    provider.sessions[0] = {
      ...provider.sessions[0]!, section: "working", turnState: "ready", provider: "cursor",
    };
    await repository.refresh();
    expect(await repository.chatAction({
      type: "send_chat", id: "send-unsupported", sessionId: "pi-1", generation: 1,
      deliveryId: "delivery-unsupported", text: "Do not send", images: [],
    })).toContain("unavailable");

    provider.sessions[0] = {
      ...provider.sessions[0]!, provider: "claude_code", section: "ready", turnState: "ready",
      conversationState: "open", messageTransport: "terminal",
      controlTarget: { kind: "terminal", target: { ...target.target, application: "Terminal" } },
    };
    await repository.refresh();
    expect(await repository.chatAction({
      type: "send_chat", id: "send-image", sessionId: "pi-1", generation: 1,
      deliveryId: "delivery-image", text: "Do not send", images: [validImage],
    })).toContain("Image sending is unavailable");
    expect(sends).toHaveLength(3);
  });

  it("reports terminal chat as read only when the native helper is unavailable", async () => {
    const transcript = temporaryTranscript("2026-08-23T00:00:00.000Z");
    const provider = new FakeProvider();
    provider.sessions = [{
      ...readyLive,
      chatPath: transcript.path,
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    }];
    let available = false;
    let sends = 0;
    const repository = new SessionRepository([provider]);
    repository.setControls({
      isAvailable: () => available,
      focus: async () => undefined,
      send: async () => { sends += 1; },
    });
    try {
      await repository.refresh();
      expect((await repository.chatPage("pi-1")).capabilities).toMatchObject({
        canSendText: false,
        canSendImages: false,
        canCancel: false,
        readOnlyReason: "The native helper is unavailable. Terminal chat is read only until it recovers.",
      });
      expect(await repository.chatAction({
        type: "send_chat", id: "helper-down", sessionId: "pi-1", generation: 1,
        deliveryId: "delivery-helper-down", text: "must not write", images: [],
      })).toContain("native helper");
      expect(sends).toBe(0);

      available = true;
      expect((await repository.chatPage("pi-1")).capabilities.canSendText).toBe(true);
      available = false;
      expect(await repository.chatAction({
        type: "send_chat", id: "helper-disappeared", sessionId: "pi-1", generation: 1,
        deliveryId: "delivery-helper-disappeared", text: "must still not write", images: [],
      })).toContain("native helper");
      expect(sends).toBe(0);
    } finally {
      transcript.remove();
    }
  });

  it("demotes an opened Ready completion until the next Ready episode", async () => {
    const provider = new FakeProvider();
    provider.sessions = [{
      ...live,
      section: "ready",
      subtitle: "Ready to continue",
      controlTarget: {
        kind: "terminal",
        target: { application: "Ghostty", tty: "ttys012", cwd: live.cwd },
      },
    }];
    const repository = new SessionRepository([provider]);
    repository.setControls({ focus: async () => undefined, send: async () => undefined });

    expect((await repository.refresh()).sessions[0]?.attentionTier).toBe("ready");

    expect(await repository.focusSession("pi-1")).toBeUndefined();
    expect(repository.current().sessions[0]?.attentionTier).toBe("acknowledged_ready");

    provider.sessions[0] = { ...provider.sessions[0]!, section: "working" };
    expect((await repository.refresh()).sessions[0]?.attentionTier).toBe("working");
    provider.sessions[0] = { ...provider.sessions[0]!, section: "ready" };
    expect((await repository.refresh()).sessions[0]?.attentionTier).toBe("ready");
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

  it("reserves a terminal next turn before concurrent sends can queue", async () => {
    const terminalSession: DiscoveredProviderSession = {
      ...live,
      id: "terminal-send-race",
      section: "ready",
      turnState: "ready",
      conversationState: "open",
      updatedAt: "2026-08-23T00:00:00.000Z",
      chatPath: "/tmp/terminal-send-race.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 42,
          processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
          tty: "ttys012",
          cwd: live.cwd,
        },
      },
    };
    const provider = new FakeProvider();
    provider.sessions = [terminalSession];
    let releaseSend!: () => void;
    let sendStarted!: () => void;
    const sendGate = new Promise<void>((resolve) => { releaseSend = resolve; });
    const sendStartedPromise = new Promise<void>((resolve) => { sendStarted = resolve; });
    let sends = 0;
    const repository = new SessionRepository([provider], {
      chatPageReader: async () => ({
        ...testChatPage("terminal-baseline"),
        sessionId: terminalSession.id,
      }),
    });
    repository.setControls({
      focus: async () => undefined,
      send: async () => {
        sends += 1;
        sendStarted();
        await sendGate;
      },
    });

    await repository.refresh();
    const first = repository.chatAction({
      type: "send_chat", id: "terminal-race-first", sessionId: terminalSession.id,
      generation: 1, deliveryId: "terminal-race-delivery-first", text: "first", images: [],
    });
    await sendStartedPromise;

    expect(repository.current().sessions[0]).toMatchObject({
      id: terminalSession.id,
      section: "working",
      sessionState: { turn: "working", route: "waiting", unavailableReason: "turn_in_progress" },
    });
    expect((await repository.chatPage(terminalSession.id)).capabilities).toMatchObject({
      canSendText: false,
      unavailableReason: "turn_in_progress",
    });

    await expect(repository.chatAction({
      type: "send_chat", id: "terminal-race-second", sessionId: terminalSession.id,
      generation: 1, deliveryId: "terminal-race-delivery-second", text: "second", images: [],
    })).resolves.toContain("Wait for this turn to finish");
    expect(sends).toBe(1);

    releaseSend();
    await expect(first).resolves.toBeUndefined();

    provider.sessions = [{
      ...terminalSession,
      section: "ready",
      turnState: "ready",
      updatedAt: "2026-08-23T00:00:01.000Z",
    }];
    // A transcript timestamp can advance before the provider exposes the
    // post-send Working boundary. Raw Ready metadata must not reopen Send.
    expect((await repository.refresh()).sessions[0]).toMatchObject({
      section: "working",
      sessionState: { turn: "working", route: "waiting", unavailableReason: "turn_in_progress" },
    });
    await expect(repository.chatAction({
      type: "send_chat", id: "terminal-race-stale-ready", sessionId: terminalSession.id,
      generation: 1, deliveryId: "terminal-race-delivery-stale-ready", text: "stale", images: [],
    })).resolves.toContain("Wait for this turn to finish");
    expect(sends).toBe(1);

    provider.sessions = [{
      ...terminalSession,
      section: "working",
      turnState: "working",
      updatedAt: "2026-08-23T00:00:02.000Z",
    }];
    expect((await repository.refresh()).sessions[0]).toMatchObject({
      section: "working",
      sessionState: { turn: "working", route: "waiting", unavailableReason: "turn_in_progress" },
    });

    provider.sessions = [{
      ...terminalSession,
      section: "ready",
      turnState: "ready",
      updatedAt: "2026-08-23T00:00:03.000Z",
    }];
    expect((await repository.refresh()).sessions[0]).toMatchObject({
      section: "ready",
      sessionState: { turn: "ready", route: "available" },
    });
    await expect(repository.chatAction({
      type: "send_chat", id: "terminal-race-third", sessionId: terminalSession.id,
      generation: 1, deliveryId: "terminal-race-delivery-third", text: "third", images: [],
    })).resolves.toBeUndefined();
    expect(sends).toBe(2);
  });

  it("does not settle from a cached Working row after an older Ready hook", async () => {
    const terminalSession: DiscoveredProviderSession = {
      ...live,
      id: "terminal-cached-working",
      section: "working",
      turnState: "working",
      conversationState: "open",
      updatedAt: "2026-08-23T00:00:00.000Z",
      chatPath: "/tmp/terminal-cached-working.jsonl",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: {
          application: "Ghostty",
          pid: 43,
          processStartToken: processInstanceToken(43, "2026-08-23T00:00:00.000Z"),
          tty: "ttys013",
          cwd: live.cwd,
        },
      },
    };
    let failProviderDiscovery = false;
    let providerSession = terminalSession;
    const provider: ProviderAdapter = {
      id: "pi",
      discover: async () => {
        if (failProviderDiscovery) throw new Error("simulated provider outage");
        return [structuredClone(providerSession)];
      },
    };
    const unrelatedProvider: ProviderAdapter = {
      id: "zed",
      discover: async () => [{
        ...readyLive,
        id: "unrelated-zed-session",
        provider: "zed",
        owner: "Zed",
      }],
    };
    let sends = 0;
    const repository = new SessionRepository([provider, unrelatedProvider], {
      chatPageReader: async () => ({
        ...testChatPage("terminal-cached-working-baseline"),
        sessionId: terminalSession.id,
      }),
    });
    repository.setControls({
      focus: async () => undefined,
      send: async () => { sends += 1; },
    });

    await repository.refresh();
    // This Ready boundary predates the send. It makes the raw cached Working
    // row look continuable, but it cannot prove the next turn's lifecycle.
    repository.applyHook({
      sessionId: terminalSession.id,
      cwd: terminalSession.cwd,
      provider: "pi",
      event: "Stop",
      status: "idle",
      receivedAt: "2026-08-23T00:00:01.000Z",
      pid: 43,
      tty: "ttys013",
    });
    expect(repository.current().sessions[0]).toMatchObject({
      id: terminalSession.id,
      section: "ready",
      sessionState: { turn: "ready", route: "available" },
    });

    await expect(repository.chatAction({
      type: "send_chat", id: "terminal-cached-working-send", sessionId: terminalSession.id,
      generation: 1, deliveryId: "terminal-cached-working-delivery", text: "first", images: [],
    })).resolves.toBeUndefined();
    expect(sends).toBe(1);

    // A first fresh raw Ready refresh still has no post-admission Working
    // boundary. The stale cached Working row must not count as that boundary.
    providerSession = {
      ...terminalSession,
      section: "ready",
      turnState: "ready",
      updatedAt: "2026-08-23T00:00:02.000Z",
    };
    // A failed target-provider discovery must not consume the unrelated
    // provider's successful refresh as lifecycle evidence for this turn.
    failProviderDiscovery = true;
    expect((await repository.refresh()).sessions.find(({ id }) => id === terminalSession.id)).toMatchObject({
      section: "working",
      sessionState: { turn: "working", route: "waiting", unavailableReason: "turn_in_progress" },
    });
    failProviderDiscovery = false;
    expect((await repository.refresh()).sessions.find(({ id }) => id === terminalSession.id)).toMatchObject({
      section: "working",
      sessionState: { turn: "working", route: "waiting", unavailableReason: "turn_in_progress" },
    });
    await expect(repository.chatAction({
      type: "send_chat", id: "terminal-cached-working-second", sessionId: terminalSession.id,
      generation: 1, deliveryId: "terminal-cached-working-second-delivery", text: "second", images: [],
    })).resolves.toContain("Wait for this turn to finish");
    expect(sends).toBe(1);
  });

  it("opens Codex Chat read-only without acquiring or releasing a writer", async () => {
    const sessionId = "codex-chat-read-only-open";
    const session: DiscoveredProviderSession = {
      ...readyLive,
      id: sessionId,
      provider: "codex",
      owner: "Codex",
      routeState: "available",
      routeOwnership: "unverified",
      conversationState: "open",
      chatPath: "/tmp/codex-chat-read-only-open.jsonl",
      messageTransport: "codex_app_server",
      controlTarget: { kind: "url", url: `codex://threads/${sessionId}` },
    };
    const provider: ProviderAdapter = {
      id: "codex",
      discover: async () => [structuredClone(session)],
      resolve: async (id) => id === sessionId ? structuredClone(session) : undefined,
    };
    let statusReads = 0;
    const repository = new SessionRepository([provider]);
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      codexRouteStatus: () => {
        statusReads += 1;
        return { routeState: "unavailable", unavailableReason: "provider_unavailable" };
      },
    });
    await repository.refresh();

    await expect(repository.chatOpened(sessionId, "lease-A")).resolves.toBeUndefined();
    expect(statusReads).toBe(0);
    await expect(repository.chatRetry(sessionId)).resolves.toBeUndefined();
    // Retry performs a read-only live probe before the exact provider read so
    // a closing native child cannot be mistaken for a released route.
    expect(statusReads).toBe(1);
    repository.chatClosed(sessionId, "lease-A");
    expect(statusReads).toBe(1);
    expect(repository.current().sessions.find(({ id }) => id === sessionId)).toMatchObject({
      sessionState: { route: "available", routeOwnership: "unverified" },
    });
  });

  it("keeps a fast completed Codex send Ready after the send acknowledgement", async () => {
    const sessionId = "codex-fast-complete-projection";
    const session: DiscoveredProviderSession = {
      ...readyLive,
      id: sessionId,
      provider: "codex",
      owner: "Codex",
      routeState: "available",
      routeOwnership: "unverified",
      conversationState: "open",
      chatPath: "/tmp/codex-fast-complete-projection.jsonl",
      messageTransport: "codex_app_server",
      controlTarget: { kind: "url", url: `codex://threads/${sessionId}` },
    };
    const provider: ProviderAdapter = {
      id: "codex",
      discover: async () => [structuredClone(session)],
    };
    let sends = 0;
    const repository = new SessionRepository([provider]);
    repository.setControls({
      focus: async () => undefined,
      send: async () => { sends += 1; },
      codexRouteStatus: () => ({ routeState: "available", turnState: "ready" }),
    });
    await repository.refresh();

    await expect(repository.chatAction({
      type: "send_chat", id: "fast-complete-request", sessionId, generation: 1,
      deliveryId: "fast-complete-delivery", text: "already completed", images: [],
    })).resolves.toBeUndefined();
    expect(sends).toBe(1);
    expect(repository.chatRecord(sessionId)).toMatchObject({
      section: "ready", turnState: "ready", routeState: "available",
    });
    expect(repository.current().sessions.find(({ id }) => id === sessionId)).toMatchObject({
      sessionState: { turn: "ready", route: "available" },
    });
  });

  it("preserves a closing terminal probe and restores tentative readiness after release", async () => {
    const sessionId = "codex-fast-complete-release-pending";
    const session: DiscoveredProviderSession = {
      ...readyLive,
      id: sessionId,
      provider: "codex",
      owner: "Codex",
      routeState: "available",
      routeOwnership: "unverified",
      conversationState: "open",
      chatPath: "/tmp/codex-fast-complete-release-pending.jsonl",
      messageTransport: "codex_app_server",
      controlTarget: { kind: "url", url: `codex://threads/${sessionId}` },
    };
    let routeProbe: SessionRouteProbeResult = {
      routeState: "unavailable",
      unavailableReason: "provider_unavailable",
      routeOwnership: "unverified",
      releasePending: true,
      turnState: "ready",
      turnId: "turn-fast",
      confirmedTerminal: true,
    };
    const provider: ProviderAdapter = {
      id: "codex",
      discover: async () => [structuredClone(session)],
      resolve: async (id) => id === sessionId ? structuredClone(session) : undefined,
    };
    const repository = new SessionRepository([provider]);
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      codexRouteStatus: () => routeProbe,
    });
    await repository.refresh();

    await expect(repository.chatAction({
      type: "send_chat", id: "fast-release-request", sessionId, generation: 1,
      deliveryId: "fast-release-delivery", text: "finish", images: [],
    })).resolves.toBeUndefined();
    expect(repository.chatRecord(sessionId)).toMatchObject({
      section: "ready", turnState: "ready", routeState: "unavailable",
      routeOwnership: "unverified", releasePending: true, turnId: "turn-fast",
      confirmedTerminal: true,
    });
    expect(repository.current().sessions.find(({ id }) => id === sessionId)).toMatchObject({
      sessionState: { turn: "ready", route: "unavailable", unavailableReason: "provider_unavailable" },
    });

    await expect(repository.chatOpened(sessionId, "release-retry-lease")).resolves.toBeUndefined();
    await expect(repository.chatRetry(sessionId)).resolves.toBe(
      "The Codex route is still closing. Retry after it settles.",
    );
    expect(repository.chatRecord(sessionId)).toMatchObject({
      routeState: "unavailable", releasePending: true, confirmedTerminal: true,
      turnId: "turn-fast",
    });

    // The provider child has now exited. The exact read can restore a
    // tentative route, but it must remain unverified until the next Send.
    routeProbe = {
      routeState: "available", routeOwnership: "unverified",
      turnState: "ready", turnId: "turn-fast", confirmedTerminal: true,
    };
    await repository.refresh();
    expect(repository.chatRecord(sessionId)).toMatchObject({
      section: "ready", turnState: "ready", routeState: "available",
      routeOwnership: "unverified",
    });
    expect(repository.chatRecord(sessionId)).not.toHaveProperty("releasePending");
    expect(repository.current().sessions.find(({ id }) => id === sessionId)).toMatchObject({
      sessionState: { turn: "ready", route: "available", routeOwnership: "unverified" },
    });
    repository.chatClosed(sessionId, "release-retry-lease");
  });

  it("recovers an uncertain Codex route only from exact ready evidence", async () => {
    const sessionId = "codex-explicit-route-recovery";
    const base: DiscoveredProviderSession = {
      ...readyLive,
      id: sessionId,
      provider: "codex",
      owner: "Codex",
      routeState: "available",
      routeOwnership: "unverified",
      conversationState: "open",
      chatPath: "/tmp/codex-explicit-route-recovery.jsonl",
      messageTransport: "codex_app_server",
      controlTarget: { kind: "url", url: `codex://threads/${sessionId}` },
    };

    const runCase = async (
      lifecycle: Pick<DiscoveredProviderSession, "turnState"> & { turnId?: string },
      expectedError?: string,
      expectedRecoveryCalls = 0,
    ): Promise<void> => {
      const routeProbe: SessionRouteProbeResult = {
        routeState: "unavailable", unavailableReason: "provider_unavailable",
        turnState: "working", turnId: "turn-lost",
      };
      let recoveryCalls = 0;
      let resolveCount = 0;
      const provider: ProviderAdapter = {
        id: "codex",
        discover: async () => [structuredClone(base)],
        resolve: async (id) => {
          if (id !== sessionId) return undefined;
          resolveCount += 1;
          // The opened page and initial Send both observe the pre-loss ready
          // state. Retry gets the fresh lifecycle result under test.
          const initialLifecycle = { turnState: "ready" as const, turnId: "turn-lost" };
          return {
            ...structuredClone(base),
            ...(resolveCount <= 2 ? initialLifecycle : lifecycle),
            routeState: "available",
            routeOwnership: "unverified",
          };
        },
      };
      const repository = new SessionRepository([provider]);
      repository.setControls({
        focus: async () => undefined,
        send: async () => undefined,
        codexRouteStatus: () => routeProbe,
        recoverCodexRoute: () => {
          recoveryCalls += 1;
          return {
            recovered: true,
            probe: {
              routeState: "available",
              routeOwnership: "unverified",
              turnState: "ready",
              turnId: "turn-lost",
              confirmedTerminal: true,
            },
          };
        },
      });
      await repository.refresh();
      await expect(repository.chatOpened(sessionId, `lease-${lifecycle.turnState}-${lifecycle.turnId ?? "missing"}`))
        .resolves.toBeUndefined();
      expect(repository.chatRecord(sessionId)).toMatchObject({
        routeState: "available", turnState: "ready", turnId: "turn-lost",
      });
      const sendResult = await repository.chatAction({
        type: "send_chat", id: `recovery-send-${lifecycle.turnState}-${lifecycle.turnId ?? "missing"}`,
        sessionId, generation: 1, deliveryId: `recovery-delivery-${lifecycle.turnState}-${lifecycle.turnId ?? "missing"}`,
        text: "may have started", images: [],
      });
      expect(sendResult).toBeUndefined();
      const retry = await repository.chatRetry(sessionId);
      if (expectedError) expect(retry).toContain(expectedError);
      else expect(retry).toBeUndefined();
      expect(recoveryCalls).toBe(expectedRecoveryCalls);
      if (expectedError) {
        expect(repository.chatRecord(sessionId)).toMatchObject({
          routeState: "unavailable", routeUnavailableReason: "provider_unavailable",
          turnState: "working", turnId: "turn-lost",
        });
      } else {
        expect(repository.chatRecord(sessionId)).toMatchObject({
          routeState: "available", routeOwnership: "unverified",
          turnState: "ready", turnId: "turn-lost",
        });
      }
      repository.chatClosed(sessionId, `lease-${lifecycle.turnState}-${lifecycle.turnId ?? "missing"}`);
    };

    await runCase({ turnState: "ready", turnId: "turn-lost" }, undefined, 1);
    await runCase({ turnState: "working", turnId: "turn-lost" }, "has not confirmed", 0);
    await runCase({ turnState: "ready", turnId: "turn-other" }, "different turn identity", 0);
    await runCase({ turnState: "ready" }, "exact identity", 0);
  });

  it("keeps a lost Codex send unavailable instead of allowing an automatic retry", async () => {
    const sessionId = "codex-uncertain-send";
    const session: DiscoveredProviderSession = {
      ...readyLive,
      id: sessionId,
      provider: "codex",
      owner: "Codex",
      routeState: "available",
      routeOwnership: "unverified",
      conversationState: "open",
      chatPath: "/tmp/codex-uncertain-send.jsonl",
      messageTransport: "codex_app_server",
      controlTarget: { kind: "url", url: `codex://threads/${sessionId}` },
    };
    const provider: ProviderAdapter = {
      id: "codex",
      discover: async () => [structuredClone(session)],
    };
    let routeProbe: SessionRouteProbeResult = {
      routeState: "unavailable", unavailableReason: "provider_unavailable",
      turnState: "working", turnId: "turn-uncertain",
    };
    let sends = 0;
    const repository = new SessionRepository([provider]);
    repository.setControls({
      focus: async () => undefined,
      send: async () => { sends += 1; },
      codexRouteStatus: () => routeProbe,
    });
    await repository.refresh();

    await expect(repository.chatAction({
      type: "send_chat", id: "uncertain-request", sessionId, generation: 1,
      deliveryId: "uncertain-delivery", text: "may have started", images: [],
    })).resolves.toBeUndefined();
    expect(repository.chatRecord(sessionId)).toMatchObject({
      section: "working", turnState: "working", routeState: "unavailable",
      routeUnavailableReason: "provider_unavailable", turnId: "turn-uncertain",
    });
    expect(repository.current().sessions.find(({ id }) => id === sessionId)).toMatchObject({
      sessionState: { route: "unavailable", unavailableReason: "provider_unavailable" },
    });

    routeProbe = { routeState: "available", turnState: "ready" };
    await expect(repository.chatAction({
      type: "send_chat", id: "uncertain-retry", sessionId, generation: 1,
      deliveryId: "uncertain-retry-delivery", text: "must wait", images: [],
    })).resolves.toContain("unavailable");
    expect(sends).toBe(1);
  });

  it("retains a native user identity after many tool items arrive", async () => {
    const sessionId = "codex-user-identity-retention";
    const session: DiscoveredProviderSession = {
      ...readyLive,
      id: sessionId,
      provider: "codex",
      owner: "Codex",
      routeState: "available",
      routeOwnership: "unverified",
      conversationState: "open",
      chatPath: "/tmp/codex-user-identity-retention.jsonl",
      messageTransport: "codex_app_server",
      controlTarget: { kind: "url", url: `codex://threads/${sessionId}` },
    };
    const provider: ProviderAdapter = {
      id: "codex",
      discover: async () => [structuredClone(session)],
    };
    let emit!: (event: CodexRouteEvent) => void;
    const repository = new SessionRepository([provider], {
      chatPageReader: async () => ({
        type: "chat_page", sessionId, items: [{
          id: "native-user", kind: "user", text: "Continue", images: [],
        }], hasMoreBefore: false,
        transcriptEvidence: { authoritative: true, complete: true },
        capabilities: { canSendText: true, canSendImages: true, canCancel: false, canApprove: false, canAnswer: false },
        pendingAction: null,
      }),
    });
    repository.setControls({
      focus: async () => undefined,
      send: async () => undefined,
      subscribeCodexRouteEvents: (listener) => {
        emit = listener;
        return () => undefined;
      },
    });
    await repository.refresh();
    emit({
      type: "item_started", threadId: sessionId, turnId: "turn-identity",
      itemId: "native-user", itemType: "userMessage", deliveryId: "delivery-identity",
    });
    for (let index = 0; index < 128; index += 1) {
      emit({
        type: "item_started", threadId: sessionId, turnId: "turn-identity",
        itemId: `tool-${index}`, itemType: "commandExecution", deliveryId: `delivery-tool-${index}`,
      });
    }

    await expect(repository.chatPage(sessionId)).resolves.toMatchObject({
      items: [{
        id: "native-user", deliveryId: "delivery-identity", providerMessageId: "native-user",
      }],
    });
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

function testChatPage(
  id: string,
  evidence: Partial<NonNullable<ChatPage["transcriptEvidence"]>> = {},
): ChatPage {
  return {
    type: "chat_page",
    sessionId: "pi-1",
    items: [{
      id,
      kind: "user",
      text: id,
      images: [],
    }],
    hasMoreBefore: false,
    transcriptEvidence: {
      authoritative: false,
      complete: false,
      ...evidence,
    },
    capabilities: {
      canSendText: true,
      canSendImages: true,
      canCancel: true,
      canApprove: false,
      canAnswer: false,
    },
    pendingAction: null,
  };
}

function piUserLine(id: string, text: string): string {
  return JSON.stringify({
    type: "message",
    id,
    timestamp: "2026-08-23T00:00:00.000Z",
    message: { role: "user", content: [{ type: "text", text }] },
  });
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
