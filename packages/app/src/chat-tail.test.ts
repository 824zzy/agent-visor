import { describe, expect, it } from "vitest";
import {
  CHAT_NEAR_BOTTOM_THRESHOLD,
  chatTailAction,
  classifyChatItemsChange,
  isNearChatBottom,
  shouldAutoPinOnComposerResize,
  shouldAutoPinOnInsert,
  shouldStreamPin,
} from "./chat-tail.js";

describe("Chat tail policy", () => {
  it("uses the Swift 80 px near-bottom boundary exactly", () => {
    expect(CHAT_NEAR_BOTTOM_THRESHOLD).toBe(80);
    expect(isNearChatBottom(0)).toBe(true);
    expect(isNearChatBottom(80)).toBe(true);
    expect(isNearChatBottom(80.01)).toBe(false);
  });

  it("pins tail inserts and stream growth only while already near the tail", () => {
    expect(shouldAutoPinOnInsert({ distanceFromBottom: 80, insertedAtTail: true })).toBe(true);
    expect(shouldAutoPinOnInsert({ distanceFromBottom: 81, insertedAtTail: true })).toBe(false);
    expect(shouldStreamPin(80)).toBe(true);
    expect(shouldStreamPin(81)).toBe(false);
  });

  it("never pins a head prepend, even when the reader is at the tail", () => {
    expect(shouldAutoPinOnInsert({ distanceFromBottom: 0, insertedAtTail: false })).toBe(false);
    expect(chatTailAction({ type: "head-prepend", distanceFromBottom: 0 })).toBe("preserve");
  });

  it("always pins an explicit local send", () => {
    expect(chatTailAction({ type: "local-send", distanceFromBottom: 10_000 })).toBe("pin-to-tail");
  });

  it("repins after composer resize only when the prior viewport was near the tail", () => {
    expect(shouldAutoPinOnComposerResize(80)).toBe(true);
    expect(shouldAutoPinOnComposerResize(81)).toBe(false);
    expect(chatTailAction({ type: "composer-resize", distanceFromBottom: 80 })).toBe("pin-to-tail");
    expect(chatTailAction({ type: "composer-resize", distanceFromBottom: 81 })).toBe("preserve");
  });

  it("repins after virtualized content remeasurement only when the prior layout was near the tail", () => {
    expect(chatTailAction({ type: "content-resize", distanceFromBottom: 80 })).toBe("pin-to-tail");
    expect(chatTailAction({ type: "content-resize", distanceFromBottom: 80.01 })).toBe("preserve");
    expect(chatTailAction({ type: "content-resize", distanceFromBottom: 81 })).toBe("preserve");
    expect(chatTailAction({ type: "content-resize", distanceFromBottom: 334 })).toBe("preserve");
  });

  it("classifies page changes by their public row identity", () => {
    expect(classifyChatItemsChange({ previousIDs: [], nextIDs: ["one"], contentChanged: true })).toBe("initial");
    expect(classifyChatItemsChange({ previousIDs: ["one"], nextIDs: ["one", "two"], contentChanged: true })).toBe("tail-insert");
    expect(classifyChatItemsChange({
      previousIDs: ["one", "two"],
      nextIDs: ["two", "three"],
      contentChanged: true,
    })).toBe("tail-insert");
    expect(classifyChatItemsChange({ previousIDs: ["two"], nextIDs: ["one", "two"], contentChanged: true })).toBe("head-prepend");
    expect(classifyChatItemsChange({ previousIDs: ["one"], nextIDs: ["one"], contentChanged: true })).toBe("stream-growth");
    expect(classifyChatItemsChange({ previousIDs: ["one"], nextIDs: ["one"], contentChanged: false })).toBe("unchanged");
  });
});
