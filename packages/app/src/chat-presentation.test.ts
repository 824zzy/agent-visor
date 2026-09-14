import { describe, expect, it } from "vitest";
import {
  defaultChatVisibility,
  type ChatItem,
  type ChatVisibility,
} from "@agent-visor/protocol";
import {
  historyImageDataURI,
  chatMetadataRows,
  accessibleThinkingText,
  filterChatItems,
  filterChatTurns,
  groupChatTurns,
  isTurnDurationItem,
  isTurnExpandedByDefault,
  mergeChatLatest,
  mergeChatPage,
  mergeChatPages,
  parseChatText,
  shouldGroupChatTurns,
  summarizeTurnWork,
  turnActivityLabel,
  turnDurationLabel,
} from "./chat-presentation.js";

const item = (
  id: string,
  kind: ChatItem["kind"],
  text = id,
  activity: Extract<ChatItem, { kind: "activity" }>["activity"] = "subagent",
): ChatItem => {
  if (kind === "user") return { id, kind, text, images: [] };
  if (kind === "tool") return { id, kind, name: "Bash", input: {}, status: "success" };
  if (kind === "system") return { id, kind, text, tone: "neutral" };
  if (kind === "activity") {
    return { id, kind, activity, title: "Review agent", text };
  }
  return { id, kind, text };
};

