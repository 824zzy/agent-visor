import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { parseChatLines, readChatPage } from "./chat.js";

describe("provider Chat visibility boundaries", () => {
  it("hides Claude metadata user records before canonical chat items", () => {
    const items = parseChatLines("claude_code", [JSON.stringify({
      type: "user",
      uuid: "claude-meta-user",
      isMeta: true,
      message: { role: "user", content: "Injected setup" },
    })]);

    expect(items).toEqual([]);
  });

  it("hides Claude compact-summary refeed records", () => {
    const items = parseChatLines("claude_code", [JSON.stringify({
      type: "user",
      uuid: "claude-compact-refeed",
      isCompactSummary: true,
      message: { role: "user", content: "Conversation checkpoint" },
    })]);

    expect(items).toEqual([]);
  });

  it("hides Claude synthetic assistant padding while keeping real assistant output", () => {
    const items = parseChatLines("claude_code", [
      JSON.stringify({
        type: "assistant",
        uuid: "claude-synthetic",
        message: {
          role: "assistant",
          model: "<synthetic>",
          content: [{ type: "text", text: "No response requested." }],
        },
      }),
      JSON.stringify({
        type: "assistant",
        uuid: "claude-real",
        message: {
          role: "assistant",
          model: "claude-sonnet-4-6",
          content: [{ type: "text", text: "Visible answer" }],
        },
      }),
    ]);

    expect(items).toEqual([{ id: "claude-real-0", kind: "assistant", text: "Visible answer", timestamp: undefined }]);
  });

  it("normalizes Claude slash-command transport into a meaningful user command", () => {
    const items = parseChatLines("claude_code", [JSON.stringify({
      type: "user",
      uuid: "claude-command",
      message: {
        role: "user",
        content: "<command-message>compact</command-message>\n<command-name>/compact</command-name>\n<command-args>focus on api</command-args>",
      },
    })]);

    expect(items).toEqual([{
      id: "claude-command",
      kind: "user",
      text: "/compact focus on api",
      images: [],
      timestamp: undefined,
    }]);
  });

  it("preserves a user-typed ordinary slash command", () => {
    const items = parseChatLines("claude_code", [JSON.stringify({
      type: "user",
      uuid: "claude-ordinary-command",
      message: { role: "user", content: "/compact focus on api" },
    })]);

    expect(items).toEqual([{
      id: "claude-ordinary-command",
      kind: "user",
      text: "/compact focus on api",
      images: [],
      timestamp: undefined,
    }]);
  });

  it("preserves a quoted complete Claude command example", () => {
    const body = "Please explain this example:\n```xml\n<command-name>/compact</command-name>\n<command-args>example</command-args>\n```";
    const items = parseChatLines("claude_code", [JSON.stringify({
      type: "user",
      uuid: "claude-quoted-command",
      message: { role: "user", content: body },
    })]);

    expect(items).toEqual([{
      id: "claude-quoted-command",
      kind: "user",
      text: body,
      images: [],
      timestamp: undefined,
    }]);
  });

  it("preserves a quoted system-reminder example in Claude user content", () => {
    const body = "Explain this:\n```xml\n<system-reminder>example</system-reminder>\n```";
    const items = parseChatLines("claude_code", [JSON.stringify({
      type: "user",
      uuid: "claude-quoted-reminder",
      message: { role: "user", content: body },
    })]);

    expect(items).toEqual([{
      id: "claude-quoted-reminder",
      kind: "user",
      text: body,
      images: [],
      timestamp: undefined,
    }]);
  });

  it("preserves incomplete Claude command transport as authored text", () => {
    const body = "<command-name>/compact</command-name>\n<command-args>unfinished";
    const items = parseChatLines("claude_code", [JSON.stringify({
      type: "user",
      uuid: "claude-incomplete-command",
      message: { role: "user", content: body },
    })]);

    expect(items).toEqual([{
      id: "claude-incomplete-command",
      kind: "user",
      text: body,
      images: [],
      timestamp: undefined,
    }]);
  });

  it("preserves Claude compaction boundaries as system activity", () => {
    const items = parseChatLines("claude_code", [JSON.stringify({
      type: "system",
      uuid: "claude-compact-boundary",
      isMeta: true,
      isCompactSummary: true,
      subtype: "compact_boundary",
      timestamp: "2026-09-02T07:42:00.000Z",
    })]);

    expect(items).toEqual([{
      id: "claude-compact-boundary",
      kind: "system",
      category: "compact_boundary",
      tone: "compact",
      text: "Context compacted",
      timestamp: "2026-09-02T07:42:00.000Z",
    }]);
  });

  it("preserves Claude approval errors, tool binding, and image prompts", () => {
    const items = parseChatLines("claude_code", [
      JSON.stringify({
        type: "assistant",
        uuid: "claude-approval",
        message: {
          role: "assistant",
          content: [{
            type: "tool_use",
            id: "approval-1",
            name: "AskUserQuestion",
            input: { questions: [{ question: "Continue?" }] },
          }],
        },
      }),
      JSON.stringify({
        type: "user",
        uuid: "claude-tool-result",
        message: {
          role: "user",
          content: [
            { type: "tool_result", tool_use_id: "approval-1", is_error: true, content: "Denied" },
            { type: "image", source: { type: "base64", media_type: "image/png", data: "iVBORw0KGgo=" } },
          ],
        },
      }),
    ]);

    expect(items.map(({ kind }) => kind)).toEqual(["tool", "user"]);
    expect(items[0]).toMatchObject({
      id: "approval-1",
      status: "error",
      result: "Denied",
    });
    expect(items[1]).toMatchObject({
      id: "claude-tool-result",
      images: [{ name: "image-1", mimeType: "image/png", data: "iVBORw0KGgo=" }],
    });
  });

  it("keeps Claude images beside normalized command text", () => {
    const items = parseChatLines("claude_code", [JSON.stringify({
      type: "user",
      uuid: "claude-command-image",
      message: {
        role: "user",
        content: [
          {
            type: "text",
            text: "<command-name>/review</command-name>\n<command-args>this file</command-args>",
          },
          { type: "image", source: { type: "base64", media_type: "image/png", data: "iVBORw0KGgo=" } },
        ],
      },
    })]);

    expect(items).toEqual([{
      id: "claude-command-image",
      kind: "user",
      text: "/review this file",
      images: [{ name: "image-1", mimeType: "image/png", data: "iVBORw0KGgo=" }],
      timestamp: undefined,
    }]);
  });

  it("drops Cursor system records instead of treating them as assistant output", () => {
    const items = parseChatLines("cursor", [JSON.stringify({
      role: "system",
      message: { content: [{ type: "text", text: "Internal setup" }] },
    })]);

    expect(items).toEqual([]);
  });

  it.each(["developer", "tool", "unknown", ""])("drops Cursor non-chat role %j", (role) => {
    const items = parseChatLines("cursor", [JSON.stringify({
      role,
      message: { content: [{ type: "text", text: "Not a conversation turn" }] },
    })]);

    expect(items).toEqual([]);
  });

  it("extracts a well-formed Cursor timestamp and user-query scaffold", () => {
    const items = parseChatLines("cursor", [JSON.stringify({
      role: "user",
      message: {
        content: [{
          type: "text",
          text: "<timestamp>2026-09-02T07:42:00Z</timestamp>\n<user_query>Explain this</user_query>",
        }],
      },
    })]);

    expect(items).toEqual([{
      id: "cursor-0-0",
      kind: "user",
      text: "Explain this",
      images: [],
      timestamp: "2026-09-02T07:42:00.000Z",
    }]);
  });

  it.each([
    "Explain this example:\n```xml\n<timestamp>2026-09-02T07:42:00Z</timestamp>\n<user_query>quoted</user_query>\n```",
    "Before <timestamp>2026-09-02T07:42:00Z</timestamp><user_query>mixed</user_query> after",
    "<timestamp>2026-09-02T07:42:00Z</timestamp>\n<user_query>incomplete",
  ])("preserves quoted, mixed, or incomplete Cursor scaffolding: %s", (body) => {
    const items = parseChatLines("cursor", [JSON.stringify({
      role: "user",
      message: { content: [{ type: "text", text: body }] },
    })]);

    expect(items).toEqual([{
      id: "cursor-0-0",
      kind: "user",
      text: body,
      images: [],
      timestamp: undefined,
    }]);
  });

  it("preserves a Cursor scaffold with an invalid timestamp", () => {
    const body = "<timestamp>not-a-date</timestamp>\n<user_query>keep this</user_query>";
    const items = parseChatLines("cursor", [JSON.stringify({
      role: "user",
      message: { content: [{ type: "text", text: body }] },
    })]);

    expect(items).toEqual([{
      id: "cursor-0-0",
      kind: "user",
      text: body,
      images: [],
      timestamp: undefined,
    }]);
  });

  it("preserves Claude duplicate command tags instead of partially normalizing", () => {
    const body = "<command-name>/compact</command-name>\n<command-name>literal example</command-name>\n<command-args>x</command-args>";
    const items = parseChatLines("claude_code", [JSON.stringify({
      type: "user",
      uuid: "claude-duplicate-command",
      message: { role: "user", content: body },
    })]);

    expect(items).toEqual([{
      id: "claude-duplicate-command",
      kind: "user",
      text: body,
      images: [],
      timestamp: undefined,
    }]);
  });

  it("preserves Claude command text with an unmatched trailing close tag", () => {
    const body = "<command-name>/compact</command-name>\n<command-args>x</command-args></command-args>";
    const items = parseChatLines("claude_code", [JSON.stringify({
      type: "user",
      uuid: "claude-trailing-command-close",
      message: { role: "user", content: body },
    })]);

    expect(items).toEqual([{
      id: "claude-trailing-command-close",
      kind: "user",
      text: body,
      images: [],
      timestamp: undefined,
    }]);
  });

  it("preserves Cursor nested user-query tags instead of stripping an outer match", () => {
    const body = "<timestamp>2026-09-02T07:42:00Z</timestamp><user_query>foo<user_query>bar</user_query>";
    const items = parseChatLines("cursor", [JSON.stringify({
      role: "user",
      message: { content: [{ type: "text", text: body }] },
    })]);

    expect(items).toEqual([{
      id: "cursor-0-0",
      kind: "user",
      text: body,
      images: [],
      timestamp: undefined,
    }]);
  });

  it("keeps Claude internal-only records out of page items and transcript evidence", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "agent-visor-claude-visibility-"));
    const transcript = path.join(directory, "session.jsonl");
    const session = {
      id: "claude-internal-only",
      provider: "claude_code" as const,
      cwd: "/tmp/project",
      owner: "Claude Code",
      section: "history" as const,
      updatedAt: "2026-09-02T07:42:00.000Z",
      canOpenOwner: true,
      canEnterChat: true,
      chatPath: transcript,
    };
    try {
      await writeFile(transcript, [
        JSON.stringify({
          type: "user",
          uuid: "meta",
          isMeta: true,
          message: { role: "user", content: "Injected metadata" },
        }),
        JSON.stringify({
          type: "user",
          uuid: "summary",
          isCompactSummary: true,
          message: { role: "user", content: "Compaction refeed" },
        }),
        JSON.stringify({
          type: "assistant",
          uuid: "synthetic",
          message: { role: "assistant", model: "<synthetic>", content: [{ type: "text", text: "No response requested." }] },
        }),
      ].join("\n") + "\n");

      const page = await readChatPage(session);

      expect(page.items).toEqual([]);
      expect(page.transcriptEvidence).toEqual({ authoritative: false, complete: true });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
});
