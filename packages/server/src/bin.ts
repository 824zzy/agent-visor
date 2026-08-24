import { randomBytes } from "node:crypto";
import os from "node:os";
import path from "node:path";
import type { NativeHelperUsageGlance } from "@agent-visor/protocol";
import { stopCodexTurns } from "./codex-turn.js";
import { startHookSocket, type RunningHookSocket } from "./hook-socket.js";
import { menuPresentation, nativeActionFor } from "./menu.js";
import { NativeHelperProcess, UnavailableNativeHelper } from "./native-helper.js";
import { NativeServicesRepository } from "./native-services.js";
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
const settings = await SettingsRepository.open({
  root: dataRoot,
  readLegacy: () => readLegacyDefaults(settingsDomain, dataRoot),
});
if (process.env.AGENT_VISOR_LAUNCH_AT_LOGIN) {
  await settings.update({ launchAtLogin: process.env.AGENT_VISOR_LAUNCH_AT_LOGIN === "true" });
}
const repository = new SessionRepository(liveProviders(
  os.homedir(),
  () => settings.current().observedWindowHours * 60 * 60 * 1_000,
));

let hookSocket: RunningHookSocket | undefined;
let nativeHelper: NativeHelperProcess | undefined;
let nativeServices: NativeServicesRepository | undefined;
let unsubscribeMenu: (() => void) | undefined;
let unsubscribeNotifications: (() => void) | undefined;
let unsubscribeSettings: (() => void) | undefined;
let usageTimer: NodeJS.Timeout | undefined;
let permissionTimer: NodeJS.Timeout | undefined;
let updateTimer: NodeJS.Timeout | undefined;
let usageGlances: NativeHelperUsageGlance[] = [];
let refreshing = false;

const nativeHelperExecutable = process.env.AGENT_VISOR_NATIVE_HELPER;
if (nativeHelperExecutable) {
  try {
    nativeHelper = await NativeHelperProcess.start(nativeHelperExecutable, (event) => {
      if (event.event === "activate_pill") {
        const action = nativeActionFor(event, repository.current());
        if (action?.action === "open_chat") {
          process.send?.(action);
          return;
        }
        void repository.focusSession(event.sessionId).then((error) => {
          if (error && action) process.send?.(action);
        });
        return;
      }
      const action = nativeActionFor(event, repository.current());
      if (action) process.send?.(action);
    });
    const present = () => {
      const preferences = settings.current();
      const presentation = preferences.pillsEnabled
        ? menuPresentation(
          repository.current(),
          preferences.codexUsageGlanceEnabled ? usageGlances : [],
        )
        : { pills: [], usageGlances: [] };
      void nativeHelper?.presentPills(
        presentation.pills,
        presentation.usageGlances,
        preferences.sessionShortcutModifierFamily,
        preferences.hotkeyTrigger,
        preferences.customHotkeyCombo,
      )
        .catch((error: unknown) => console.warn(`Agent Visor menu update failed: ${String(error)}`));
    };
    unsubscribeMenu = repository.subscribe(present);
    unsubscribeSettings = settings.subscribe(present);
    present();

    const refreshUsage = async () => {
      if (!settings.current().codexUsageGlanceEnabled) return;
      const codex = await readCodexUsage();
      if (!codex) return;
      usageGlances = [codex];
      present();
    };
    void refreshUsage();
    usageTimer = setInterval(() => void refreshUsage(), 300_000);
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
  currentVersion,
  checkUpdates: () => checkForUpdates(currentVersion),
  emitDesktop: (effect) => process.send?.({ type: "native_effect", ...effect }),
});
await nativeServices.start();
permissionTimer = setInterval(() => void nativeServices?.refresh(), 15_000);
permissionTimer.unref();
void nativeServices.checkForUpdates();
updateTimer = setInterval(() => void nativeServices?.checkForUpdates(), 6 * 60 * 60_000);
updateTimer.unref();
unsubscribeNotifications = repository.subscribe((snapshot) => {
  nativeServices?.reconcileSessions(snapshot);
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

void refresh();
const refreshTimer = setInterval(() => void refresh(), 3_000);
refreshTimer.unref();

const hookPath = process.env.AGENT_VISOR_HOOK_SOCKET ?? "/tmp/agent-visor.sock";
try {
  hookSocket = await startHookSocket({ socketPath: hookPath, repository });
  console.log(`Agent Visor hook socket listening at ${hookPath}`);
} catch (error) {
  console.warn(`Agent Visor hook socket unavailable: ${String(error)}`);
}

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
  unsubscribeSettings?.();
  stopCodexTurns();
  await sessionControls.close();
  await nativeHelper?.close();
  await hookSocket?.close();
  await running.close();
  process.exit(0);
}

process.once("SIGINT", () => void stop());
process.once("SIGTERM", () => void stop());
