import { randomBytes } from "node:crypto";
import { fixtureSnapshot } from "./fixture.js";
import { startServer } from "./server.js";

const requestedPort = Number.parseInt(process.env.AGENT_VISOR_PORT ?? "0", 10);
const token = process.env.AGENT_VISOR_TOKEN ?? randomBytes(32).toString("base64url");
const running = await startServer({ port: requestedPort, snapshot: fixtureSnapshot, token });

process.send?.({ type: "ready", url: running.url });
console.log(`Agent Visor daemon listening at ${new URL(running.url).origin}`);

async function stop(): Promise<void> {
  await running.close();
  process.exit(0);
}

process.once("SIGINT", stop);
process.once("SIGTERM", stop);
