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
  subtitle: "Ready to continue",
  source: "Pi",
  project: "agent-visor",
  owner: "Ghostty",
  phase: "ready" as const,
  priority: 1,
  accessibilityLabel: "Review migration, ready",
};

const usage = {
  id: "codex" as const,
  label: "5h 82% | 7d 61%",
  detail: "Codex usage",
  tone: "normal" as const,
  priority: 100,
  accessibilityLabel: "Codex usage",
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
    await helper.requestAccessibility();
    await helper.openAccessibilitySettings();
    await helper.presentPills([pill], [usage], "controlCommand", "custom", "49:8");
    await helper.focus(focus);
    const terminal = { application: "Ghostty" as const, tty: "ttys012", cwd: "/tmp/project" };
    await helper.focusTerminal(terminal);
    await helper.sendTerminal(terminal, "Continue", true);

    expect(helper.requestedAccessibility).toBe(true);
    expect(helper.openedAccessibilitySettings).toBe(true);
    expect(helper.presentedPills).toEqual([pill]);
    expect(helper.presentedUsageGlances).toEqual([usage]);
    expect(helper.shortcutModifierFamily).toBe("controlCommand");
    expect(helper.hotkeyTrigger).toBe("custom");
    expect(helper.customHotkeyCombo).toBe("49:8");
    expect(helper.focusRequests).toEqual([focus]);
    expect(helper.terminalFocusRequests).toEqual([terminal]);
    expect(helper.terminalSendRequests).toEqual([{ target: terminal, text: "Continue", submit: true }]);
  });

  it("copies mutable inputs at the adapter boundary", async () => {
    const helper = new FakeNativeHelper();
    const pills = [pill];

    await helper.presentPills(pills, []);
    pills.length = 0;

    expect(helper.presentedPills).toEqual([pill]);
  });
});
