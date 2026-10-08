import { randomBytes } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runDaemon } from "./daemon-lifetime.js";
import { runBackground } from "./background-task.js";
import { stopCodexTurns } from "./codex-turn.js";
import { startHookSocket, type RunningHookSocket } from "./hook-socket.js";
import { startAlfredSocket } from "./alfred.js";
import { activateMenuPill, menuPresentation, nativeActionFor } from "./menu.js";
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
import { codexHomeStatuses } from "./providers/codex-instances.js";
import { LiveProviderEnvironment } from "./providers/environment.js";
import { startServer } from "./server.js";
import { SessionRepository } from "./sessions.js";
import { NativeSessionControls } from "./session-controls.js";
import { readLegacyDefaults, SettingsRepository } from "./settings.js";
import { chatUsageGlanceFromNative, readCodexUsage } from "./usage.js";
import { readCopilotUsage } from "./copilot-usage.js";
import { UsageGlances } from "./usage-glances.js";
import { checkForUpdates } from "./updates.js";
import { agentVisorVersion } from "./runtime-version.js";
import { NavigationDiagnostics } from "./navigation-diagnostics.js";
import { ClaudePresenceDiagnostics } from "./claude-presence-diagnostics.js";

await runDaemon(async (lifetime) => {
  let hookSocket: RunningHookSocket | undefined;
  let alfredSocket: Awaited<ReturnType<typeof startAlfredSocket>> | undefined;
  let nativeHelper: NativeHelperProcess | undefined;
  let nativeServices: NativeServicesRepository | undefined;
  let unsubscribeMenu: (() => void) | undefined;
  let unsubscribeNotifications: (() => void) | undefined;
  let unsubscribePiRestoration: (() => void) | undefined;
  let unsubscribeSettings: (() => void) | undefined;
  let usageTimer: NodeJS.Timeout | undefined;
  let menuTimer: NodeJS.Timeout | undefined;
  let permissionTimer: NodeJS.Timeout | undefined;
  let updateTimer: NodeJS.Timeout | undefined;
  const usageGlances = new UsageGlances({ codex: readCodexUsage, copilot: readCopilotUsage });
  let presentNativeMenu = () => {};
  let refreshUsage = async () => {};
  let refreshing = false;

  let sessionControls: NativeSessionControls | undefined;
  let running: Awaited<ReturnType<typeof startServer>> | undefined;
  let refreshTimer: NodeJS.Timeout | undefined;
  let flushNavigationDiagnostics = async () => {};
  lifetime.onStop(async () => {
    for (const timer of [refreshTimer, usageTimer, menuTimer, permissionTimer, updateTimer]) {
      clearInterval(timer);
    }
    unsubscribeMenu?.();
    unsubscribeNotifications?.();
    unsubscribePiRestoration?.();
    unsubscribeSettings?.();
    stopCodexTurns();
    // A failed or slow close must not prevent closing the helper connection.
    const results = await Promise.allSettled([
      alfredSocket?.close(), sessionControls?.close(), hookSocket?.close(),
      nativeHelper?.close(), running?.close(),
    ]);
    await flushNavigationDiagnostics();
    const failure = results.find((result) => result.status === "rejected");
    if (failure?.status === "rejected") throw failure.reason;
  });

  const requestedPort = Number.parseInt(process.env.AGENT_VISOR_PORT ?? "0", 10);
  const token = process.env.AGENT_VISOR_TOKEN ?? randomBytes(32).toString("base64url");
  const currentVersion = agentVisorVersion();
  const dataRoot = process.env.AGENT_VISOR_DATA_DIR
    ?? path.join(os.homedir(), "Library/Application Support/Agent Visor");
  const navigationDiagnostics = new NavigationDiagnostics(dataRoot);
  const claudePresenceDiagnostics = new ClaudePresenceDiagnostics(dataRoot);
  flushNavigationDiagnostics = async () => {
    await navigationDiagnostics.flush();
    await claudePresenceDiagnostics.flush();
  };
  const settingsDomain = process.env.AGENT_VISOR_SETTINGS_DOMAIN ?? "com.824zzy.AgentVisor.Dev";
  const integrationResources = process.env.AGENT_VISOR_INTEGRATIONS_DIR ?? path.resolve(
    path.dirname(fileURLToPath(import.meta.url)), "../../../AgentVisor/Resources",
  );
  const settings = await SettingsRepository.open({
    root: dataRoot,
    readLegacy: () => readLegacyDefaults(settingsDomain, dataRoot),
  });
  if (lifetime.stopping) return;
  const statusEnvironment = new LiveProviderEnvironment(os.homedir());
  if (process.env.AGENT_VISOR_LAUNCH_AT_LOGIN) {
    await settings.update({ launchAtLogin: process.env.AGENT_VISOR_LAUNCH_AT_LOGIN === "true" });
  }
  const repository = new SessionRepository(
    liveProviders(
      os.homedir(),
      () => settings.current().observedWindowHours * 60 * 60 * 1_000,
      () => settings.current().codexHomes,
      (home) => settings.addDiscoveredCodexHome(home),
      () => settings.current().ignoredCodexHomes,
      async () => {
        if (!nativeHelper?.ghosttyTerminalViews) throw new Error("Native terminal view reader is unavailable.");
        return nativeHelper.ghosttyTerminalViews();
      },
      report => claudePresenceDiagnostics.record(report),
    ),
    {
      piRuntimeStatePath: path.join(dataRoot, "pi-runtime-links.json"),
      completionAttentionPath: path.join(dataRoot, "completion-attention.json"),
      bootSessionUUID: await macBootSessionUUID(),
      chatUsageGlance: async (session) => {
        // Claude usage remains absent until a provider-authoritative source is
        // available. Do not show Codex quota data on another provider's chat.
        if (session.provider !== "codex" || session.id.startsWith("codex:")
          || !settings.current().codexUsageGlanceEnabled) {
          return undefined;
        }
        return chatUsageGlanceFromNative(await readCodexUsage());
      },
    },
  );

  if (lifetime.stopping) return;
  const hookPath = process.env.AGENT_VISOR_HOOK_SOCKET ?? "/tmp/agent-visor.sock";
  try {
    hookSocket = await startHookSocket({ socketPath: hookPath, repository });
    console.log(`Agent Visor hook socket listening at ${hookPath}`);
  } catch (error) {
    console.warn(`Agent Visor hook socket unavailable: ${String(error)}`);
  }

  if (lifetime.stopping) return;
  const nativeHelperExecutable = process.env.AGENT_VISOR_NATIVE_HELPER;
  if (nativeHelperExecutable) {
    try {
      nativeHelper = await retryNativeHelperStart(() => NativeHelperProcess.start(nativeHelperExecutable, (event) => {
        if (lifetime.stopping) return;
        if (event.event === "notification_permission") {
          nativeServices?.setNotificationPermission(event.status);
          return;
        }
        if (event.event === "notification_action") {
          if (event.action === "activate") {
            repository.acknowledgeReady(event.sessionId);
            const action = nativeActionFor(event, repository.current());
            if (action) sendToDesktop(action);
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
          runBackground("session focus", () => navigationDiagnostics.run(
            event.sessionId, event.intent ?? "standard", async () => {
              if (event.intent !== "dismiss") repository.acknowledgeReady(event.sessionId);
              await activateMenuPill(event, repository, (message) => sendToDesktop(message));
            },
          ));
          return;
        }
        const action = nativeActionFor(event, repository.current());
        if (action) sendToDesktop(action);
      }));
      presentNativeMenu = () => {
        const preferences = settings.current();
        const presentation = preferences.pillsEnabled
          ? menuPresentation(
            repository.current(),
            usageGlances.current(preferences),
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
      // Age eligibility can change even when the session snapshot is unchanged.
      menuTimer = setInterval(presentNativeMenu, 60_000);
      menuTimer.unref();
      unsubscribeMenu = repository.subscribe(presentNativeMenu);
      let previousPreferences = settings.current();
      unsubscribeSettings = settings.subscribe((preferences) => {
        presentNativeMenu();
        if ((preferences.codexUsageGlanceEnabled && !previousPreferences.codexUsageGlanceEnabled)
          || (preferences.copilotUsageGlanceEnabled && !previousPreferences.copilotUsageGlanceEnabled)) {
          runBackground("usage refresh", refreshUsage);
        }
        previousPreferences = preferences;
      });
      presentNativeMenu();

      refreshUsage = async () => {
        if (lifetime.stopping) return;
        await usageGlances.refresh(settings.current(), () => {
          if (!lifetime.stopping) presentNativeMenu();
        });
      };
      runBackground("usage refresh", refreshUsage);
      usageTimer = setInterval(() => runBackground("usage refresh", refreshUsage), 300_000);
      usageTimer.unref();
    } catch (error) {
      console.warn(`Agent Visor native helper unavailable: ${String(error)}`);
    }
  }

  if (lifetime.stopping) return;
  const helperAdapter = nativeHelper ?? new UnavailableNativeHelper();
  sessionControls = new NativeSessionControls(
    helperAdapter,
    path.join(dataRoot, "chat-images"),
    undefined,
    async (url) => { sendToDesktop({ type: "native_action", action: "open_session_url", url }); },
    (sessionId, pending, respond, generation) => repository.registerExternalAction(
      sessionId, pending, respond, generation,
    ),
  );
  repository.setControls(sessionControls);
  try {
    alfredSocket = await startAlfredSocket({
      socketPath: path.join(dataRoot, "alfred", "s.sock"),
      source: repository,
    });
  } catch (error) {
    console.warn(`Agent Visor Alfred session search unavailable: ${String(error)}`);
  }
  if (lifetime.stopping) return;
  nativeServices = new NativeServicesRepository({
    settings,
    helper: helperAdapter,
    codexHomeStatuses: () => codexHomeStatuses(statusEnvironment, settings.current().codexHomes),
    connections: new AgentConnectionsRepository({
      home: os.homedir(), resources: integrationResources,
    }),
    currentVersion,
    checkUpdates: () => checkForUpdates(currentVersion),
    pendingAction: (sessionId) => repository.pendingAction(sessionId),
    piRestorationUpdate: () => repository.piRestorationUpdate(),
    emitDesktop: (effect) => sendToDesktop({ type: "native_effect", ...effect }),
  });
  await nativeServices.start();
  if (lifetime.stopping) return;
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

  running = await startServer({
    port: requestedPort,
    source: repository,
    token,
    nativeServices,
    navigationDiagnostics,
  });
  if (lifetime.stopping) return;
  sendToDesktop({ type: "ready", url: running.url });
  console.log(`Agent Visor daemon listening at ${new URL(running.url).origin}`);

  runBackground("session refresh", refresh);
  refreshTimer = setInterval(() => runBackground("session refresh", refresh), 3_000);
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

});

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

function sendToDesktop(message: object): void {
  if (!process.connected) return;
  // The connection may close between the check and write. Handle that race
  // without an unhandled IPC error interrupting graceful cleanup.
  process.send?.(message, (error) => {
    if (error && process.connected) console.warn(`Agent Visor IPC failed: ${String(error)}`);
  });
}
