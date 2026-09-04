import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { ChatPendingAction, NativeHelperPiRestorationUpdate } from "@agent-visor/protocol";
import { afterEach, describe, expect, it } from "vitest";
import { AgentConnectionsRepository } from "./agent-connections.js";
import { FakeNativeHelper } from "./native-helper.js";
import { NativeServicesRepository, type DesktopNativeEffect } from "./native-services.js";
import { SettingsRepository } from "./settings.js";

const roots: string[] = [];
afterEach(async () => Promise.all(roots.splice(0).map((root) =>
  rm(root, { recursive: true, force: true }))));

const session = {
  id: "session-1", title: "Review migration", subtitle: "Agent is working",
  source: "Claude Code", project: "agent-visor", owner: "Ghostty", cwd: "/repo",
  section: "working" as const, updatedAt: "2026-08-22T10:00:00.000Z",
  canOpenOwner: true, canEnterChat: true,
};

async function notificationFixture(
  pendingAction?: () => ChatPendingAction | undefined,
  piRestorationUpdate?: () => NativeHelperPiRestorationUpdate,
): Promise<{
  services: NativeServicesRepository;
  effects: DesktopNativeEffect[];
  helper: FakeNativeHelper;
}> {
  const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-native-services-"));
  roots.push(root);
  const settings = await SettingsRepository.open({ root, readLegacy: async () => ({}) });
  const effects: DesktopNativeEffect[] = [];
  const helper = new FakeNativeHelper({ trusted: true });
  const services = new NativeServicesRepository({
    settings,
    helper,
    connections: new AgentConnectionsRepository({
      home: path.join(root, "home"), resources: path.join(root, "resources"),
    }),
    currentVersion: "2.7.0",
    checkUpdates: async () => ({ status: "up_to_date", currentVersion: "2.7.0" }),
    pendingAction,
    piRestorationUpdate,
    emitDesktop: (effect) => effects.push(effect),
  });
  await services.start();
  return { services, effects, helper };
}

