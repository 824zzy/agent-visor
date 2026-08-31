import { describe, expect, it } from "vitest";
import {
  CHAT_INITIAL_PAGE_LIMIT,
  CHAT_PAGE_MAX_ITEMS,
  ChatPaginationWindow,
  boundChatItems,
} from "./chat-pagination-window.js";

describe("Chat pagination window", () => {
  it("starts with a bounded suffix and the protocol page request stays below its cap", () => {
    const window = new ChatPaginationWindow();
    expect(window.visibleLimit).toBe(100);
    expect(CHAT_INITIAL_PAGE_LIMIT).toBe(100);
    expect(CHAT_INITIAL_PAGE_LIMIT).toBeLessThanOrEqual(CHAT_PAGE_MAX_ITEMS);
    expect(window.slice(101)).toEqual({ start: 1, end: 101 });
  });

  it("expands by one bounded page when earlier history is requested", () => {
    const window = new ChatPaginationWindow();
    const next = window.expanded(400);
    expect(next.visibleLimit).toBe(200);
    expect(next.hasMore(400)).toBe(true);
  });

  it("can grow to retain a complete turn-aligned page within the safety cap", () => {
    const window = new ChatPaginationWindow().expandedTo(1_000);
    expect(window.visibleLimit).toBe(1_000);
    expect(window.expandedTo(5_000).visibleLimit).toBe(ChatPaginationWindow.safetyCap);
  });

  it("never renders more than the client safety cap and reports discarded history", () => {
    let window = new ChatPaginationWindow();
    for (let index = 0; index < 100; index += 1) window = window.expanded(10_000);
    expect(window.visibleLimit).toBe(ChatPaginationWindow.safetyCap);
    const result = boundChatItems(
      Array.from({ length: 10_000 }, (_, index) => index),
      window,
    );
    expect(result.items).toHaveLength(ChatPaginationWindow.safetyCap);
    expect(result.items[0]).toBe(6_000);
    expect(result.items.at(-1)).toBe(9_999);
    expect(result.hiddenCount).toBe(6_000);
    expect(result.atSafetyCap).toBe(true);
  });

  it("does not claim a client limit for a small, fully retained conversation", () => {
    const result = boundChatItems(["one", "two"], new ChatPaginationWindow());
    expect(result.items).toEqual(["one", "two"]);
    expect(result.hiddenCount).toBe(0);
    expect(result.atSafetyCap).toBe(false);
  });
});
