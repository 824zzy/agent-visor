import { describe, expect, it } from "vitest";
import { FakeNativeHelper } from "./native-helper.js";

const screen = {
  displayId: 1,
  frame: { x: 0, y: 0, width: 1512, height: 982 },
  visibleFrame: { x: 0, y: 37, width: 1512, height: 945 },
  scale: 2,
  isMain: true,
};

const pill = {
  id: "session-1",
  title: "Review migration",
  phase: "ready" as const,
  priority: 1,
  accessibilityLabel: "Review migration, ready",
};

const focus = {
  pid: 42,
  bundleIdentifier: "com.mitchellh.ghostty",
  windowId: 7,
};

describe("FakeNativeHelper", () => {
  it("supports daemon tests without a native process", async () => {
    const helper = new FakeNativeHelper({ screens: [screen], trusted: true });

    expect(await helper.screenTopology()).toEqual([screen]);
    expect(await helper.accessibilityStatus()).toBe(true);

    await helper.presentPills([pill]);
    await helper.focus(focus);

    expect(helper.presentedPills).toEqual([pill]);
    expect(helper.focusRequests).toEqual([focus]);
  });

  it("copies mutable inputs at the adapter boundary", async () => {
    const helper = new FakeNativeHelper();
    const pills = [pill];

    await helper.presentPills(pills);
    pills.length = 0;

    expect(helper.presentedPills).toEqual([pill]);
  });
});