describe("Chat presentation", () => {
  it("only presents bounded, signature-validated data image URIs", () => {
    const png = {
      name: "diagram.png",
      mimeType: "image/png" as const,
      data: "data:image/png;base64,iVBORw0KGgo=",
    };
    expect(historyImageDataURI(png)).toBe(png.data);
    expect(historyImageDataURI({ ...png, data: "https://example.com/diagram.png" })).toBeUndefined();
    expect(historyImageDataURI({ ...png, data: "/Users/me/diagram.png" })).toBeUndefined();
    expect(historyImageDataURI({ ...png, data: "file:///Users/me/diagram.png" })).toBeUndefined();
    expect(historyImageDataURI({ ...png, data: "data:image/png;base64,YWJj" })).toBeUndefined();
    expect(historyImageDataURI({ ...png, data: "data:image/jpeg;base64,iVBORw0KGgo=" })).toBeUndefined();
    expect(historyImageDataURI({ ...png, data: `data:image/png;base64,${"A".repeat(13_333_337)}` })).toBeUndefined();
    expect(historyImageDataURI({ ...png, data: "data:image/bmp;base64,Qk1Q" })).toBeUndefined();
    expect(historyImageDataURI({ ...png, data: "data:image/png;base64,not base64" })).toBeUndefined();
  });

  it("normalizes raw history base64 and infers a missing MIME from its signature", () => {
    const rawPng = "iVBORw0KGgo=";
    expect(historyImageDataURI({ mimeType: "image/png", data: rawPng })).toBe(
      `data:image/png;base64,${rawPng}`,
    );
    expect(historyImageDataURI({ data: rawPng })).toBe(`data:image/png;base64,${rawPng}`);
    expect(historyImageDataURI({ mimeType: "image/jpeg", data: rawPng })).toBeUndefined();
    expect(historyImageDataURI({ data: "data:image/png;base64,${rawPng}" })).toBeUndefined();
  });

  it("exposes thinking text without raw basic Markdown markers", () => {
    expect(accessibleThinkingText("**Inspecting** files")).toBe("Inspecting files");
    expect(accessibleThinkingText("```\nconst result = true;\n```")).toBe("const result = true;");
    expect(accessibleThinkingText("```text\n**done** `nested`\n```")).toBe("**done** `nested`");
    expect(accessibleThinkingText("before ```code``` after")).toBe("before code after");
    expect(accessibleThinkingText("before ```ts\nconst result = true;\n``` after")).toBe("before const result = true; after");
    expect(accessibleThinkingText("before ```**done** `nested` ``` after")).toBe("before **done** `nested` after");
  });

  it("shares inline and fence semantics for valid and malformed Markdown", () => {
    expect(parseChatText("**a*b**")).toEqual([
      { kind: "text", text: "**a*b**" },
    ]);
    expect(parseChatText("****")).toEqual([
      { kind: "text", text: "****" },
    ]);
    expect(parseChatText("bare **")).toEqual([
      { kind: "text", text: "bare **" },
    ]);
    expect(parseChatText("lone `")).toEqual([
      { kind: "text", text: "lone `" },
    ]);
    expect(parseChatText("**bold** and `literal`")).toEqual([
      { kind: "bold", text: "bold" },
      { kind: "text", text: " and " },
      { kind: "inline-code", text: "literal" },
    ]);
    expect(parseChatText("```text\n**done** `nested`\n```")).toEqual([
      { kind: "fenced-code", text: "**done** `nested`\n" },
    ]);
    expect(parseChatText("before ```code``` after")).toEqual([
      { kind: "text", text: "before " },
      { kind: "fenced-code", text: "code" },
      { kind: "text", text: " after" },
    ]);
    expect(parseChatText("```ts\nconst one = 1;\nconst two = 2;\n```")).toEqual([
      { kind: "fenced-code", text: "const one = 1;\nconst two = 2;\n" },
    ]);
    expect(parseChatText("before ```js\n**bold** `literal`\n``` after")).toEqual([
      { kind: "text", text: "before " },
      { kind: "fenced-code", text: "**bold** `literal`\n" },
      { kind: "text", text: " after" },
    ]);
    expect(parseChatText("first\n```\nsecond\nthird\n```\nlast")).toEqual([
      { kind: "text", text: "first\n" },
      { kind: "fenced-code", text: "\nsecond\nthird\n" },
      { kind: "text", text: "\nlast" },
    ]);
    expect(accessibleThinkingText("**a*b**")).toBe("**a*b**");
    expect(accessibleThinkingText("****")).toBe("****");
    expect(accessibleThinkingText("bare **")).toBe("bare **");
    expect(accessibleThinkingText("lone `")).toBe("lone `");
    expect(accessibleThinkingText("**bold** and `literal`")).toBe("bold and literal");
    expect(accessibleThinkingText("```text\n**done** `nested`\n```")).toBe("**done** `nested`");
    expect(accessibleThinkingText("before ```code``` after")).toBe("before code after");
    expect(accessibleThinkingText("```ts\nconst one = 1;\nconst two = 2;\n```")).toBe("const one = 1; const two = 2;");
    expect(accessibleThinkingText("before ```js\n**bold** `literal`\n``` after")).toBe("before **bold** `literal` after");
    expect(accessibleThinkingText("first\n```\nsecond\nthird\n```\nlast")).toBe("first second third last");
  });

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

  it("starts a finished turn collapsed even when a step failed", () => {
    const failed: ChatItem = { ...item("tool-1", "tool"), status: "error" } as ChatItem;
    const [finished, live] = groupChatTurns([
      item("user-1", "user"),
      failed,
      item("answer-1", "assistant"),
      item("user-2", "user"),
      item("tool-2", "tool"),
    ]);

    expect(finished).toMatchObject({ live: false, work: [{ status: "error" }] });
    expect(isTurnExpandedByDefault(finished!)).toBe(false);
    expect(isTurnExpandedByDefault(live!)).toBe(true);
  });

  it("keeps a turn open while a tool waits for approval", () => {
    const waiting: ChatItem = { ...item("tool-1", "tool"), status: "waiting" } as ChatItem;
    const [turn] = groupChatTurns([item("user-1", "user"), waiting]);
    expect(isTurnExpandedByDefault(turn!)).toBe(true);

    // Even if a system row makes the turn look finished, the blocking step wins.
    expect(isTurnExpandedByDefault({ ...turn!, live: false })).toBe(true);
  });

  it("keeps structured agent activity visible when user messages are hidden", () => {
    const activity = item("activity-1", "activity", "Review finished.");
    const turns = filterChatTurns(groupChatTurns([
      item("prompt-1", "user", "Please review this"),
      activity,
      item("answer-1", "assistant", "The review is complete."),
    ]), { ...defaultChatVisibility, showUserMessage: false });

    expect(filterChatItems([activity], {
      ...defaultChatVisibility,
      showTask: false,
      showUserMessage: true,
    })).toEqual([]);
    expect(filterChatItems([activity], {
      ...defaultChatVisibility,
      showTask: false,
      showUserMessage: false,
    })).toEqual([]);
    expect(filterChatItems([activity], {
      ...defaultChatVisibility,
      showTask: true,
      showUserMessage: false,
    })).toEqual([activity]);
    expect(turns).toMatchObject([{
      prompt: undefined,
      work: [{ id: "activity-1", kind: "activity" }],
      answers: [{ id: "answer-1" }],
      live: false,
    }]);
  });

  it.each(["delegation", "background_task"] as const)("keeps %s activity in the work disclosure", (activity) => {
    const delegation = item("delegation-1", "activity", "Delegation finished.", activity);
    const turns = groupChatTurns([
      item("prompt-1", "user"),
      delegation,
      item("answer-1", "assistant", "The delegated work is complete."),
    ]);

    expect(filterChatItems([delegation], {
      ...defaultChatVisibility,
      showTask: true,
      showUserMessage: false,
    })).toEqual([delegation]);
    expect(turns).toMatchObject([{
      work: [{ id: "delegation-1", kind: "activity", activity }],
      answers: [{ id: "answer-1" }],
      live: false,
    }]);
  });

  it("keeps agent activity in work without moving a genuine answer into work", () => {
    const turns = groupChatTurns([
      item("prompt-1", "user"),
      item("thinking-1", "thinking"),
      item("answer-1", "assistant", "The main answer."),
      item("activity-1", "activity", "The delegated review finished."),
    ]);

    expect(turns).toMatchObject([{
      work: [{ id: "thinking-1" }, { id: "activity-1", kind: "activity" }],
      answers: [{ id: "answer-1" }],
      live: false,
    }]);
  });

  it("does not present activity-only history as an actively running turn", () => {
    const turns = groupChatTurns([
      item("activity-1", "activity", "Delegation completed."),
    ]);

    expect(turns).toMatchObject([{
      work: [{ id: "activity-1", kind: "activity" }],
      answers: [],
      live: false,
    }]);
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
      sessionState: { conversation: "open", turn: "ready", route: "available" } as const,
      stateRevision: 2,
      capabilities: { canSendText: false, canSendImages: false, canCancel: false, canApprove: false, canAnswer: false, unavailableReason: "turn_in_progress" as const },
      pendingAction: null,
    };
    const earlier = {
      ...current,
      items: [item("old", "user")],
      hasMoreBefore: false,
      nextBefore: undefined,
      metadata: undefined,
      sessionState: { conversation: "open", turn: "working", route: "waiting", unavailableReason: "turn_in_progress" } as const,
      stateRevision: 1,
      capabilities: { canSendText: true, canSendImages: true, canCancel: true, canApprove: false, canAnswer: false },
    };
    expect(mergeChatPage(current, earlier, "earlier")).toMatchObject({
      items: [{ id: "old" }, { id: "new" }],
      metadata: { model: "GPT-5.6 Sol" },
      sessionState: { conversation: "open", turn: "ready", route: "available" },
      stateRevision: 2,
      capabilities: { canSendText: false, canSendImages: false, canCancel: false, canApprove: false, canAnswer: false, unavailableReason: "turn_in_progress" },
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

  it("keeps bounded old rows behind one accessible gap when latest pages do not overlap", () => {
    const first = mergeChatLatest(
      [item("old", "assistant")],
      [item("new", "assistant")],
    );
    expect(first.map(({ id }) => id)).toEqual(["old", "chat-history-gap", "new"]);
    expect(first.find(({ id }) => id === "chat-history-gap")).toMatchObject({
      kind: "system",
      tone: "neutral",
      text: expect.stringMatching(/messages.*not shown/i),
    });

    const second = mergeChatLatest(first, [item("newer", "assistant")]);
    expect(second.map(({ id }) => id)).toEqual(["old", "new", "chat-history-gap", "newer"]);
    expect(second.filter(({ kind }) => kind === "system")).toHaveLength(1);
  });
  describe("turn header summary", () => {
    const tool = (
      id: string,
      family: Extract<ChatItem, { kind: "tool" }>["family"],
      status: Extract<ChatItem, { kind: "tool" }>["status"] = "success",
    ): ChatItem => ({ id, kind: "tool", name: id, family, input: {}, status });

    it("describes what a turn did, state-changing actions first", () => {
      const activity = summarizeTurnWork([
        item("think", "thinking"),
        tool("r1", "read"), tool("r2", "glob"), tool("g1", "grep"),
        tool("e1", "edit"), tool("w1", "write"), tool("e2", "edit"),
        tool("b1", "bash"),
      ]);
      expect(activity).toMatchObject({ edited: 3, ran: 1, read: 2, searched: 1, failed: 0, tools: 7, steps: 8 });
      expect(turnActivityLabel(activity)).toBe("Edited 3 files · Ran 1 command · +3 more");
      expect(turnActivityLabel(activity, 4)).toBe("Edited 3 files · Ran 1 command · Read 2 files · Searched 1 search");
    });

    it("counts failed and interrupted tool calls", () => {
      const activity = summarizeTurnWork([tool("b1", "bash", "error"), tool("b2", "bash", "interrupted"), tool("b3", "bash")]);
      expect(activity.failed).toBe(2);
      expect(turnActivityLabel(activity)).toBe("Ran 3 commands");
    });

    it("falls back to a step count when nothing is categorized", () => {
      expect(turnActivityLabel(summarizeTurnWork([item("think", "thinking")]))).toBe("1 step");
      expect(turnActivityLabel(summarizeTurnWork([tool("m1", "mcp"), tool("m2", "other"), tool("m3", undefined)]))).toBe("3 steps");
    });

    it("lifts the turn duration out of its system row", () => {
      const duration: ChatItem = {
        id: "duration", kind: "system", text: "Turn duration: 1m 31s", tone: "neutral", category: "turn_duration",
      };
      const [turn] = groupChatTurns([item("user-1", "user"), tool("b1", "bash"), item("answer", "assistant"), duration]);
      expect(isTurnDurationItem(duration)).toBe(true);
      expect(turnDurationLabel(turn!)).toBe("1m 31s");
      expect(turnDurationLabel({ ...turn!, answers: [item("answer", "assistant")] })).toBeUndefined();
    });

    it("sums the durations of several assistant turns under one prompt", () => {
      const row = (id: string, text: string): ChatItem =>
        ({ id, kind: "system", text: `Turn duration: ${text}`, tone: "neutral", category: "turn_duration" });
      const [turn] = groupChatTurns([
        item("user-1", "user"), tool("b1", "bash"), item("a1", "assistant"), row("d1", "6m 37s"),
        item("a2", "assistant"), row("d2", "42s"), item("a3", "assistant"), row("d3", "1.5s"),
      ]);
      expect(turnDurationLabel(turn!)).toBe("7m 21s");
      expect(turnDurationLabel({ ...turn!, answers: [row("odd", "a while")] })).toBe("a while");
    });
  });
});
