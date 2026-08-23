import { describe, expect, it } from "vitest";
import type { ChatItem } from "@agent-visor/protocol";
import { groupChatTurns, mergeChatLatest, mergeChatPages } from "./chat-presentation.js";

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

  it("replaces the newest overlap without dropping loaded history", () => {
    expect(mergeChatLatest(
      [item("one", "user"), item("two", "assistant"), item("three", "assistant")],
      [item("two", "assistant", "updated"), item("three", "assistant"), item("four", "assistant")],
    ).map(({ id }) => id)).toEqual(["one", "two", "three", "four"]);
  });

  it("prepends earlier pages without duplicating streamed items", () => {
    expect(mergeChatPages(
      [item("three", "assistant"), item("four", "assistant")],
      [item("one", "user"), item("two", "assistant"), item("three", "assistant", "updated")],
    ).map(({ id }) => id)).toEqual(["one", "two", "three", "four"]);
  });
});
