import { describe, expect, it } from "vitest";
import { CHAT_MAX_WIRE_BYTES, serverMessageSchema, type ServerMessage } from "@agent-visor/protocol";
import { daemonWireLimit, sendDaemonMessage, serializeDaemonMessage } from "./outbound.js";

const page: ServerMessage = {
  type: "chat_page",
  sessionId: "session-1",
  items: [{ id: "answer-1", kind: "assistant", text: "A response" }],
  hasMoreBefore: false,
  capabilities: {
    canSendText: true,
    canSendImages: false,
    canCancel: false,
    canApprove: false,
    canAnswer: false,
  },
  pendingAction: null,
};

const commands: ServerMessage = {
  type: "chat_commands",
  sessionId: "session-1",
  commands: [{
    name: "review",
    aliases: [],
    description: "Review the current branch",
    argNames: [],
    source: "builtin",
    isHidden: false,
    opensInTerminalDialog: false,
  }],
  truncated: false,
};

describe("daemon outbound protocol seam", () => {
  it("never permits a test limit above the production protocol ceiling", () => {
    expect(daemonWireLimit(Number.MAX_SAFE_INTEGER)).toBe(CHAT_MAX_WIRE_BYTES);
    expect(daemonWireLimit(Infinity)).toBe(CHAT_MAX_WIRE_BYTES);
    expect(daemonWireLimit(0)).toBe(CHAT_MAX_WIRE_BYTES);
    expect(daemonWireLimit(-1)).toBe(CHAT_MAX_WIRE_BYTES);
    expect(daemonWireLimit(1.5)).toBe(CHAT_MAX_WIRE_BYTES);
    expect(daemonWireLimit(CHAT_MAX_WIRE_BYTES - 1)).toBe(CHAT_MAX_WIRE_BYTES - 1);
  });

  it("accepts a message exactly at the configured UTF-8 byte boundary", () => {
    const data = JSON.stringify(page);
    const result = serializeDaemonMessage(page, {}, Buffer.byteLength(data, "utf8"));

    expect(result.usedFallback).toBe(false);
    expect(result.data).toBe(data);
    expect(serverMessageSchema.parse(JSON.parse(result.data))).toEqual(page);
  });

  it("returns a contextual protocol error for an oversized Chat page", () => {
    const result = serializeDaemonMessage(
      page,
      { requestType: "open_chat", requestId: "open-1", sessionId: "session-1" },
      Buffer.byteLength(JSON.stringify(page), "utf8") - 1,
    );

    expect(result.usedFallback).toBe(true);
    expect(result.message).toEqual({
      type: "daemon_error",
      code: "response_too_large",
      message: "Daemon response exceeded the protocol wire limit.",
      responseType: "chat_page",
      requestType: "open_chat",
      requestId: "open-1",
      sessionId: "session-1",
    });
  });

  it("returns a contextual protocol error for an oversized slash catalog", () => {
    const result = serializeDaemonMessage(
      commands,
      { requestType: "get_chat_commands", requestId: "commands-1", sessionId: "session-1" },
      Buffer.byteLength(JSON.stringify(commands), "utf8") - 1,
    );

    expect(result.usedFallback).toBe(true);
    expect(result.message).toMatchObject({
      type: "daemon_error",
      code: "response_too_large",
      responseType: "chat_commands",
      requestType: "get_chat_commands",
      requestId: "commands-1",
      sessionId: "session-1",
    });
  });

  it("reports invalid responses instead of silently dropping them", () => {
    const sent: string[] = [];
    const didSend = sendDaemonMessage({ send: (data) => sent.push(data) }, { type: "invented" }, { requestType: "health" });

    expect(didSend).toBe(true);
    expect(serverMessageSchema.parse(JSON.parse(sent[0]!))).toMatchObject({
      type: "daemon_error",
      code: "invalid_response",
      responseType: "invented",
      requestType: "health",
    });
  });

  it("retains request context when an invalid response has no type", () => {
    const pageResult = serializeDaemonMessage({}, {
      requestType: "open_chat",
      sessionId: "session-1",
    });
    const slashResult = serializeDaemonMessage({}, {
      requestType: "get_chat_commands",
      requestId: "commands-1",
      sessionId: "session-1",
    });

    expect(pageResult.message).toEqual({
      type: "daemon_error",
      code: "invalid_response",
      message: "Daemon produced an invalid protocol response.",
      requestType: "open_chat",
      sessionId: "session-1",
    });
    expect(slashResult.message).toEqual({
      type: "daemon_error",
      code: "invalid_response",
      message: "Daemon produced an invalid protocol response.",
      requestType: "get_chat_commands",
      requestId: "commands-1",
      sessionId: "session-1",
    });
  });

  it("returns false when the socket rejects the bounded payload", () => {
    const didSend = sendDaemonMessage({
      send: () => { throw new Error("closed"); },
    }, page);

    expect(didSend).toBe(false);
  });
});
