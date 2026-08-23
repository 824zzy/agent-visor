import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { parseChatLines, readChatPage } from "./chat.js";

describe("provider Chat parsing", () => {
  it("parses Claude prose, thinking, tools, results, and images", () => {
    const items = parseChatLines("claude_code", [
      JSON.stringify({ type: "user", uuid: "u1", timestamp: "2026-08-22T10:00:00.000Z", message: { role: "user", content: "Fix it" } }),
      JSON.stringify({ type: "assistant", uuid: "a1", timestamp: "2026-08-22T10:00:01.000Z", message: { role: "assistant", content: [
        { type: "thinking", thinking: "Inspecting" },
        { type: "text", text: "I found it." },
        { type: "tool_use", id: "tool-1", name: "Bash", input: { command: "npm test" } },
      ] } }),
      JSON.stringify({ type: "user", uuid: "r1", timestamp: "2026-08-22T10:00:02.000Z", message: { role: "user", content: [
        { type: "tool_result", tool_use_id: "tool-1", content: "45 passed", is_error: false },
        { type: "image", source: { type: "base64", media_type: "image/png", data: "abc" } },
      ] } }),
    ]);

    expect(items.map(({ kind }) => kind)).toEqual(["user", "thinking", "assistant", "tool", "user"]);
    expect(items[3]).toMatchObject({ id: "tool-1", status: "success", result: "45 passed" });
    expect(items[4]).toMatchObject({ kind: "user", images: [{ mimeType: "image/png", data: "abc" }] });
  });

  it("parses Codex messages, reasoning, and function results", () => {
    const items = parseChatLines("codex", [
      JSON.stringify({ type: "response_item", timestamp: "2026-08-22T10:00:00.000Z", payload: { type: "message", id: "u1", role: "user", content: [{ type: "input_text", text: "Fix it" }] } }),
      JSON.stringify({ type: "response_item", timestamp: "2026-08-22T10:00:01.000Z", payload: { type: "reasoning", id: "think-1", summary: [{ text: "Inspecting" }] } }),
      JSON.stringify({ type: "response_item", timestamp: "2026-08-22T10:00:02.000Z", payload: { type: "function_call", id: "call-row", call_id: "call-1", name: "shell", arguments: "{\"command\":\"npm test\"}" } }),
      JSON.stringify({ type: "response_item", timestamp: "2026-08-22T10:00:03.000Z", payload: { type: "function_call_output", call_id: "call-1", output: "45 passed" } }),
      JSON.stringify({ type: "response_item", timestamp: "2026-08-22T10:00:04.000Z", payload: { type: "message", id: "a1", role: "assistant", content: [{ type: "output_text", text: "Done" }] } }),
    ]);

    expect(items.map(({ kind }) => kind)).toEqual(["user", "thinking", "tool", "assistant"]);
    expect(items[2]).toMatchObject({ id: "call-1", name: "Shell", status: "success", result: "45 passed" });
  });

  it("parses Pi messages and tool results", () => {
    const items = parseChatLines("pi", [
      JSON.stringify({ type: "message", id: "u1", timestamp: "2026-08-22T10:00:00.000Z", message: { role: "user", content: [{ type: "text", text: "Fix it" }] } }),
      JSON.stringify({ type: "message", id: "a1", timestamp: "2026-08-22T10:00:01.000Z", message: { role: "assistant", content: [
        { type: "thinking", thinking: "Inspecting" },
        { type: "toolCall", id: "tool-1", name: "bash", arguments: { command: "npm test" } },
      ] } }),
      JSON.stringify({ type: "message", id: "r1", timestamp: "2026-08-22T10:00:02.000Z", message: { role: "toolResult", toolCallId: "tool-1", isError: true, content: [{ type: "text", text: "failed" }] } }),
      JSON.stringify({ type: "message", id: "a2", timestamp: "2026-08-22T10:00:03.000Z", message: { role: "assistant", content: [{ type: "text", text: "Try again" }] } }),
    ]);

    expect(items.map(({ kind }) => kind)).toEqual(["user", "thinking", "tool", "assistant"]);
    expect(items[2]).toMatchObject({ status: "error", result: "failed" });
  });

  it("pages backward without repeating visible messages", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "agent-visor-chat-"));
    const transcript = path.join(directory, "session.jsonl");
    try {
      const lines = Array.from({ length: 5 }, (_, index) => JSON.stringify({
        type: "message",
        id: `message-${index}`,
        timestamp: `2026-08-22T10:0${index}:00.000Z`,
        message: { role: "user", content: [{ type: "text", text: `Message ${index}` }] },
      }));
      await writeFile(transcript, `${lines.join("\n")}\n`);
      const session = {
        id: "session-1", provider: "pi", cwd: "/tmp", owner: "Pi", section: "history",
        updatedAt: "2026-08-22T10:04:00.000Z", canOpenOwner: false, canEnterChat: true,
        chatPath: transcript,
      } as const;

      const newest = await readChatPage(session, undefined, 2);
      const earlier = await readChatPage(session, newest.nextBefore, 2);

      expect(newest.items.map(({ id }) => id)).toEqual(["message-3", "message-4"]);
      expect(earlier.items.map(({ id }) => id)).toEqual(["message-1", "message-2"]);
      expect(newest.hasMoreBefore).toBe(true);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("parses Cursor messages and keeps its tools read-only", () => {
    const items = parseChatLines("cursor", [
      JSON.stringify({ role: "user", message: { content: [{ type: "text", text: "Fix it" }] } }),
      JSON.stringify({ role: "assistant", message: { content: [
        { type: "text", text: "Inspecting" },
        { type: "tool_use", name: "Shell", input: { command: "npm test" } },
      ] } }),
      JSON.stringify({ type: "turn_ended", status: "completed" }),
    ]);

    expect(items.map(({ kind }) => kind)).toEqual(["user", "assistant", "tool"]);
    expect(items[2]).toMatchObject({ name: "Shell", status: "success" });
  });
});
