import { describe, expect, it } from "vitest";
import {
  defaultChatVisibility,
  type ChatItem,
  type ChatVisibility,
} from "@agent-visor/protocol";
import {
  chatMetadataRows,
  filterChatItems,
  filterChatTurns,
  groupChatTurns,
  mergeChatLatest,
  mergeChatPage,
  mergeChatPages,
  shouldGroupChatTurns,
} from "./chat-presentation.js";

const item = (id: string, kind: ChatItem["kind"], text = id): ChatItem => {
  if (kind === "user") return { id, kind, text, images: [] };
  if (kind === "tool") return { id, kind, name: "Bash", input: {}, status: "success" };
  if (kind === "system") return { id, kind, text, tone: "neutral" };
  return { id, kind, text };
};

describe("Chat presentation", () => {
  it("groups work under its prompt and keeps the final answer prominent", () => {
    const turns = groupChatTurns([
      item("user-1", "user"),
      item("thinking-1", "thinking"),
      item("tool-1", "tool"),
      item("answer-1", "assistant"),
      item("user-2", "user"),
      item("working-2", "thinking"),
    ]);

    expect(turns).toMatchObject([
      { id: "user-1", prompt: { id: "user-1" }, work: [{ id: "thinking-1" }, { id: "tool-1" }], answers: [{ id: "answer-1" }], live: false },
      { id: "user-2", prompt: { id: "user-2" }, work: [{ id: "working-2" }], answers: [], live: true },
    ]);
  });

  it("applies every supported Chat visibility rule at render time", () => {
    const toolRules: Array<[string, keyof ChatVisibility]> = [
      ["Bash", "showBash"], ["Read", "showRead"], ["Write", "showWrite"],
      ["Edit", "showEdit"], ["Grep", "showGrep"], ["Glob", "showGlob"],
      ["Web Fetch", "showWebFetch"], ["Web Search", "showWebSearch"],
      ["Todo Write", "showTodoWrite"], ["Task", "showTask"],
      ["Ask User Question", "showAskUserQuestion"], ["Bash Output", "showBashOutput"],
      ["Kill Shell", "showKillShell"], ["Enter Plan Mode", "showPlanMode"],
      ["Mcp Github Search", "showMCP"], ["Custom Tool", "showOtherTools"],
    ];
    for (const [name, setting] of toolRules) {
      const rules = { ...defaultChatVisibility, [setting]: false };
      expect(filterChatItems([
        { id: setting, kind: "tool", name, input: {}, status: "success" },
      ], rules)).toEqual([]);
    }
    expect(filterChatItems([{
      id: "exec", kind: "tool", name: "Exec Command", family: "bash",
      input: {}, status: "success",
    }], { ...defaultChatVisibility, showBash: false })).toEqual([]);

    const rules = {
      ...defaultChatVisibility,
      showUserMessage: false,
      showAssistantMessage: false,
      showThinking: false,
      showInterrupted: false,
      showCompactBoundary: false,
    };
    expect(filterChatItems([
      item("user", "user"), item("assistant", "assistant"), item("thinking", "thinking"),
      { id: "interrupted", kind: "system", text: "interrupted", tone: "error", category: "interrupted" },
      { id: "compact", kind: "system", text: "compact", tone: "compact", category: "compact_boundary" },
      { id: "other", kind: "system", text: "other", tone: "neutral", category: "other" },
    ], rules).map(({ id }) => id)).toEqual(["other"]);

    expect(shouldGroupChatTurns("Claude Code", { ...defaultChatVisibility, collapseClaudeTurns: false })).toBe(false);
    expect(shouldGroupChatTurns("Codex", { ...defaultChatVisibility, collapseCodexTurns: false })).toBe(false);
    expect(shouldGroupChatTurns("Pi", { ...defaultChatVisibility, collapsePiTurns: false })).toBe(false);
    expect(shouldGroupChatTurns("Cursor", defaultChatVisibility)).toBe(true);

    const hiddenPrompts = filterChatTurns(groupChatTurns([
      item("prompt-1", "user"), item("answer-1", "assistant"),
      item("prompt-2", "user"), item("tool-2", "tool"), item("answer-2", "assistant"),
    ]), { ...defaultChatVisibility, showUserMessage: false });
    expect(hiddenPrompts).toMatchObject([
      { prompt: undefined, answers: [{ id: "answer-1" }] },
      { prompt: undefined, work: [{ id: "tool-2" }], answers: [{ id: "answer-2" }] },
    ]);
  });

  it("formats only authoritative Chat metadata", () => {
    expect(chatMetadataRows({
      model: "GPT-5.6-Sol",
      modelId: "gpt-5.6-sol",
      modelProvider: "openai-codex",
      reasoningEffort: "high",
      permissionMode: "acceptEdits",
      sandbox: "workspace-write",
      approvalPolicy: "on-request",
      contextTokens: 12_000,
      contextWindow: 258_400,
    })).toEqual([
      { label: "Model", value: "GPT-5.6-Sol" },
      { label: "Model identifier", value: "gpt-5.6-sol" },
      { label: "Model provider", value: "OpenAI Codex" },
      { label: "Reasoning", value: "High" },
      { label: "Permission", value: "Accept Edits" },
      { label: "Sandbox", value: "Workspace Write" },
      { label: "Approval", value: "On Request" },
      { label: "Context", value: "12,000 / 258,400 tokens (5%)" },
    ]);
    expect(chatMetadataRows({})).toEqual([]);
  });

  it("replaces the newest overlap without dropping loaded history", () => {
    expect(mergeChatLatest(
      [item("one", "user"), item("two", "assistant"), item("three", "assistant")],
      [item("two", "assistant", "updated"), item("three", "assistant"), item("four", "assistant")],
    ).map(({ id }) => id)).toEqual(["one", "two", "three", "four"]);
  });

  it("keeps latest metadata when earlier history loads", () => {
    const current = {
      type: "chat_page" as const,
      sessionId: "session",
      items: [item("new", "assistant")],
      hasMoreBefore: true,
      nextBefore: 100,
      metadata: { model: "GPT-5.6 Sol" },
      capabilities: { canSendText: true, canSendImages: false, canApprove: false, canAnswer: false },
      pendingAction: null,
    };
    const earlier = {
      ...current,
      items: [item("old", "user")],
      hasMoreBefore: false,
      nextBefore: undefined,
      metadata: undefined,
    };
    expect(mergeChatPage(current, earlier, "earlier")).toMatchObject({
      items: [{ id: "old" }, { id: "new" }],
      metadata: { model: "GPT-5.6 Sol" },
      hasMoreBefore: false,
    });
    expect(mergeChatPage(current, {
      ...current, metadata: { model: "GPT-5.7" },
    }, "latest").metadata).toEqual({ model: "GPT-5.7" });
    expect(mergeChatPage(current, { ...current, metadata: undefined }, "latest").metadata)
      .toBeUndefined();
  });

  it("prepends earlier pages without duplicating streamed items", () => {
    expect(mergeChatPages(
      [item("three", "assistant"), item("four", "assistant")],
      [item("one", "user"), item("two", "assistant"), item("three", "assistant", "updated")],
    ).map(({ id }) => id)).toEqual(["one", "two", "three", "four"]);
  });
});
