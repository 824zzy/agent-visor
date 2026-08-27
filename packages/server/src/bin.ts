import { randomBytes } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { NativeHelperUsageGlance } from "@agent-visor/protocol";
import { runBackground } from "./background-task.js";
import { stopCodexTurns } from "./codex-turn.js";
import { startHookSocket, type RunningHookSocket } from "./hook-socket.js";
import { menuPresentation, nativeActionFor } from "./menu.js";
import { runProcess } from "./machine.js";
import {
  NativeHelperProcess,
  retryNativeHelperStart,
  UnavailableNativeHelper,
} from "./native-helper.js";
import { AgentConnectionsRepository } from "./agent-connections.js";
import { NativeServicesRepository } from "./native-services.js";
import { handleNotificationAction } from "./notification-actions.js";
import { liveProviders } from "./providers/index.js";
import { startServer } from "./server.js";
import { SessionRepository } from "./sessions.js";
import { NativeSessionControls } from "./session-controls.js";
import { readLegacyDefaults, SettingsRepository } from "./settings.js";
import { readCodexUsage } from "./usage.js";
import { checkForUpdates } from "./updates.js";

const requestedPort = Number.parseInt(process.env.AGENT_VISOR_PORT ?? "0", 10);
const token = process.env.AGENT_VISOR_TOKEN ?? randomBytes(32).toString("base64url");
const currentVersion = process.env.AGENT_VISOR_VERSION ?? "0.0.0";
const dataRoot = process.env.AGENT_VISOR_DATA_DIR
  ?? path.join(os.homedir(), "Library/Application Support/Agent Visor Next");
const settingsDomain = process.env.AGENT_VISOR_SETTINGS_DOMAIN ?? "com.824zzy.AgentVisor.Dev";
const integrationResources = process.env.AGENT_VISOR_INTEGRATIONS_DIR ?? path.resolve(
  path.dirname(fileURLToPath(import.meta.url)), "../../../AgentVisor/Resources",
);
const settings = await SettingsRepository.open({
  root: dataRoot,
  readLegacy: () => readLegacyDefaults(settingsDomain, dataRoot),
});
if (process.env.AGENT_VISOR_LAUNCH_AT_LOGIN) {
  await settings.update({ launchAtLogin: process.env.AGENT_VISOR_LAUNCH_AT_LOGIN === "true" });
}
const repository = new SessionRepository(
  liveProviders(
    os.homedir(),
    () => settings.current().observedWindowHours * 60 * 60 * 1_000,
  ),
  {
    piRuntimeStatePath: path.join(dataRoot, "pi-runtime-links.json"),
    bootSessionUUID: await macBootSessionUUID(),
  },
);

let hookSocket: RunningHookSocket | undefined;
let nativeHelper: NativeHelperProcess | undefined;
let nativeServices: NativeServicesRepository | undefined;
let unsubscribeMenu: (() => void) | undefined;
let unsubscribeNotifications: (() => void) | undefined;
let unsubscribePiRestoration: (() => void) | undefined;
let unsubscribeSettings: (() => void) | undefined;
let usageTimer: NodeJS.Timeout | undefined;
let permissionTimer: NodeJS.Timeout | undefined;
let updateTimer: NodeJS.Timeout | undefined;
let usageGlances: NativeHelperUsageGlance[] = [];
let usageRefreshing = false;
let presentNativeMenu = () => {};
let refreshUsage = async () => {};
let refreshing = false;

const hookPath = process.env.AGENT_VISOR_HOOK_SOCKET ?? "/tmp/agent-visor.sock";
try {
  hookSocket = await startHookSocket({ socketPath: hookPath, repository });
  console.log(`Agent Visor hook socket listening at ${hookPath}`);
} catch (error) {
  console.warn(`Agent Visor hook socket unavailable: ${String(error)}`);
}

