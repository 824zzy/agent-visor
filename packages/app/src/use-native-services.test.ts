import { describe, expect, it } from "vitest";
import { nativeServicesFromServerData } from "./use-native-services.js";

describe("native services messages", () => {
  it("accepts only a typed native services state", () => {
    const state = {
      type: "native_services_state",
      revision: 1,
      settings: {
        appearance: "dark",
        contentScale: 1,
        pillsEnabled: true,
        codexUsageGlanceEnabled: true,
        claudeUsageGlanceEnabled: false,
        notificationSound: "Pop",
        hotkeyTrigger: "shift",
        customHotkeyCombo: null,
        sessionShortcutModifierFamily: "optionCommand",
        editorPreference: "auto",
        observedWindowHours: 42,
        launchAtLogin: false,
      },
      permissions: { accessibility: "needed", notifications: "not_determined" },
      update: { status: "idle", currentVersion: "2.6.2" },
    };
    expect(nativeServicesFromServerData(JSON.stringify(state))).toEqual(state);
    expect(nativeServicesFromServerData(JSON.stringify({ ...state, unknown: true })))
      .toBeUndefined();
  });
});
