import { describe, expect, it, vi } from "vitest";
import { activateSessionNotification } from "./menu.js";
import { SessionRepository, type DiscoveredProviderSession } from "./sessions.js";
import { FakeNativeHelper } from "./native-helper.js";
import { NativeSessionControls } from "./session-controls.js";
import { DesktopSessionNavigation } from "./desktop-navigation.js";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import WebSocket from "ws";
import { startServer, type RunningServer } from "./server.js";

const updatedAt = "2026-10-16T20:00:00.000Z";
const completed: DiscoveredProviderSession = {
  id: "finished", provider: "codex", title: "Finished task", cwd: "/fixture", owner: "Codex",
  section: "ready", turnState: "ready", turnId: "turn-1", updatedAt,
  codexLifecycle: { phase: "ready", observedAt: updatedAt, turnId: "turn-1" },
  conversationState: "open", canOpenOwner: true, canEnterChat: true,
  controlTarget: { kind: "application", target: { pid: 42 } },
};
const notification = { version: 1, type: "event", event: "notification_action",
  action: "activate", sessionId: completed.id } as const;

async function fixture(row = completed) {
  const helper = new FakeNativeHelper();
  const rows = [row];
  const provider = { id: "codex" as const, discover: async () => rows };
  const repository = new SessionRepository([provider]);
  repository.setControls(new NativeSessionControls(helper));
  await repository.refresh();
  return { helper, repository, rows };
}

