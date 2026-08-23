import { afterEach, describe, expect, it } from "vitest";
import WebSocket from "ws";
import { serverMessageSchema } from "@agent-visor/protocol";
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
    const source = {
      current: () => fixtureSnapshot,
      subscribe: () => () => undefined,
      chatPage: async (sessionId: string) => ({
        type: "chat_page" as const,
        sessionId,
        items: [{ id: "u1", kind: "user" as const, text: "Fix it", images: [] }],
        hasMoreBefore: false,
        capabilities: {
          canSendText: false, canSendImages: false, canApprove: false, canAnswer: false,
          readOnlyReason: "Read only.",
        },
        pendingAction: null,
      }),
      chatAction: async () => "Read only.",
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
    socket.send(JSON.stringify({
      type: "send_chat", id: "send-1", sessionId: "pi-ready", text: "Continue", images: [],
    }));

    await expect.poll(() => messages.length).toBe(3);
    expect(messages[1]).toMatchObject({ type: "chat_page", sessionId: "pi-ready" });
    expect(messages[2]).toEqual({
      type: "chat_action_result", id: "send-1", ok: false, error: "Read only.",
    });
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
});