describe("native services", () => {
  it("requests notification permission when its status is undecided", async () => {
    const { helper } = await notificationFixture();

    expect(helper.requestedNotifications).toBe(true);
  });

  it("reconciles exact Pi restoration candidates with the signed helper", async () => {
    const candidate = {
      sessionId: "pi-1",
      sessionFile: "/Users/me/.pi/agent/sessions/pi-1.jsonl",
      cwd: "/Users/me/Codes/agent-visor",
      sessionName: "Restore Pi sessions",
      pid: 43,
      tty: "ttys001",
    };
    const { services, helper } = await notificationFixture(undefined, () => ({
      candidates: [candidate],
      liveSessionIds: ["pi-1"],
      removeCandidateSessionIds: [],
      cleanTermination: false,
    }));

    services.reconcileSessions({ type: "session_snapshot", revision: 1, sessions: [] });

    expect(helper.piRestorationCandidates).toEqual([candidate]);
    expect(helper.piRestorationLiveSessionIds).toEqual(["pi-1"]);
    expect(helper.piRestorationRemovedSessionIds).toEqual([]);
    expect(helper.invalidatedPiRestoration).toBe(false);
  });

  it("publishes and changes agent connections", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-native-services-"));
    roots.push(root);
    const home = path.join(root, "home");
    const resources = path.join(root, "resources");
    await mkdir(path.join(home, ".claude"), { recursive: true });
    await mkdir(resources, { recursive: true });
    await writeFile(path.join(resources, "agent-visor-state.py"), "# hook\n");
    const settings = await SettingsRepository.open({ root, readLegacy: async () => ({}) });
    const services = new NativeServicesRepository({
      settings,
      helper: new FakeNativeHelper({ trusted: true }),
      connections: new AgentConnectionsRepository({ home, resources }),
      currentVersion: "2.7.0",
      checkUpdates: async () => ({ status: "up_to_date", currentVersion: "2.7.0" }),
      emitDesktop: () => undefined,
    });
    await services.start();

    expect(services.current().agents.find(({ id }) => id === "claude"))
      .toMatchObject({ installed: false, control: "toggle" });
    expect(await services.action({
      type: "set_agent_connection", id: "agent-1", agent: "claude", enabled: true,
    })).toBeUndefined();
    expect(services.current().agents.find(({ id }) => id === "claude"))
      .toMatchObject({ installed: true, control: "toggle" });
  });

  it("publishes available pill screens from the signed helper", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-native-services-"));
    roots.push(root);
    const settings = await SettingsRepository.open({ root, readLegacy: async () => ({}) });
    const helper = new FakeNativeHelper({ trusted: true, screens: [{
      displayId: 5,
      name: "XZ322QU V3",
      isBuiltIn: false,
      frame: { x: 0, y: 0, width: 2_052, height: 1_080 },
      visibleFrame: { x: 0, y: 0, width: 2_052, height: 1_055 },
      scale: 2,
      isMain: true,
    }] });
    const services = new NativeServicesRepository({
      settings,
      helper,
      connections: new AgentConnectionsRepository({
        home: path.join(root, "home"), resources: path.join(root, "resources"),
      }),
      currentVersion: "2.7.0",
      checkUpdates: async () => ({ status: "up_to_date", currentVersion: "2.7.0" }),
      emitDesktop: () => undefined,
    });

    await services.start();

    expect(services.current().pillScreens).toEqual([{
      displayId: 5,
      name: "XZ322QU V3",
      isBuiltIn: false,
      isMain: true,
    }]);
  });

  it("repairs permissions, persists settings, and emits desktop effects", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-native-services-"));
    roots.push(root);
    const settings = await SettingsRepository.open({ root, readLegacy: async () => ({}) });
    const helper = new FakeNativeHelper({ trusted: false, notifications: "authorized" });
    const effects: unknown[] = [];
    const services = new NativeServicesRepository({
      settings,
      helper,
      connections: new AgentConnectionsRepository({
        home: path.join(root, "home"), resources: path.join(root, "resources"),
      }),
      currentVersion: "2.7.0",
      checkUpdates: async () => ({
        status: "available",
        currentVersion: "2.7.0",
        availableVersion: "2.7.1",
        releaseUrl: "https://github.com/824zzy/agent-visor/releases/tag/v2.7.1",
      }),
      emitDesktop: (effect) => effects.push(effect),
    });
    await services.start();

    expect(services.current().permissions).toEqual({
      accessibility: "needed",
      notifications: "authorized",
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
    expect(helper.requestedNotifications).toBe(true);
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
      url: "https://github.com/824zzy/agent-visor/releases/tag/v2.7.1",
    });
  });

  it("includes the exact pending approval in a Needs you notice", async () => {
    const { services, helper } = await notificationFixture(() => ({
      type: "approval", toolUseId: "tool-7", toolName: "Bash",
      input: { command: "npm test" }, canPersist: false,
    }));

    services.reconcileSessions({ type: "session_snapshot", revision: 1, sessions: [session] });
    services.reconcileSessions({
      type: "session_snapshot",
      revision: 2,
      sessions: [{ ...session, section: "needs_you", subtitle: "Approval required" }],
    });

    expect(helper.presentedNotifications).toEqual([{
      id: expect.stringMatching(/^attention-[0-9a-f]{64}$/),
      sessionId: "session-1",
      title: "Bash needs approval",
      subtitle: "Review migration",
      body: "{\"command\":\"npm test\"}",
      toolUseId: "tool-7",
      sound: "Pop",
    }]);
    expect(helper.presentedNewNotifications).toBe(true);
  });

  it("replaces stale approvals, removes resolved notices, and updates the Dock badge", async () => {
    let toolUseId = "tool-1";
    const { services, effects, helper } = await notificationFixture(() => ({
      type: "approval", toolUseId, toolName: "Bash", input: {}, canPersist: false,
    }));

    services.reconcileSessions({ type: "session_snapshot", revision: 1, sessions: [session] });
    services.reconcileSessions({
      type: "session_snapshot", revision: 2,
      sessions: [{ ...session, section: "needs_you", subtitle: "Approval required" }],
    });
    const firstId = helper.presentedNotifications[0]?.id;
    toolUseId = "tool-2";
    services.reconcileSessions({
      type: "session_snapshot", revision: 3,
      sessions: [{ ...session, section: "needs_you", subtitle: "Another approval" }],
    });
    services.reconcileSessions({ type: "session_snapshot", revision: 4, sessions: [session] });

    expect(helper.notificationPresentations.map(({ notifications, presentNew }) => ({
      ids: notifications.map(({ id }) => id), presentNew,
    }))).toEqual([
      { ids: [], presentNew: false },
      { ids: [firstId], presentNew: true },
      { ids: [expect.not.stringMatching(firstId ?? "")], presentNew: true },
      { ids: [], presentNew: true },
    ]);
    expect(effects).toContainEqual({ action: "set_badge", count: 1 });
    expect(effects).toContainEqual({ action: "set_badge", count: 0 });
  });

  it("does not add approval actions to a question", async () => {
    const { services, helper } = await notificationFixture(() => ({
      type: "question", toolUseId: "question-1",
      questions: [{ id: "q1", question: "Continue?", choices: ["Yes"], multiple: false }],
    }));

    services.reconcileSessions({ type: "session_snapshot", revision: 1, sessions: [session] });
    services.reconcileSessions({
      type: "session_snapshot", revision: 2,
      sessions: [{ ...session, section: "needs_you", subtitle: "Question" }],
    });

    expect(helper.presentedNotifications[0]?.toolUseId).toBeUndefined();
  });

  it("restores the Dock badge without replaying an initial Ready notice", async () => {
    const { services, effects, helper } = await notificationFixture();

    services.reconcileSessions({
      type: "session_snapshot", revision: 1,
      sessions: [{ ...session, source: "Pi", section: "ready", subtitle: "Ready" }],
    });

    expect(helper.presentedNotifications).toHaveLength(1);
    expect(helper.presentedNewNotifications).toBe(false);
    expect(effects).toEqual([{ action: "set_badge", count: 1 }]);
  });

  it("does not notify or badge for a Ready Codex automation record", async () => {
    const { services, effects, helper } = await notificationFixture();

    services.reconcileSessions({
      type: "session_snapshot", revision: 1,
      sessions: [{
        ...session,
        id: "codex-exec",
        title: "Current message from a private prompt",
        source: "Codex",
        owner: "Codex",
        sessionClass: "automation",
        section: "ready",
        subtitle: "Ready to continue",
      }],
    });

    expect(helper.presentedNotifications).toEqual([]);
    expect(effects).toEqual([]);
  });

  it("notifies only when a session enters an attention state", async () => {
    const { services, helper } = await notificationFixture();
    const piSession = { ...session, source: "Pi" };
    services.reconcileSessions({ type: "session_snapshot", revision: 1, sessions: [piSession] });
    services.reconcileSessions({
      type: "session_snapshot",
      revision: 2,
      sessions: [{ ...piSession, section: "needs_you", subtitle: "Approval required" }],
    });
    services.reconcileSessions({
      type: "session_snapshot",
      revision: 3,
      sessions: [{ ...piSession, section: "needs_you", subtitle: "Approval required" }],
    });

    const attention = helper.notificationPresentations.flatMap(({ notifications }) =>
      notifications).filter(({ body }) => body === "Pi needs you");
    expect(new Set(attention.map(({ id }) => id)).size).toBe(1);
  });
});
