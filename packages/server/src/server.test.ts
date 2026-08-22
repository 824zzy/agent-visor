import { afterEach, describe, expect, it } from "vitest";
import WebSocket from "ws";
import { serverMessageSchema } from "@agent-visor/protocol";
import { fixtureSnapshot } from "./fixture.js";
import { startServer, type RunningServer } from "./server.js";

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
