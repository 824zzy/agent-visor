import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { FakeNativeHelper } from "./native-helper.js";
import { NativeServicesRepository } from "./native-services.js";
import { SettingsRepository } from "./settings.js";

const roots: string[] = [];
afterEach(async () => Promise.all(roots.splice(0).map((root) =>
  rm(root, { recursive: true, force: true }))));

describe("native services", () => {
  it("repairs permissions, persists settings, and emits desktop effects", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-native-services-"));
    roots.push(root);
    const settings = await SettingsRepository.open({ root, readLegacy: async () => ({}) });
    const helper = new FakeNativeHelper({ trusted: false });
    const effects: unknown[] = [];
    const services = new NativeServicesRepository({
      settings,
      helper,
      currentVersion: "2.6.2",
      checkUpdates: async () => ({
        status: "available",
        currentVersion: "2.6.2",
        availableVersion: "2.6.3",
        releaseUrl: "https://github.com/824zzy/agent-visor/releases/tag/v2.6.3",
      }),
      emitDesktop: (effect) => effects.push(effect),
    });
    await services.start();

    expect(services.current().permissions).toEqual({
      accessibility: "needed",
      notifications: "not_determined",
    });
    expect(await services.action({
      type: "update_settings",
      id: "settings-1",
      patch: { appearance: "system", launchAtLogin: true },
    })).toBeUndefined();
    expect(settings.current()).toMatchObject({ appearance: "system", launchAtLogin: true });
    expect(effects).toContainEqual({ action: "set_login_item", enabled: true });

    await services.action({
      type: "native_service_action",
      id: "permission-1",
      action: "request_accessibility",
    });
    expect(helper.requestedAccessibility).toBe(true);

    await services.action({
      type: "native_service_action",
      id: "notifications-1",
      action: "request_notifications",
    });
    expect(effects).toContainEqual({ action: "request_notifications" });

    await services.action({
      type: "native_service_action",
      id: "update-1",
      action: "check_updates",
    });
    await services.action({
      type: "native_service_action",
      id: "update-2",
      action: "open_update",
    });
    expect(effects).toContainEqual({
      action: "open_update",
      url: "https://github.com/824zzy/agent-visor/releases/tag/v2.6.3",
    });
  });

  it("notifies only when a session enters an attention state", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-native-services-"));
    roots.push(root);
    const settings = await SettingsRepository.open({ root, readLegacy: async () => ({}) });
    const helper = new FakeNativeHelper({ trusted: true });
    const effects: unknown[] = [];
    const services = new NativeServicesRepository({
      settings,
      helper,
      currentVersion: "2.6.2",
      checkUpdates: async () => ({ status: "up_to_date", currentVersion: "2.6.2" }),
      emitDesktop: (effect) => effects.push(effect),
    });
    await services.start();
    const session = {
      id: "session-1", title: "Review migration", subtitle: "Agent is working",
      source: "Pi", project: "agent-visor", owner: "Ghostty", cwd: "/repo",
      section: "working" as const, updatedAt: "2026-08-22T10:00:00.000Z",
      canOpenOwner: true, canEnterChat: true,
    };
    services.reconcileSessions({ type: "session_snapshot", revision: 1, sessions: [session] });
    services.reconcileSessions({
      type: "session_snapshot",
      revision: 2,
      sessions: [{ ...session, section: "needs_you", subtitle: "Approval required" }],
    });
    services.reconcileSessions({
      type: "session_snapshot",
      revision: 3,
      sessions: [{ ...session, section: "needs_you", subtitle: "Approval required" }],
    });

    expect(effects).toEqual([{
      action: "notify",
      notification: {
        id: "needs_you-session-1-2",
        sessionId: "session-1",
        title: "Review migration",
        body: "Pi needs you",
        owner: "Ghostty",
        sound: "Pop",
      },
    }]);
  });
});
