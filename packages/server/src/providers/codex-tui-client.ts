import { lstat, realpath, stat } from "node:fs/promises";
import path from "node:path";
import { WebSocket } from "ws";
import { machineWork, runProcess } from "../machine.js";
import { isRecord } from "./shared.js";

/** Live client transport identity; never historical thread origin or a cached capability. */
type ThreadInventory = { loaded: string[]; roots: Array<{ id: string; path: string | null }> };
export type CodexTuiBinding = { sessionIds: string[]; origin: string; socketPath: string; socketIdentity: string;
  inventory?: ThreadInventory };
export type CodexTuiTransportCapability = "supported" | "unsupported" | "unknown";
const uuid = (value: unknown): value is string => typeof value === "string"
  && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);

/** Read only the existing server. Never resumes, subscribes to, or starts a thread. */
export async function readCodexTuiBinding(pid: number, home: string,
  run: typeof runProcess = runProcess): Promise<CodexTuiBinding | undefined> {
  return readBinding(pid, home, run);
}

/**
 * Classify only the bounded OS evidence needed to decide whether legacy CLI
 * observation may be consulted. A successful exact process scan with no TCP
 * listener is a positive absence; command failure, malformed ownership, and a
 * listener that needs a deeper identity read remain unknown.
 */
export async function readCodexTuiTransportCapability(
  pid: number,
  _home: string,
  run: typeof runProcess = runProcess,
): Promise<CodexTuiTransportCapability> {
  if (!Number.isSafeInteger(pid) || pid <= 0) return "unknown";
  const result = await machineWork.run(() => run(
    "/usr/sbin/lsof",
    ["-b", "-w", "-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fpn"],
    { deadlineMs: 500, maxOutputBytes: 8_192 },
  ));
  if (result.status === "failed" && result.exitCode === 1 && !result.stderr.trim()) {
    const noListener = result.stdout.trim().split("\n").filter(Boolean);
    // lsof uses exit 1 for a successful no-match query. The caller has
    // already confirmed this exact PID is a live Codex frontend, so an empty
    // or PID-only result is a clean absence rather than a missing process.
    if (noListener.length === 0 || noListener.every(line => line === `p${pid}`)) return "unsupported";
    return "unknown";
  }
  if (result.status !== "success") return "unknown";
  const lines = result.stdout.trim().split("\n").filter(Boolean);
  if (!lines.includes(`p${pid}`) || lines.some(line => /^p/.test(line) && line !== `p${pid}`)) {
    return "unknown";
  }
  const addresses = lines.filter(line => /^n(?:127\.0\.0\.1|\[::1\]):\d+$/.test(line));
  if (addresses.length === 0 && lines.every(line => line === `p${pid}`)) return "unsupported";
  if (addresses.length === 1 && lines.every(line => line === `p${pid}` || line.startsWith("n"))) {
    return "supported";
  }
  return "unknown";
}

/** Revalidate transport ownership, never repeat transcript discovery on navigation. */
export async function verifyCodexTuiBinding(pid: number, home: string, expected: CodexTuiBinding,
  run: typeof runProcess = runProcess): Promise<boolean> {
  if (!expected.inventory || expected.sessionIds.length !== 1) return false;
  const current = await readBinding(pid, home, run, expected);
  return current?.socketPath === expected.socketPath && current.socketIdentity === expected.socketIdentity
    && current.origin === expected.origin && current.sessionIds.length === 1
    && current.sessionIds[0] === expected.sessionIds[0];
}

