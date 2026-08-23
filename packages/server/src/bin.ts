import { randomBytes } from "node:crypto";
import type { NativeHelperUsageGlance } from "@agent-visor/protocol";
import { startHookSocket, type RunningHookSocket } from "./hook-socket.js";
import { menuPresentation, nativeActionFor } from "./menu.js";
import { NativeHelperProcess } from "./native-helper.js";
import { liveProviders } from "./providers/index.js";
import { startServer } from "./server.js";
import { SessionRepository } from "./sessions.js";
import { readCodexUsage } from "./usage.js";

const requestedPort = Number.parseInt(process.env.AGENT_VISOR_PORT ?? "0", 10);
const token = process.env.AGENT_VISOR_TOKEN ?? randomBytes(32).toString("base64url");
const repository = new SessionRepository(liveProviders());
const running = await startServer({ port: requestedPort, source: repository, token });
let hookSocket: RunningHookSocket | undefined;
let nativeHelper: NativeHelperProcess | undefined;
let unsubscribeMenu: (() => void) | undefined;
let usageTimer: NodeJS.Timeout | undefined;
let usageGlances: NativeHelperUsageGlance[] = [];
let refreshing = false;

const nativeHelperExecutable = process.env.AGENT_VISOR_NATIVE_HELPER;
if (nativeHelperExecutable) {
  try {
    nativeHelper = await NativeHelperProcess.start(nativeHelperExecutable, (event) => {
      const action = nativeActionFor(event, repository.current());
      if (action) process.send?.(action);
    });
    const present = () => {
      const presentation = menuPresentation(
        repository.current(),
        usageGlances,
      );
      void nativeHelper?.presentPills(presentation.pills, presentation.usageGlances)
        .catch((error: unknown) => console.warn(`Agent Visor menu update failed: ${String(error)}`));
    };
    unsubscribeMenu = repository.subscribe(present);
    present();
    const refreshUsage = async () => {
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
  unsubscribeMenu?.();
  await nativeHelper?.close();
  await hookSocket?.close();
  await running.close();
  process.exit(0);
}

process.once("SIGINT", () => void stop());
process.once("SIGTERM", () => void stop());