describe("notification navigation", () => {
  it("opens the exact source session and clears attention only after the focus succeeds", async () => {
    const { helper, repository } = await fixture();
    const focused = Promise.withResolvers<void>();
    const focusStarted = Promise.withResolvers<void>();
    const originalFocus = helper.focus.bind(helper);
    helper.focus = async target => {
      await originalFocus(target);
      focusStarted.resolve();
      await focused.promise;
    };
    const effects: unknown[] = [];
    const opening = activateSessionNotification(notification, repository, effect => effects.push(effect));
    await focusStarted.promise;
    expect(repository.current().sessions[0]?.attentionTier).toBe("ready");
    expect(effects).toEqual([]);
    focused.resolve();
    await opening;
    expect(helper.focusRequests).toEqual([{ pid: 42 }]);
    expect(repository.current().sessions[0]?.attentionTier).toBe("acknowledged_ready");
    expect(effects).toEqual([]);
    expect(helper.terminalSendRequests).toEqual([]);
    expect(helper.claudeAttachRequests).toEqual([]);
  });

  it.each([true, false])("keeps a failed source open unread and offers Chat only when supported (Chat: %s)", async canEnterChat => {
    const { helper, repository } = await fixture({ ...completed, canEnterChat });
    helper.focus = async () => { throw new Error("The original session is unavailable."); };
    const effects: unknown[] = [];
    await activateSessionNotification(notification, repository, effect => effects.push(effect));
    expect(repository.current().sessions[0]?.attentionTier).toBe("ready");
    expect(effects).toEqual([{
      type: "native_effect", action: "session_focus_failed", message: "The original session is unavailable.",
      ...(canEnterChat ? { chatSessionId: completed.id } : {}),
    }]);
    expect(helper.terminalSendRequests).toEqual([]);
    expect(helper.claudeAttachRequests).toEqual([]);
  });

  it("opens an owner-only session even when Agent Visor Chat is unavailable", async () => {
    const { helper, repository } = await fixture({ ...completed, canEnterChat: false });
    const effects: unknown[] = [];
    await activateSessionNotification(notification, repository, effect => effects.push(effect));
    expect(helper.focusRequests).toEqual([{ pid: 42 }]);
    expect(repository.current().sessions[0]?.attentionTier).toBe("acknowledged_ready");
    expect(effects).toEqual([]);
  });

  it.each(["approve", "deny"] as const)("leaves explicit %s actions to the permission handler", async action => {
    const { helper, repository } = await fixture();
    const effects: unknown[] = [];
    await activateSessionNotification({ ...notification, action, toolUseId: "fixture-permission" }, repository,
      effect => effects.push(effect));
    expect(repository.current().sessions[0]?.attentionTier).toBe("ready");
    expect(effects).toEqual([]);
    expect(helper.focusRequests).toEqual([]);
    expect(helper.terminalSendRequests).toEqual([]);
  });

  it("opens an Agent Visor-owned conversation in Chat without releasing its running route", async () => {
    const { helper, repository } = await fixture({ ...completed,
      messageTransport: "codex_app_server", routeState: "available", routeOwnership: "owned",
    });
    expect(repository.current().sessions[0]?.sessionState?.routeOwnership).toBe("owned");
    const effects: unknown[] = [];
    await activateSessionNotification(notification, repository, effect => effects.push(effect));
    expect(effects).toEqual([{ type: "native_action", action: "open_chat", sessionId: completed.id }]);
    expect(helper.focusRequests).toEqual([]);
    // Dispatch is not proof of opening: the existing Chat page-read path acknowledges it.
    expect(repository.current().sessions[0]?.attentionTier).toBe("ready");
  });

  it("clears a Chat-only notification only after its transcript page is served", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "av-notification-chat-"));
    let running: RunningServer | undefined;
    let socket: WebSocket | undefined;
    try {
      const file = path.join(root, "transcript.jsonl");
      await writeFile(file, JSON.stringify({ type: "response_item", timestamp: updatedAt,
        payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "Task completed." }] },
      }) + "\n");
      const { helper, repository } = await fixture({ ...completed, canOpenOwner: false,
        controlTarget: undefined, chatPath: file,
      });
      const effects: unknown[] = [];
      await activateSessionNotification(notification, repository, effect => effects.push(effect));
      expect(effects).toEqual([{ type: "native_action", action: "open_chat", sessionId: completed.id }]);
      expect(repository.current().sessions[0]?.attentionTier).toBe("ready");
      running = await startServer({ port: 0, token: "fixture-notification-token-with-32-characters", source: repository });
      socket = new WebSocket(running.url);
      const page = new Promise<Record<string, unknown>>((resolve, reject) => {
        socket!.on("message", data => {
          const message = JSON.parse(data.toString());
          if (message.type === "chat_page") resolve(message);
          if (message.type === "daemon_error") reject(new Error(message.message));
        });
        socket!.once("error", reject);
      });
      await new Promise<void>((resolve, reject) => { socket!.once("open", resolve); socket!.once("error", reject); });
      socket.send(JSON.stringify({ type: "open_chat", sessionId: completed.id }));
      expect((await page).items).toContainEqual(expect.objectContaining({ text: "Task completed." }));
      expect(repository.current().sessions[0]?.attentionTier).toBe("acknowledged_ready");
      expect(helper.focusRequests).toEqual([]);
      expect(helper.terminalSendRequests).toEqual([]);
    } finally {
      socket?.terminate();
      await running?.close();
      await rm(root, { recursive: true, force: true });
    }
  });

  it("does not mark a notification seen when a newer click supersedes its queued focus", async () => {
    const { helper, repository, rows } = await fixture();
    rows.push({ ...completed, id: "newest", controlTarget: { kind: "application", target: { pid: 43 } } });
    await repository.refresh();
    const effects: unknown[] = [];
    await Promise.all([
      activateSessionNotification(notification, repository, effect => effects.push(effect)),
      activateSessionNotification({ ...notification, sessionId: "newest" }, repository, effect => effects.push(effect)),
    ]);
    expect(helper.focusRequests).toEqual([{ pid: 43 }]);
    expect(repository.current().sessions.find(row => row.id === completed.id)?.attentionTier).toBe("ready");
    expect(repository.current().sessions.find(row => row.id === "newest")?.attentionTier).toBe("acknowledged_ready");
    expect(effects).toEqual([]);
  });

  it.each([true, false])("waits for the exact session-link launch result before clearing attention (accepted: %s)", async accepted => {
    const url = "paseo://h/srv_local/agent/fixture-agent";
    const requests: Array<{ requestId: string }> = [];
    const sent = Promise.withResolvers<void>();
    const desktop = new DesktopSessionNavigation(message => { requests.push(message); sent.resolve(); });
    const { helper, repository } = await fixture({ ...completed, controlTarget: { kind: "url", url } });
    repository.setControls(new NativeSessionControls(helper, undefined, undefined, link => desktop.open(link)));
    const effects: unknown[] = [];
    const opening = activateSessionNotification(notification, repository, effect => effects.push(effect));
    await sent.promise;
    expect(repository.current().sessions[0]?.attentionTier).toBe("ready");
    desktop.receive({ type: "session_url_result", requestId: "unrelated", ok: true });
    await new Promise<void>(resolve => setImmediate(resolve));
    expect(repository.current().sessions[0]?.attentionTier).toBe("ready");
    desktop.receive({ type: "session_url_result", requestId: requests[0]!.requestId, ok: accepted });
    await opening;
    expect(repository.current().sessions[0]?.attentionTier).toBe(accepted ? "acknowledged_ready" : "ready");
    expect(effects).toMatchObject(accepted ? [] : [{ action: "session_focus_failed", chatSessionId: completed.id }]);
    expect(helper.focusRequests).toEqual([]);
    desktop.close();
  });

  it.each(["timeout", "disconnect"] as const)("keeps session-link attention when the desktop cannot confirm navigation (%s)", async failure => {
    vi.useFakeTimers();
    const sent = Promise.withResolvers<void>();
    const desktop = new DesktopSessionNavigation(() => sent.resolve());
    try {
      const { helper, repository } = await fixture({ ...completed,
        controlTarget: { kind: "url", url: "paseo://h/srv_local/agent/fixture-agent" },
      });
      repository.setControls(new NativeSessionControls(helper, undefined, undefined, url => desktop.open(url)));
      const effects: unknown[] = [];
      const opening = activateSessionNotification(notification, repository, effect => effects.push(effect));
      await sent.promise;
      if (failure === "disconnect") desktop.close();
      else await vi.advanceTimersByTimeAsync(5_000);
      await opening;
      expect(repository.current().sessions[0]?.attentionTier).toBe("ready");
      expect(effects).toMatchObject([{ action: "session_focus_failed" }]);
    } finally { desktop.close(); vi.useRealTimers(); }
  });
});
