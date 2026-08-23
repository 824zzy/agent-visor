import { randomBytes } from "node:crypto";
import { startHookSocket, type RunningHookSocket } from "./hook-socket.js";
import { liveProviders } from "./providers/index.js";
import { startServer } from "./server.js";
import { SessionRepository } from "./sessions.js";

const requestedPort = Number.parseInt(process.env.AGENT_VISOR_PORT ?? "0", 10);
const token = process.env.AGENT_VISOR_TOKEN ?? randomBytes(32).toString("base64url");
const repository = new SessionRepository(liveProviders());
const running = await startServer({ port: requestedPort, source: repository, token });
let hookSocket: RunningHookSocket | undefined;
let refreshing = false;

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
  await hookSocket?.close();
  await running.close();
  process.exit(0);
}

process.once("SIGINT", () => void stop());
process.once("SIGTERM", () => void stop());
