import { describe, expect, it } from "vitest";
import { browserCommand, changeContentScale, sessionShortcutEducation } from "./browser-shortcuts.js";

describe("browser shortcuts", () => {
  it("maps keyboard navigation and capability actions", () => {
    expect(browserCommand({ key: "ArrowDown" })).toEqual({ type: "move", offset: 1 });
    expect(browserCommand({ key: "ArrowUp" })).toEqual({ type: "move", offset: -1 });
    expect(browserCommand({ key: "Enter" })).toEqual({ type: "activate", alternate: false });
    expect(browserCommand({ key: "Enter", shiftKey: true })).toEqual({ type: "activate", alternate: true });
    expect(browserCommand({ key: "7", metaKey: true })).toEqual({ type: "hotkey", position: 6 });
    expect(browserCommand({ key: "f", metaKey: true })).toEqual({ type: "focus_search" });
    expect(browserCommand({ key: ",", metaKey: true })).toEqual({ type: "open_settings" });
    expect(browserCommand({ key: "[", metaKey: true })).toEqual({ type: "back" });
  });

  it("describes the configured global pill shortcuts", () => {
    expect(sessionShortcutEducation("optionCommand")).toEqual({
      hints: [
        { keys: "⌥⌘1–9", label: "Switch sessions" },
        { keys: "⌥⌘0", label: "Session menu" },
      ],
    });
    expect(sessionShortcutEducation("off")).toEqual({
      disabledMessage: "Global shortcuts off · Configure in Settings",
      hints: [],
    });
  });

  it("keeps global modifier families separate from content scaling", () => {
    expect(browserCommand({ key: "+", metaKey: true })).toEqual({ type: "scale", delta: 0.1 });
    expect(browserCommand({ key: "-", metaKey: true })).toEqual({ type: "scale", delta: -0.1 });
    expect(browserCommand({ key: "0", metaKey: true })).toEqual({ type: "scale", delta: 0 });
    expect(browserCommand({ key: "+", metaKey: true, altKey: true })).toBeUndefined();
    expect(browserCommand({ key: "-", metaKey: true, ctrlKey: true })).toBeUndefined();
    expect(changeContentScale(2.5, 0.1)).toBe(2.5);
    expect(changeContentScale(0.8, -0.1)).toBe(0.8);
    expect(changeContentScale(1.4, 0)).toBe(1);
  });
});