async function readBinding(pid: number, home: string, run: typeof runProcess,
  expected?: CodexTuiBinding): Promise<CodexTuiBinding | undefined> {
  let binding: CodexTuiBinding | undefined;
  try {
    if (!Number.isSafeInteger(pid) || pid <= 0 || !path.isAbsolute(home)) return undefined;
    const listeners = () => machineWork.run(() => run("/usr/sbin/lsof", ["-b", "-w", "-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fpn"],
      { deadlineMs: 500, maxOutputBytes: 8_192 }));
    const listening = await listeners();
    if (listening.status !== "success") return undefined;
    const lines = listening.stdout.trim().split("\n");
    if (!lines.includes(`p${pid}`) || lines.some(line => /^p/.test(line) && line !== `p${pid}`)) return undefined;
    const addresses = lines.filter(line => /^n(?:127\.0\.0\.1|\[::1\]):\d+$/.test(line));
    if (addresses.length !== 1) return undefined;
    const origin = `http://${addresses[0]!.slice(1)}`;
    const port = Number(new URL(origin).port);
    if (!Number.isSafeInteger(port) || port <= 0 || port > 65535) return undefined;
    const socketPath = await realpath(path.join(home, "app-server-control", "app-server-control.sock"));
    if (/[:?#\u0000-\u001f]/.test(socketPath)) return undefined;
    const info = await lstat(socketPath), parent = await stat(path.dirname(socketPath));
    if (!info.isSocket() || info.uid !== process.getuid?.() || (info.mode & 0o077) !== 0
      || parent.uid !== info.uid || (parent.mode & 0o077) !== 0) return undefined;
    const socketIdentity = `${info.dev}:${info.ino}:${info.uid}`;
    binding = { sessionIds: [], origin, socketPath, socketIdentity };
    if (expected && (expected.socketPath !== socketPath || expected.socketIdentity !== socketIdentity
      || expected.origin !== origin)) return binding;
    const result = await query(socketPath, origin, await realpath(home), expected?.inventory);
    const after = await lstat(socketPath);
    const current = await listeners();
    if (`${after.dev}:${after.ino}:${after.uid}` !== socketIdentity
      || current.status !== "success" || current.stdout !== listening.stdout) return binding;
    return { ...binding, ...result };
  } catch { return binding; }
}

async function query(socketPath: string, origin: string, home: string,
  known?: ThreadInventory): Promise<{ sessionIds: string[]; inventory: ThreadInventory }> {
  const socket = new WebSocket(`ws+unix://${socketPath}:/rpc`, { maxPayload: 1_048_576, handshakeTimeout: 1_000 });
  let id = 0;
  const pending = new Map<number, { resolve(value: unknown): void; reject(): void }>();
  const fail = () => { for (const entry of pending.values()) entry.reject(); pending.clear(); };
  socket.on("error", fail); socket.on("close", fail);
  socket.on("message", data => {
    try {
      const message: unknown = JSON.parse(data.toString());
      if (!isRecord(message) || typeof message.id !== "number") return;
      const entry = pending.get(message.id); if (!entry) return;
      pending.delete(message.id);
      if (message.error !== undefined) entry.reject(); else entry.resolve(message.result);
    } catch { fail(); socket.terminate(); }
  });
  const timer = setTimeout(() => { fail(); socket.terminate(); }, 1_500);
  const request = (method: string, params: object) => new Promise<unknown>((resolve, reject) => {
    const current = ++id;
    pending.set(current, { resolve, reject: () => reject(new Error("Codex client identity unavailable")) });
    socket.send(JSON.stringify({ id: current, method, params }));
  });
  try {
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve); socket.once("error", reject); socket.once("close", () => reject(new Error("closed")));
    });
    await request("initialize", { clientInfo: { name: "agent-visor-owner-reader", version: "1" }, capabilities: { experimentalApi: true } });
    socket.send(JSON.stringify({ method: "initialized" }));
    const loaded = await request("thread/loaded/list", { limit: 128 });
    if (!isRecord(loaded) || !Array.isArray(loaded.data) || loaded.data.length > 128
      || loaded.nextCursor != null || !loaded.data.every(uuid)
      || new Set(loaded.data).size !== loaded.data.length) throw new Error("Incomplete thread inventory");
    const ids = [...loaded.data].sort();
    if (known && JSON.stringify(ids) !== JSON.stringify(known.loaded)) throw new Error("Thread inventory changed");
    const inventory: ThreadInventory = known ?? { loaded: ids, roots: [] };
    if (!known) for (const threadId of ids) {
      const read = await request("thread/read", { threadId, includeTurns: false });
      const thread = isRecord(read) ? read.thread : undefined;
      // UUID ancestry and transcript locations are captured off the click path.
      // Retain unmaterialized roots too: they can become ambiguous without a new UUID.
      if (!isRecord(thread) || thread.id !== threadId) throw new Error("Incomplete thread metadata");
      if (uuid(thread.parentThreadId)) continue;
      inventory.roots.push({ id: threadId, path: thread.parentThreadId === null
        && thread.ephemeral === false && ["cli", "vscode"].includes(String(thread.source))
        && typeof thread.path === "string" && path.isAbsolute(thread.path) ? thread.path : null });
    }
    const matches = await Promise.all(inventory.roots.map(async root => {
      if (root.path !== null) {
        const file = await realpath(root.path).catch(() => undefined);
        if (!file || !file.startsWith(path.join(home, "sessions") + path.sep)
          || !(await stat(file)).isFile()) return undefined;
      } else if (!known) return undefined;
      const result = await request("mcpServerStatus/list", { threadId: root.id, serverName: "codex_tui", detail: "toolsAndAuthOnly", limit: 100 });
      if (!isRecord(result) || !Array.isArray(result.data) || result.nextCursor != null) throw new Error("Incomplete client inventory");
      const clients = result.data.filter(value => isRecord(value) && value.name === "codex_tui"
        && value.runtimeStatus === "connected" && value.httpOrigin === origin);
      if (clients.length > 1) throw new Error("Ambiguous client inventory");
      if (root.path === null && clients.length) throw new Error("Root metadata needs discovery");
      return clients.length === 1 ? root.id.toLowerCase() : undefined;
    }));
    return { sessionIds: matches.filter((id): id is string => id !== undefined).sort(), inventory };
  } finally { clearTimeout(timer); fail(); socket.terminate(); }
}
