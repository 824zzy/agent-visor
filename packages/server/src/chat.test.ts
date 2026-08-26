import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  chatCapabilities,
  parseChatLines,
  parseChatMetadata,
  readChatPage,
} from "./chat.js";

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
    expect(items[3]).toMatchObject({
      id: "tool-1", family: "bash", status: "success", result: "45 passed",
    });
    expect(items[4]).toMatchObject({ kind: "user", images: [{ mimeType: "image/png", data: "abc" }] });
  });

  it("preserves provider session metadata rows for visibility controls", () => {
    const claude = parseChatLines("claude_code", [
      JSON.stringify({ type: "system", subtype: "turn_duration", uuid: "duration", durationMs: 1_250 }),
      JSON.stringify({ type: "system", subtype: "away_summary", uuid: "recap", content: "Earlier work" }),
      JSON.stringify({ type: "system", subtype: "compact_boundary", uuid: "compact", compactMetadata: { preTokens: 9_000 } }),
      JSON.stringify({ type: "system", subtype: "local_command", uuid: "local", content: "<local-command-stdout>Reloaded</local-command-stdout>" }),
      JSON.stringify({ type: "user", uuid: "interrupted", message: { role: "user", content: "[Request interrupted by user]" } }),
    ]);
    expect(claude.map((item) => item.kind === "system" ? item.category : item.kind)).toEqual([
      "turn_duration", "recap", "compact_boundary", "local_command_output", "interrupted",
    ]);

    const codex = parseChatLines("codex", [
      JSON.stringify({ type: "event_msg", payload: { type: "task_complete", turn_id: "turn", duration_ms: 2_500 } }),
      JSON.stringify({ type: "event_msg", payload: { type: "context_compacted", turn_id: "turn" } }),
    ]);
    expect(codex.map((item) => item.kind === "system" ? item.category : item.kind))
      .toEqual(["turn_duration", "compact_boundary"]);

    const pi = parseChatLines("pi", [
      JSON.stringify({ type: "compaction", id: "compact", summary: "Earlier work" }),
    ]);
    expect(pi[0]).toMatchObject({ kind: "system", category: "compact_boundary" });
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
    expect(items[2]).toMatchObject({
      id: "call-1", name: "Shell", family: "bash", status: "success", result: "45 passed",
    });
    expect(parseChatLines("codex", [
      JSON.stringify({ type: "response_item", payload: {
        type: "function_call", call_id: "patch", name: "apply_patch", arguments: "{}",
      } }),
    ])[0]).toMatchObject({ family: "edit" });
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

  it("reads latest authoritative provider metadata", () => {
    expect(parseChatMetadata("codex", [
      JSON.stringify({ type: "session_meta", payload: { model_provider: "openai" } }),
      JSON.stringify({ type: "turn_context", payload: {
        model: "gpt-5.6-sol", effort: "high", approval_policy: "on-request",
        sandbox_policy: { type: "workspace-write" },
      } }),
      JSON.stringify({ type: "event_msg", payload: { type: "token_count", info: {
        last_token_usage: { total_tokens: 12_000 }, model_context_window: 258_400,
      } } }),
    ], { "gpt-5.6-sol": { displayName: "GPT-5.6-Sol", contextWindow: 258_400 } }))
      .toEqual({
        model: "GPT-5.6-Sol", modelId: "gpt-5.6-sol", modelProvider: "openai",
        reasoningEffort: "high",
        sandbox: "workspace-write", approvalPolicy: "on-request",
        contextTokens: 12_000, contextWindow: 258_400,
      });

    expect(parseChatMetadata("codex", [
      JSON.stringify({ type: "turn_context", payload: { model: "gpt-old" } }),
      JSON.stringify({ type: "event_msg", payload: { type: "token_count", info: {
        last_token_usage: { total_tokens: 10_000 }, model_context_window: 100_000,
      } } }),
      JSON.stringify({ type: "turn_context", payload: { model: "gpt-new" } }),
    ], { "gpt-new": { displayName: "GPT-New", contextWindow: 200_000 } }))
      .toEqual({ model: "GPT-New", modelId: "gpt-new", contextWindow: 200_000 });

    expect(parseChatMetadata("claude_code", [
      JSON.stringify({ type: "user", permissionMode: "acceptEdits" }),
      JSON.stringify({ type: "assistant", effort: "medium", message: {
        model: "claude-opus-4-6", usage: {
          input_tokens: 200, cache_read_input_tokens: 700, cache_creation_input_tokens: 100,
        },
      } }),
    ])).toEqual({
      model: "Opus 4.6", modelId: "claude-opus-4-6", reasoningEffort: "medium",
      permissionMode: "acceptEdits", contextTokens: 1_000,
    });

    expect(parseChatMetadata("pi", [
      JSON.stringify({ type: "model_change", provider: "openai-codex", modelId: "gpt-5.6-sol" }),
      JSON.stringify({ type: "thinking_level_change", thinkingLevel: "high" }),
      JSON.stringify({ type: "message", message: {
        role: "assistant", usage: { input: 1_000, cacheRead: 900, cacheWrite: 100 },
      } }),
    ], { "gpt-5.6-sol": { displayName: "GPT-5.6 Sol", contextWindow: 114_688 } }))
      .toEqual({
        model: "GPT-5.6 Sol", modelId: "gpt-5.6-sol", modelProvider: "openai-codex",
        reasoningEffort: "high",
        contextTokens: 2_000, contextWindow: 114_688,
      });
  });

  it("enables only verified provider message transports", () => {
    const base = {
      id: "session-1", provider: "pi" as const, cwd: "/tmp/project", owner: "Ghostty",
      section: "working" as const, updatedAt: "2026-08-23T00:00:00.000Z",
      canOpenOwner: true, canEnterChat: true,
    };
    expect(chatCapabilities({ ...base, messageTransport: "terminal" })).toMatchObject({
      canSendText: true, canSendImages: true,
    });
    expect(chatCapabilities({
      ...base,
      provider: "claude_code",
      messageTransport: "terminal",
      controlTarget: {
        kind: "terminal",
        target: { application: "Terminal", tty: "ttys001", cwd: "/tmp/project" },
      },
    })).toMatchObject({ canSendText: true, canSendImages: false });
    expect(chatCapabilities({ ...base, provider: "cursor" })).toMatchObject({
      canSendText: false, canSendImages: false,
    });
  });

  it("pages backward without repeating visible messages", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "agent-visor-chat-"));
    const transcript = path.join(directory, "session.jsonl");
    try {
      const lines = [
        JSON.stringify({
          type: "model_change", provider: "openai-codex", modelId: "gpt-5.6-sol",
        }),
        ...Array.from({ length: 5 }, (_, index) => JSON.stringify({
          type: "message",
          id: `message-${index}`,
          timestamp: `2026-08-22T10:0${index}:00.000Z`,
          message: { role: "user", content: [{ type: "text", text: `Message ${index}` }] },
        })),
      ];
      await writeFile(transcript, `${lines.join("\n")}\n`);
      const session = {
        id: "session-1", provider: "pi", cwd: "/tmp", owner: "Pi", section: "history",
        updatedAt: "2026-08-22T10:04:00.000Z", canOpenOwner: false, canEnterChat: true,
        chatPath: transcript,
        modelCatalog: {
          "gpt-5.6-sol": { displayName: "GPT-5.6 Sol", contextWindow: 114_688 },
        },
      } as const;

      const newest = await readChatPage(session, undefined, 2);
      const earlier = await readChatPage(session, newest.nextBefore, 2);

      expect(newest.items.map(({ id }) => id)).toEqual(["message-3", "message-4"]);
      expect(earlier.items.map(({ id }) => id)).toEqual(["message-1", "message-2"]);
      expect(newest.hasMoreBefore).toBe(true);
      expect(newest.metadata).toEqual({
        model: "GPT-5.6 Sol", modelId: "gpt-5.6-sol",
        modelProvider: "openai-codex", contextWindow: 114_688,
      });
      expect(earlier.metadata).toBeUndefined();
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
