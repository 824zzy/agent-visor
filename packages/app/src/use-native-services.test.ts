import { describe, expect, it } from "vitest";
import {
  agentConnectionRequest,
  nativeServicesFromServerData,
} from "./use-native-services.js";

describe("native services messages", () => {
  it("builds a typed agent connection request", () => {
    expect(agentConnectionRequest("claude", true, "agent-1")).toEqual({
      type: "set_agent_connection", id: "agent-1", agent: "claude", enabled: true,
    });
  });

  it("accepts only a typed native services state", () => {
    const state = {
      type: "native_services_state",
      revision: 1,
      settings: {
        appearance: "dark",
        contentScale: 1,
        pillsEnabled: true,
        pillScreen: { mode: "automatic" },
        fullScreenPolicy: "onDemand",
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
      agents: [{
        id: "claude", name: "Claude Code", available: true,
        installed: false, control: "toggle",
      }],
      pillScreens: [{
        displayId: 1, name: "Built-in Retina Display", isBuiltIn: true, isMain: true,
      }],
      update: { status: "idle", currentVersion: "2.6.2" },
    };
    expect(nativeServicesFromServerData(JSON.stringify(state))).toEqual(state);
    expect(nativeServicesFromServerData(JSON.stringify({ ...state, unknown: true })))
      .toBeUndefined();
  });
});
