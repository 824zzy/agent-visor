import { describe, expect, it, vi } from "vitest";
import { FakeNativeHelper, retryNativeHelperStart } from "./native-helper.js";

const screen = {
  displayId: 1,
  name: "Built-in Retina Display",
  isBuiltIn: true,
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

const navigatorPill = {
  ...pill,
  id: "history-chat-only",
  title: "Chat history",
  owner: undefined,
  phase: "history" as const,
  priority: 2,
  accessibilityLabel: "Chat history, recent session",
};

const usage = {
  id: "codex" as const,
  label: "5h 82% | 7d 61%",
  detail: "Codex usage",
  tone: "normal" as const,
  priority: 100,
  accessibilityLabel: "Codex usage",
};

const notification = {
  id: "attention-1",
  sessionId: "session-1",
  title: "Bash needs approval",
  subtitle: "Review migration",
  body: "{\"command\":\"npm test\"}",
  toolUseId: "tool-7",
  sound: "Pop" as const,
};

const focus = {
  pid: 42,
  bundleIdentifier: "com.mitchellh.ghostty",
  windowId: 7,
};

const piRestorationCandidate = {
  sessionId: "pi-1",
  sessionFile: "/Users/me/.pi/agent/sessions/pi-1.jsonl",
  cwd: "/Users/me/Codes/agent-visor",
  sessionName: "Restore Pi sessions",
  pid: 43,
  tty: "ttys001",
};

describe("retryNativeHelperStart", () => {
  it("retries one transient startup failure", async () => {
    vi.useFakeTimers();
    let attempts = 0;
    const started = retryNativeHelperStart(async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("Launch Services was not ready");
      return "helper";
    });

    await vi.runAllTimersAsync();

    await expect(started).resolves.toBe("helper");
    expect(attempts).toBe(2);
    vi.useRealTimers();
  });
});

describe("FakeNativeHelper", () => {
  it("supports daemon tests without a native process", async () => {
    const helper = new FakeNativeHelper({
      screens: [screen], trusted: true, notifications: "authorized",
    });

    expect(await helper.screenTopology()).toEqual([screen]);
    expect(await helper.accessibilityStatus()).toBe(true);
    expect(await helper.notificationStatus()).toBe("authorized");
    await helper.requestNotifications();
    await helper.reconcileNotifications([notification], true);
    await helper.reconcilePiRestoration({
      candidates: [piRestorationCandidate],
      liveSessionIds: ["pi-1"],
      removeCandidateSessionIds: [],
      cleanTermination: false,
    });
    await helper.requestAccessibility();
    await helper.openAccessibilitySettings();
    await helper.presentPills(
      [pill], [usage], "controlCommand", "custom", "49:8", [pill, navigatorPill],
      { mode: "specific", displayId: 5, name: "XZ322QU V3" }, "alwaysHide",
    );
    await helper.focus(focus);
    const terminal = { application: "Ghostty" as const, tty: "ttys012", cwd: "/tmp/project" };
    await helper.focusTerminal(terminal);
    await helper.sendTerminal(terminal, "Continue", true);

    expect(helper.requestedNotifications).toBe(true);
    expect(helper.presentedNotifications).toEqual([notification]);
    expect(helper.presentedNewNotifications).toBe(true);
    expect(helper.piRestorationCandidates).toEqual([piRestorationCandidate]);
    expect(helper.piRestorationLiveSessionIds).toEqual(["pi-1"]);
    expect(helper.piRestorationRemovedSessionIds).toEqual([]);
    expect(helper.invalidatedPiRestoration).toBe(false);
    expect(helper.requestedAccessibility).toBe(true);
    expect(helper.openedAccessibilitySettings).toBe(true);
    expect(helper.presentedPills).toEqual([pill]);
    expect(helper.presentedNavigatorPills).toEqual([pill, navigatorPill]);
    expect(helper.presentedUsageGlances).toEqual([usage]);
    expect(helper.shortcutModifierFamily).toBe("controlCommand");
    expect(helper.hotkeyTrigger).toBe("custom");
    expect(helper.customHotkeyCombo).toBe("49:8");
    expect(helper.pillScreen).toEqual({
      mode: "specific", displayId: 5, name: "XZ322QU V3",
    });
    expect(helper.fullScreenPolicy).toBe("alwaysHide");
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
