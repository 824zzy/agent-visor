import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const directory = path.dirname(fileURLToPath(import.meta.url));
const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-clean-daemon-"));
const home = path.join(root, "home");
const data = path.join(root, "data");
const socket = path.join(root, "hook.sock");
const token = "clean-profile-token-000000000000000000000000";
const child = spawn(process.execPath, [path.resolve(directory, "../../server/dist/bin.js")], {
  env: {
    ...process.env,
    HOME: home,
    AGENT_VISOR_DATA_DIR: data,
    AGENT_VISOR_HOOK_SOCKET: socket,
    AGENT_VISOR_PORT: "0",
    AGENT_VISOR_SETTINGS_DOMAIN: "com.824zzy.AgentVisor.CleanProfileTest",
    AGENT_VISOR_TOKEN: token,
    AGENT_VISOR_VERSION: "2.6.2",
  },
  stdio: ["ignore", "pipe", "pipe"],
});

try {
  const origin = await daemonOrigin(child);
  const ws = new WebSocket(`${origin}?token=${encodeURIComponent(token)}`);
  const messages = [];
  ws.on("message", (value) => messages.push(JSON.parse(String(value))));
  await new Promise((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("error", reject);
  });
  ws.send(JSON.stringify({ type: "subscribe_sessions" }));
  ws.send(JSON.stringify({ type: "get_native_services" }));
  await waitFor(() => messages.some(({ type }) => type === "session_snapshot")
    && messages.some(({ type }) => type === "native_services_state"));
  const snapshot = messages.find(({ type }) => type === "session_snapshot");
  const native = messages.find(({ type }) => type === "native_services_state");
  assert(snapshot.sessions.length === 0, "clean HOME starts without provider rows");
  assert(native.settings.appearance === "dark", "clean settings use typed defaults");
  const settings = JSON.parse(await readFile(path.join(data, "settings.json"), "utf8"));
  assert(settings.version === 1, "clean settings use version one");
  assert(((await stat(path.join(data, "settings.json"))).mode & 0o777) === 0o600,
    "clean settings file uses mode 0600");
  ws.close();
  console.log("Clean profile PASS: Electron profile isolation and empty daemon settings, providers, protocol, and lifecycle.");
} finally {
  const exited = new Promise((resolve) => child.once("exit", resolve));
  child.kill("SIGTERM");
  await exited;
  await rm(root, { recursive: true, force: true });
}

function daemonOrigin(process) {
  return new Promise((resolve, reject) => {
    let output = "";
    const deadline = setTimeout(() => reject(new Error("Clean daemon startup timed out.")), 15_000);
    process.once("error", reject);
    process.once("exit", (code) => reject(new Error(`Clean daemon exited with ${code}.`)));
    process.stdout.on("data", (chunk) => {
      output += chunk.toString("utf8");
      const match = output.match(/listening at (ws:\/\/127\.0\.0\.1:\d+)/);
      if (!match) return;
      clearTimeout(deadline);
      resolve(match[1]);
    });
  });
}

async function waitFor(predicate) {
  const deadline = Date.now() + 5_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("Clean profile protocol timed out.");
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