const nativeHelperExecutable = process.env.AGENT_VISOR_NATIVE_HELPER;
if (nativeHelperExecutable) {
  try {
    nativeHelper = await retryNativeHelperStart(() => NativeHelperProcess.start(nativeHelperExecutable, (event) => {
      if (event.event === "notification_permission") {
        nativeServices?.setNotificationPermission(event.status);
        return;
      }
      if (event.event === "notification_action") {
        if (event.action === "activate") {
          repository.acknowledgeReady(event.sessionId);
          const action = nativeActionFor(event, repository.current());
          if (action) process.send?.(action);
          return;
        }
        runBackground("notification action", () => handleNotificationAction({
          type: "notification_action",
          action: event.action === "approve" ? "allow" : "deny",
          sessionId: event.sessionId,
          toolUseId: event.toolUseId,
        }, repository).then((error) => {
          if (error) console.warn(`Agent Visor notification action failed: ${error}`);
        }));
        return;
      }
      if (event.event === "refresh_usage") {
        runBackground("usage refresh", refreshUsage);
        return;
      }
      if (event.event === "activate_pill") {
        repository.acknowledgeReady(event.sessionId);
        const action = nativeActionFor(event, repository.current());
        if (action?.action === "open_chat") {
          process.send?.(action);
          return;
        }
        runBackground("session focus", () => repository.focusSession(event.sessionId).then((error) => {
          if (error && action) process.send?.(action);
        }));
        return;
      }
      const action = nativeActionFor(event, repository.current());
      if (action) process.send?.(action);
    }));
    presentNativeMenu = () => {
      const preferences = settings.current();
      const presentation = preferences.pillsEnabled
        ? menuPresentation(
          repository.current(),
          preferences.codexUsageGlanceEnabled ? usageGlances : [],
        )
        : { pills: [], navigatorPills: [], usageGlances: [] };
      void nativeHelper?.presentPills(
        presentation.pills,
        presentation.usageGlances,
        preferences.sessionShortcutModifierFamily,
        preferences.hotkeyTrigger,
        preferences.customHotkeyCombo,
        presentation.navigatorPills,
        preferences.pillScreen,
        preferences.fullScreenPolicy,
      )
        .catch((error: unknown) => console.warn(`Agent Visor menu update failed: ${String(error)}`));
    };
    unsubscribeMenu = repository.subscribe(presentNativeMenu);
    unsubscribeSettings = settings.subscribe(presentNativeMenu);
    presentNativeMenu();

    refreshUsage = async () => {
      if (!settings.current().codexUsageGlanceEnabled || usageRefreshing) return;
      usageRefreshing = true;
      const codex = await readCodexUsage().finally(() => { usageRefreshing = false; });
      if (!codex) {
        if (usageGlances.some((glance) => glance.stale !== true)) {
          usageGlances = usageGlances.map((glance) => ({ ...glance, stale: true }));
          presentNativeMenu();
        }
        return;
      }
      usageGlances = [codex];
      presentNativeMenu();
    };
    runBackground("usage refresh", refreshUsage);
    usageTimer = setInterval(() => runBackground("usage refresh", refreshUsage), 300_000);
    usageTimer.unref();
  } catch (error) {
    console.warn(`Agent Visor native helper unavailable: ${String(error)}`);
  }
}

const helperAdapter = nativeHelper ?? new UnavailableNativeHelper();
const sessionControls = new NativeSessionControls(
  helperAdapter,
  path.join(dataRoot, "chat-images"),
  undefined,
  async (url) => { process.send?.({ type: "native_action", action: "open_session_url", url }); },
  (sessionId, pending, respond) => repository.registerExternalAction(
    sessionId, pending, respond,
  ),
);
repository.setControls(sessionControls);
nativeServices = new NativeServicesRepository({
  settings,
  helper: helperAdapter,
  connections: new AgentConnectionsRepository({
    home: os.homedir(), resources: integrationResources,
  }),
  currentVersion,
  checkUpdates: () => checkForUpdates(currentVersion),
  pendingAction: (sessionId) => repository.pendingAction(sessionId),
  piRestorationUpdate: () => repository.piRestorationUpdate(),
  emitDesktop: (effect) => process.send?.({ type: "native_effect", ...effect }),
});
await nativeServices.start();
permissionTimer = setInterval(() => runBackground(
  "native services refresh", () => nativeServices?.refresh() ?? Promise.resolve(),
), 15_000);
permissionTimer.unref();
runBackground("update check", () => nativeServices?.checkForUpdates() ?? Promise.resolve());
updateTimer = setInterval(() => runBackground(
  "update check", () => nativeServices?.checkForUpdates() ?? Promise.resolve(),
), 6 * 60 * 60_000);
updateTimer.unref();
unsubscribeNotifications = repository.subscribe((snapshot) => {
  nativeServices?.reconcileSessions(snapshot);
});
unsubscribePiRestoration = repository.subscribePiRestoration(() => {
  nativeServices?.reconcilePiRestoration();
});
nativeServices.reconcileSessions(repository.current());

const running = await startServer({
  port: requestedPort,
  source: repository,
  token,
  nativeServices,
});
process.send?.({ type: "ready", url: running.url });
console.log(`Agent Visor daemon listening at ${new URL(running.url).origin}`);

runBackground("session refresh", refresh);
const refreshTimer = setInterval(() => runBackground("session refresh", refresh), 3_000);
refreshTimer.unref();

async function refresh(): Promise<void> {
  if (refreshing) return;
  refreshing = true;
  try {
    await repository.refresh();
  } finally {
    refreshing = false;
  }
}

async function stop(): Promise<void> {
  clearInterval(refreshTimer);
  if (usageTimer) clearInterval(usageTimer);
  if (permissionTimer) clearInterval(permissionTimer);
  if (updateTimer) clearInterval(updateTimer);
  unsubscribeMenu?.();
  unsubscribeNotifications?.();
  unsubscribePiRestoration?.();
  unsubscribeSettings?.();
  stopCodexTurns();
  await sessionControls.close();
  await hookSocket?.close();
  await nativeHelper?.close().catch((error: unknown) => {
    console.warn(`Agent Visor Pi restoration invalidation failed: ${String(error)}`);
  });
  await running.close();
  process.exit(0);
}

async function macBootSessionUUID(): Promise<string | undefined> {
  const result = await runProcess(
    "/usr/sbin/sysctl",
    ["-n", "kern.bootsessionuuid"],
    { deadlineMs: 500, maxOutputBytes: 1_024 },
  );
  if (result.status !== "success") return undefined;
  const value = result.stdout.trim();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value.toUpperCase()
    : undefined;
}

process.once("SIGINT", () => runBackground("shutdown", stop));
process.once("SIGTERM", () => runBackground("shutdown", stop));
