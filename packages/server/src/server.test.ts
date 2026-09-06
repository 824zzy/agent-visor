import { afterEach, describe, expect, it, vi } from "vitest";
import WebSocket from "ws";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  defaultChatVisibility,
  serverMessageSchema,
  type ChatSettingsUpdate,
} from "@agent-visor/protocol";
import { fixtureSnapshot } from "./fixture.js";
import { startServer, type RunningServer } from "./server.js";
import { SessionRepository, type ProviderAdapter } from "./sessions.js";

const token = "test-token-with-at-least-thirty-two-characters";
let running: RunningServer | undefined;

afterEach(async () => {
  await running?.close();
  running = undefined;
});

describe("Agent Visor daemon", () => {
  it("delivers health and one validated session snapshot", async () => {
    running = await startServer({ port: 0, snapshot: fixtureSnapshot, token });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];

    socket.on("message", (data) => {
      messages.push(serverMessageSchema.parse(JSON.parse(data.toString())));
    });

    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });

    socket.send(JSON.stringify({ type: "health" }));
    socket.send(JSON.stringify({ type: "subscribe_sessions" }));

    await expect.poll(() => messages.length).toBe(3);
    expect(messages).toEqual([
      { type: "hello", protocolVersion: 1 },
      { type: "health", status: "ok" },
      fixtureSnapshot,
    ]);

    socket.close();
  });

  it("rejects clients without the ephemeral desktop token", async () => {
    running = await startServer({ port: 0, snapshot: fixtureSnapshot, token });
    const socket = new WebSocket(running.url.replace(/\?.*$/, ""));

    const statusCode = await new Promise<number>((resolve, reject) => {
      socket.once("unexpected-response", (_, response) => {
        const status = response.statusCode ?? 0;
        response.destroy();
        resolve(status);
      });
      socket.once("error", reject);
    });

    expect(statusCode).toBe(401);
  });

  it("keeps revisions across reconnects and pushes later snapshots", async () => {
    let title = "First";
    const provider: ProviderAdapter = {
      id: "pi",
      async discover() {
        return [{
          id: "pi-1",
          provider: "pi",
          title,
          cwd: "/Users/me/Codes/agent-visor",
          owner: "Ghostty",
          section: "working",
          updatedAt: "2026-08-22T08:00:00.000Z",
          canOpenOwner: true,
          canEnterChat: true,
        }];
      },
    };
    const source = new SessionRepository([provider]);
    await source.refresh();
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    const snapshots: unknown[] = [];
    socket.on("message", (data) => {
      const parsed = serverMessageSchema.parse(JSON.parse(data.toString()));
      if (parsed.type === "session_snapshot") snapshots.push(parsed);
    });
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });
    socket.send(JSON.stringify({ type: "subscribe_sessions" }));
    await expect.poll(() => snapshots.length).toBe(1);

    title = "Changed";
    await source.refresh();
    await expect.poll(() => snapshots.length).toBe(2);
    expect(snapshots).toMatchObject([
      { revision: 1, sessions: [{ title: "First" }] },
      { revision: 2, sessions: [{ title: "Changed" }] },
    ]);
    socket.close();
    await new Promise((resolve) => socket.once("close", resolve));

    const reconnect = new WebSocket(running.url);
    let reconnectRevision: number | undefined;
    reconnect.on("message", (data) => {
      const parsed = serverMessageSchema.parse(JSON.parse(data.toString()));
      if (parsed.type === "session_snapshot") reconnectRevision = parsed.revision;
    });
    await new Promise<void>((resolve, reject) => {
      reconnect.once("open", resolve);
      reconnect.once("error", reject);
    });
    reconnect.send(JSON.stringify({ type: "subscribe_sessions" }));
    await expect.poll(() => reconnectRevision).toBe(2);
    reconnect.close();
  });

  it("delivers Chat pages and capability action results", async () => {
    const acknowledged: string[] = [];
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      acknowledgeReady: (sessionId: string) => { acknowledged.push(sessionId); },
      chatPage: async (sessionId: string) => ({
        type: "chat_page" as const,
        sessionId,
        items: [{ id: "u1", kind: "user" as const, text: "Fix it", images: [] }],
        hasMoreBefore: false,
        capabilities: {
          canSendText: false, canSendImages: false, canCancel: false, canApprove: false, canAnswer: false,
          readOnlyReason: "Read only.",
        },
        pendingAction: null,
      }),
      chatAction: async () => "Read only.",
      focusSession: async () => undefined,
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];
    socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });

    socket.send(JSON.stringify({ type: "open_chat", sessionId: "pi-ready" }));
    socket.send(JSON.stringify({ type: "focus_session", id: "focus-1", sessionId: "pi-ready" }));
    socket.send(JSON.stringify({
      type: "send_chat", id: "send-1", sessionId: "pi-ready", generation: 1,
      deliveryId: "delivery-1", text: "Continue", images: [],
    }));
    await expect.poll(() => messages.length).toBe(4);
    expect(messages[1]).toMatchObject({ type: "chat_page", sessionId: "pi-ready" });
    expect(messages).toContainEqual({ type: "native_action_result", id: "focus-1", ok: true });
    expect(acknowledged).toEqual(["pi-ready"]);
    expect(messages).toContainEqual({
      type: "chat_action_result", id: "send-1", action: "send", sessionId: "pi-ready",
      generation: 1, deliveryId: "delivery-1", ok: false, error: "Read only.",
    });
    socket.close();
  });

  it("keeps one opaque chat reference for same-session pages and closes the exact token", async () => {
    const opened: Array<{ sessionId: string; referenceId: string }> = [];
    const closed: Array<{ sessionId: string; referenceId: string }> = [];
    const pageSessions: string[] = [];
    const retried: string[] = [];
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      chatOpened: async (sessionId: string, referenceId = "missing-reference") => {
        opened.push({ sessionId, referenceId });
        return undefined;
      },
      chatClosed: (sessionId: string, referenceId = "missing-reference") => {
        closed.push({ sessionId, referenceId });
      },
      chatRetry: async (sessionId: string) => {
        retried.push(sessionId);
        return undefined;
      },
      chatPage: async (sessionId: string) => {
        pageSessions.push(sessionId);
        return {
          type: "chat_page" as const,
          sessionId,
          items: [],
          hasMoreBefore: false,
          capabilities: {
            canSendText: true, canSendImages: false, canCancel: false,
            canApprove: false, canAnswer: false,
          },
          pendingAction: null,
        };
      },
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    socket.on("message", (data) => serverMessageSchema.parse(JSON.parse(data.toString())));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });

    socket.send(JSON.stringify({ type: "open_chat", id: "same-1", sessionId: "session-a" }));
    await expect.poll(() => pageSessions).toEqual(["session-a"]);
    socket.send(JSON.stringify({ type: "open_chat", id: "same-2", sessionId: "session-a" }));
    await expect.poll(() => pageSessions).toEqual(["session-a", "session-a"]);
    expect(opened).toHaveLength(1);
    expect(retried).toEqual([]);
    socket.send(JSON.stringify({
      type: "open_chat", id: "retry-1", sessionId: "session-a", retryAvailability: true,
    }));
    await expect.poll(() => pageSessions).toEqual(["session-a", "session-a", "session-a"]);
    expect(opened).toHaveLength(1);
    expect(retried).toEqual(["session-a"]);

    socket.send(JSON.stringify({ type: "open_chat", id: "switch-1", sessionId: "session-b" }));
    await expect.poll(() => pageSessions).toEqual(["session-a", "session-a", "session-a", "session-b"]);
    expect(opened).toHaveLength(2);
    expect(closed).toEqual([opened[0]]);

    const closedSocket = new Promise<void>((resolve) => socket.once("close", () => resolve()));
    socket.close();
    await closedSocket;
    await expect.poll(() => closed).toEqual(opened);
  });

  it("propagates retry errors and drops late results after a chat switch", async () => {
    const pageSessions: string[] = [];
    const retryCalls: string[] = [];
    let retryStarted!: () => void;
    const retryStartedPromise = new Promise<void>((resolve) => { retryStarted = resolve; });
    let resolveStaleRetry!: (value: string | undefined) => void;
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      chatOpened: async () => undefined,
      chatClosed: () => undefined,
      chatRetry: (sessionId: string) => {
        retryCalls.push(sessionId);
        if (sessionId === "session-a") {
          retryStarted();
          return new Promise<string | undefined>((resolve) => {
            resolveStaleRetry = resolve;
          });
        }
        return Promise.resolve("The Codex route is still closing. Retry after it settles.");
      },
      chatPage: async (sessionId: string) => {
        pageSessions.push(sessionId);
        return {
          type: "chat_page" as const,
          sessionId,
          items: [{ id: "draft-anchor", kind: "user" as const, text: "Draft stays", images: [] }],
          hasMoreBefore: false,
          capabilities: {
            canSendText: true, canSendImages: false, canCancel: false,
            canApprove: false, canAnswer: false,
          },
          pendingAction: null,
        };
      },
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];
    socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });

    socket.send(JSON.stringify({ type: "open_chat", id: "open-a", sessionId: "session-a" }));
    await expect.poll(() => pageSessions).toEqual(["session-a"]);
    socket.send(JSON.stringify({
      type: "open_chat", id: "retry-a", sessionId: "session-a", retryAvailability: true,
    }));
    await retryStartedPromise;

    socket.send(JSON.stringify({ type: "open_chat", id: "open-b", sessionId: "session-b" }));
    await expect.poll(() => pageSessions).toEqual(["session-a", "session-b"]);
    resolveStaleRetry("stale retry must not cross the chat reference");
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(messages).not.toContainEqual(expect.objectContaining({ requestId: "retry-a" }));

    socket.send(JSON.stringify({
      type: "open_chat", id: "retry-b", sessionId: "session-b", retryAvailability: true,
    }));
    await expect.poll(() => messages).toContainEqual({
      type: "daemon_error",
      code: "invalid_response",
      message: "The Codex route is still closing. Retry after it settles.",
      responseType: "chat_page",
      requestType: "open_chat",
      requestId: "retry-b",
      sessionId: "session-b",
    });
    expect(pageSessions).toEqual(["session-a", "session-b"]);
    expect(retryCalls).toEqual(["session-a", "session-b"]);
    socket.close();
  });

  it("drops deferred pages from stale chat references during rapid switch and reopen", async () => {
    const opened: Array<{ sessionId: string; referenceId: string }> = [];
    const closed: Array<{ sessionId: string; referenceId: string }> = [];
    const pageSessions: string[] = [];
    const pendingOpens: Array<{
      sessionId: string;
      referenceId: string;
      resolve(value: string | undefined): void;
    }> = [];
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      chatOpened: (sessionId: string, referenceId = "missing-reference") => {
        opened.push({ sessionId, referenceId });
        return new Promise<string | undefined>((resolve) => {
          pendingOpens.push({ sessionId, referenceId, resolve });
        });
      },
      chatClosed: (sessionId: string, referenceId = "missing-reference") => {
        closed.push({ sessionId, referenceId });
      },
      chatPage: async (sessionId: string) => {
        pageSessions.push(sessionId);
        return {
          type: "chat_page" as const,
          sessionId,
          items: [],
          hasMoreBefore: false,
          capabilities: {
            canSendText: true, canSendImages: false, canCancel: false,
            canApprove: false, canAnswer: false,
          },
          pendingAction: null,
        };
      },
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    socket.on("message", (data) => serverMessageSchema.parse(JSON.parse(data.toString())));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });

    socket.send(JSON.stringify({ type: "open_chat", id: "rapid-a1", sessionId: "session-a" }));
    await expect.poll(() => pendingOpens.length).toBe(1);
    socket.send(JSON.stringify({ type: "open_chat", id: "rapid-b", sessionId: "session-b" }));
    await expect.poll(() => pendingOpens.length).toBe(2);
    expect(closed).toEqual([opened[0]]);
    socket.send(JSON.stringify({ type: "open_chat", id: "rapid-a2", sessionId: "session-a" }));
    await expect.poll(() => pendingOpens.length).toBe(3);
    expect(closed).toEqual([opened[0], opened[1]]);
    expect(new Set(opened.map(({ referenceId }) => referenceId)).size).toBe(3);

    pendingOpens[0]!.resolve(undefined);
    pendingOpens[1]!.resolve(undefined);
    pendingOpens[2]!.resolve(undefined);
    await expect.poll(() => pageSessions).toEqual(["session-a"]);

    const closedSocket = new Promise<void>((resolve) => socket.once("close", () => resolve()));
    socket.close();
    await closedSocket;
    await expect.poll(() => closed).toEqual(opened);
  });

  it("routes lazy Codex settings updates only to the matching open chat", async () => {
    let publishSettings: ((update: ChatSettingsUpdate) => void) | undefined;
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      subscribeChatSettings: (listener: (update: ChatSettingsUpdate) => void) => {
        publishSettings = listener;
        return () => { publishSettings = undefined; };
      },
      chatPage: async (sessionId: string) => ({
        type: "chat_page" as const,
        sessionId,
        items: [],
        hasMoreBefore: false,
        capabilities: {
          canSendText: true, canSendImages: false, canCancel: false,
          canApprove: false, canAnswer: false,
        },
        pendingAction: null,
      }),
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];
    socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });
    socket.send(JSON.stringify({
      type: "open_chat", id: "open-codex", sessionId: "pi-ready", generation: 1,
    }));
    await expect.poll(() => messages.some((message) => (
      typeof message === "object" && message !== null
      && (message as { type?: unknown }).type === "chat_page"
    ))).toBe(true);

    publishSettings?.({
      type: "chat_settings_update",
      sessionId: "pi-ready",
      generation: 1,
      settings: {
        provider: "codex",
        current: { modelId: "gpt-6-astra", reasoningEffort: "high" },
        models: [{
          id: "gpt-6-astra", displayName: "GPT-6 Astra", description: "Fast model",
          reasoningEfforts: [{ value: "high", description: "Deep" }],
          defaultReasoningEffort: "high", supportsImages: true, isDefault: true,
        }],
        permissionProfiles: [],
        appliesTo: "next_turn",
        canChange: true,
      },
    });
    await expect.poll(() => messages.some((message) => (
      typeof message === "object" && message !== null
      && (message as { type?: unknown }).type === "chat_settings_update"
    ))).toBe(true);
    expect(messages).toContainEqual(expect.objectContaining({
      type: "chat_settings_update",
      sessionId: "pi-ready",
      generation: 1,
    }));
    socket.close();
  });

  it("settles permission-mode cycle with exact action metadata", async () => {
    const actions: unknown[] = [];
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      chatAction: async (message: Extract<import("@agent-visor/protocol").ClientMessage, {
        type: "cycle_permission_mode";
      }>) => {
        actions.push(message);
        return undefined;
      },
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];
    socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });
    socket.send(JSON.stringify({
      type: "cycle_permission_mode", id: "cycle-1", sessionId: "claude-1",
      generation: 4, expectedMode: "default",
    }));
    await new Promise((resolve) => setTimeout(resolve, 100));
    await expect.poll(() => messages.length).toBe(2);
    expect(actions).toEqual([expect.objectContaining({
      type: "cycle_permission_mode", sessionId: "claude-1", generation: 4,
    })]);
    expect(messages[1]).toEqual({
      type: "chat_action_result", id: "cycle-1", action: "cycle_permission_mode",
      sessionId: "claude-1", generation: 4, ok: true,
    });
    socket.close();
  });

  it("echoes send request identity in success and failure acknowledgements", async () => {
    const actions: unknown[] = [];
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      chatAction: async (message: Extract<import("@agent-visor/protocol").ClientMessage, { type: "send_chat" }>) => {
        actions.push(message);
        return message.text === "fail" ? "Provider rejected the message." : undefined;
      },
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];
    socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });

    socket.send(JSON.stringify({
      type: "send_chat", id: "request-1", sessionId: "pi-ready", generation: 9,
      deliveryId: "delivery-1", text: "Continue", images: [],
    }));
    socket.send(JSON.stringify({
      type: "send_chat", id: "request-2", sessionId: "pi-ready", generation: 9,
      deliveryId: "delivery-2", text: "fail", images: [],
    }));
    await expect.poll(() => messages.length).toBe(3);

    expect(actions).toMatchObject([
      { id: "request-1", sessionId: "pi-ready", generation: 9, deliveryId: "delivery-1" },
      { id: "request-2", sessionId: "pi-ready", generation: 9, deliveryId: "delivery-2" },
    ]);
    expect(messages).toContainEqual({
      type: "chat_action_result", id: "request-1", action: "send", sessionId: "pi-ready",
      generation: 9, deliveryId: "delivery-1", ok: true,
    });
    expect(messages).toContainEqual({
      type: "chat_action_result", id: "request-2", action: "send", sessionId: "pi-ready",
      generation: 9, deliveryId: "delivery-2", ok: false, error: "Provider rejected the message.",
    });
    socket.close();
  });

  it("acknowledges a cancellation with request, session, and generation identity", async () => {
    const actions: unknown[] = [];
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      chatPage: async (sessionId: string) => ({
        type: "chat_page" as const,
        sessionId,
        items: [{ id: "working", kind: "assistant" as const, text: "Working" }],
        hasMoreBefore: false,
        capabilities: {
          canSendText: true,
          canSendImages: false,
          canCancel: true,
          canApprove: false,
          canAnswer: false,
        },
        pendingAction: null,
      }),
      chatAction: async (message: unknown) => {
        actions.push(message);
        return undefined;
      },
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];
    socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });

    socket.send(JSON.stringify({
      type: "cancel_chat",
      id: "cancel-1",
      sessionId: "pi-ready",
      generation: 4,
      deliveryId: "send-1",
    }));
    await expect.poll(() => messages.length).toBe(2);

    expect(actions).toEqual([expect.objectContaining({
      type: "cancel_chat", id: "cancel-1", sessionId: "pi-ready", generation: 4,
    })]);
    expect(messages[1]).toEqual({
      type: "chat_action_result",
      id: "cancel-1",
      action: "cancel",
      sessionId: "pi-ready",
      generation: 4,
      deliveryId: "send-1",
      ok: true,
    });
    socket.close();
  });

  it("settles thrown send, cancel, and respond actions with contextual errors", async () => {
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      chatAction: async () => { throw new Error("provider action exploded"); },
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];
    socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });

    socket.send(JSON.stringify({
      type: "send_chat", id: "throw-send", sessionId: "pi-ready", generation: 3,
      deliveryId: "delivery-throw", text: "send", images: [],
    }));
    socket.send(JSON.stringify({
      type: "cancel_chat", id: "throw-cancel", sessionId: "pi-ready", generation: 3,
      deliveryId: "delivery-throw",
    }));
    socket.send(JSON.stringify({
      type: "respond_chat", id: "throw-respond", sessionId: "pi-ready",
      toolUseId: "tool-throw", decision: "allow",
    }));
    await expect.poll(() => messages.length).toBe(4);

    expect(messages).toContainEqual({
      type: "chat_action_result", id: "throw-send", action: "send", sessionId: "pi-ready",
      generation: 3, deliveryId: "delivery-throw", ok: false, error: "provider action exploded",
    });
    expect(messages).toContainEqual({
      type: "chat_action_result", id: "throw-cancel", action: "cancel", sessionId: "pi-ready",
      generation: 3, deliveryId: "delivery-throw", ok: false, error: "provider action exploded",
    });
    expect(messages).toContainEqual({
      type: "chat_action_result", id: "throw-respond", action: "respond", sessionId: "pi-ready",
      ok: false, error: "provider action exploded",
    });
    socket.close();
  });

  it("returns contextual daemon errors for malformed page and slash responses", async () => {
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      chatPage: async () => ({}) as never,
      chatCommands: async () => ({}) as never,
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];
    socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });

    socket.send(JSON.stringify({ type: "open_chat", sessionId: "pi-ready" }));
    socket.send(JSON.stringify({ type: "get_chat_commands", id: "commands-1", sessionId: "pi-ready" }));
    await expect.poll(() => messages.length).toBe(3);

    expect(messages).toContainEqual({
      type: "daemon_error",
      code: "invalid_response",
      message: "Daemon produced an invalid protocol response.",
      requestType: "open_chat",
      sessionId: "pi-ready",
    });
    expect(messages).toContainEqual({
      type: "daemon_error",
      code: "invalid_response",
      message: "Daemon produced an invalid protocol response.",
      requestType: "get_chat_commands",
      requestId: "commands-1",
      sessionId: "pi-ready",
    });
    socket.close();
  });

  it("stays available when a client request fails", async () => {
    const failed = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      chatPage: async () => { throw new Error("conversation file changed"); },
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];
    socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });

    socket.send(JSON.stringify({ type: "open_chat", id: "open-failed", sessionId: "pi-ready" }));
    await expect.poll(() => failed.mock.calls.length).toBe(1);
    await expect.poll(() => messages.some((message) => (
      typeof message === "object" && message !== null && "type" in message
      && message.type === "daemon_error"
    ))).toBe(true);
    expect(messages).toContainEqual({
      type: "daemon_error",
      code: "invalid_response",
      message: "conversation file changed",
      responseType: "chat_page",
      requestType: "open_chat",
      requestId: "open-failed",
      sessionId: "pi-ready",
    });
    socket.send(JSON.stringify({ type: "health" }));
    await expect.poll(() => messages.some((message) => (
      typeof message === "object" && message !== null && "type" in message
      && message.type === "health"
    ))).toBe(true);

    expect(failed).toHaveBeenCalledWith("Agent Visor request failed: Error: conversation file changed");
    failed.mockRestore();
    socket.close();
  });

  it("serves slash commands through the lazy daemon seam", async () => {
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      chatCommands: async (sessionId: string) => ({
        type: "chat_commands" as const,
        sessionId,
        truncated: false,
        commands: [{
          name: "review",
          aliases: [],
          description: "Review the current branch",
          argNames: [],
          source: "builtin" as const,
          isHidden: false,
          opensInTerminalDialog: false,
        }],
      }),
    };
    running = await startServer({ port: 0, source, token });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];
    socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });
    socket.send(JSON.stringify({ type: "get_chat_commands", id: "commands-1", sessionId: "pi-ready" }));
    await expect.poll(() => messages.length).toBe(2);
    expect(messages[1]).toEqual(expect.objectContaining({
      type: "chat_commands",
      sessionId: "pi-ready",
      commands: [expect.objectContaining({ name: "review" })],
    }));
    socket.close();
  });

  it("serves slash commands for a hook-backed session without a discovered record", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-server-hook-chat-"));
    try {
      const cwd = path.join(root, "project");
      await mkdir(path.join(cwd, ".claude", "commands"), { recursive: true });
      await writeFile(path.join(cwd, ".claude", "commands", "hook-review.md"),
        "---\nname: hook-review\n---\nReview from the hook cwd\n");
      const source = new SessionRepository([]);
      source.applyHook({
        sessionId: "hook-only",
        cwd,
        provider: "claude_code",
        event: "SessionStart",
        status: "working",
        receivedAt: "2026-08-22T08:00:00.000Z",
        tty: "ttys001",
        sessionFile: path.join(cwd, "conversation.jsonl"),
      });
      expect(source.chatRecord("hook-only")).toMatchObject({
        id: "hook-only",
        provider: "claude_code",
        chatPath: path.join(cwd, "conversation.jsonl"),
      });
      running = await startServer({ port: 0, source, token });
      const socket = new WebSocket(running.url);
      const messages: unknown[] = [];
      socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
      await new Promise<void>((resolve, reject) => {
        socket.once("open", resolve);
        socket.once("error", reject);
      });
      socket.send(JSON.stringify({ type: "get_chat_commands", id: "hook-commands", sessionId: "hook-only" }));
      await expect.poll(() => messages.length).toBe(2);
      expect(messages[1]).toEqual(expect.objectContaining({
        type: "chat_commands",
        sessionId: "hook-only",
      }));
      expect((messages[1] as { commands: unknown[] }).commands).toEqual(expect.arrayContaining([
        expect.objectContaining({ name: "hook-review", source: "project" }),
      ]));
      socket.close();
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("delivers native settings and action results", async () => {
    const state = {
      type: "native_services_state" as const,
      revision: 1,
      settings: {
        appearance: "dark" as const, contentScale: 1, pillsEnabled: true,
        pillScreen: { mode: "automatic" as const }, fullScreenPolicy: "onDemand" as const,
        codexUsageGlanceEnabled: true, claudeUsageGlanceEnabled: false,
        notificationSound: "Pop" as const, hotkeyTrigger: "shift" as const,
        customHotkeyCombo: null, sessionShortcutModifierFamily: "optionCommand" as const,
        editorPreference: "auto" as const, observedWindowHours: 42, launchAtLogin: false,
        chatVisibility: defaultChatVisibility,
      },
      permissions: { accessibility: "granted" as const, notifications: "authorized" as const },
      agents: [{
        id: "claude" as const, name: "Claude Code", available: true,
        installed: false, control: "toggle" as const,
      }],
      pillScreens: [{
        displayId: 1, name: "Built-in Retina Display", isBuiltIn: true, isMain: true,
      }],
      update: { status: "idle" as const, currentVersion: "2.7.0" },
    };
    const actions: unknown[] = [];
    const nativeServices = {
      current: () => state,
      subscribe: () => () => undefined,
      action: async (message: unknown) => { actions.push(message); return undefined; },
    };
    running = await startServer({ port: 0, snapshot: fixtureSnapshot, token, nativeServices });
    const socket = new WebSocket(running.url);
    const messages: unknown[] = [];
    socket.on("message", (data) => messages.push(serverMessageSchema.parse(JSON.parse(data.toString()))));
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });
    socket.send(JSON.stringify({ type: "get_native_services" }));
    socket.send(JSON.stringify({
      type: "update_settings", id: "settings-1", patch: { appearance: "light" },
    }));
    socket.send(JSON.stringify({
      type: "set_agent_connection", id: "agent-1", agent: "claude", enabled: true,
    }));

    await expect.poll(() => messages.length).toBe(4);
    expect(messages[1]).toEqual(state);
    expect(messages[2]).toEqual({ type: "native_action_result", id: "settings-1", ok: true });
    expect(messages[3]).toEqual({ type: "native_action_result", id: "agent-1", ok: true });
    expect(actions).toHaveLength(2);
    socket.close();
  });

  it("ignores malformed client messages", async () => {
    running = await startServer({ port: 0, snapshot: fixtureSnapshot, token });
    const socket = new WebSocket(running.url);
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });

    socket.send("not-json");
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(socket.readyState).toBe(WebSocket.OPEN);
    socket.close();
  });

  it("closes an oversized frame without taking down the daemon", async () => {
    running = await startServer({
      port: 0,
      snapshot: fixtureSnapshot,
      token,
      maxPayload: 256,
    });
    const oversized = new WebSocket(running.url);
    oversized.on("error", () => undefined);
    await new Promise<void>((resolve, reject) => {
      oversized.once("open", resolve);
      oversized.once("error", reject);
    });
    const closed = new Promise<number>((resolve) => {
      oversized.once("close", (code) => resolve(code));
    });
    oversized.send(Buffer.alloc(2_048, 0x78));

    await expect(closed).resolves.toBe(1009);

    const healthy = new WebSocket(running.url);
    const messages: unknown[] = [];
    healthy.on("message", (data) => messages.push(JSON.parse(data.toString())));
    await new Promise<void>((resolve, reject) => {
      healthy.once("open", resolve);
      healthy.once("error", reject);
    });
    healthy.send(JSON.stringify({ type: "health" }));
    await expect.poll(() => messages).toContainEqual({ type: "health", status: "ok" });
    healthy.close();
  });
});
