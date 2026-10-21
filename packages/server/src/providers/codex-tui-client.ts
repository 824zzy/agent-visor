import { lstat, realpath, stat } from "node:fs/promises";
import path from "node:path";
import { WebSocket } from "ws";
import { machineWork, runProcess } from "../machine.js";
import { isRecord } from "./shared.js";

/** Live client transport identity; never historical thread origin or a cached capability. */
export type CodexTuiBinding = { sessionIds: string[]; origin: string; socketPath: string; socketIdentity: string };
const uuid = (value: unknown): value is string => typeof value === "string"
  && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);

/** Read only the existing server. Never resumes, subscribes to, or starts a thread. */
export async function readCodexTuiBinding(pid: number, home: string,
  run: typeof runProcess = runProcess): Promise<CodexTuiBinding | undefined> {
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
    const sessionIds = await query(socketPath, origin, await realpath(home));
    const after = await lstat(socketPath);
    const current = await listeners();
    if (`${after.dev}:${after.ino}:${after.uid}` !== socketIdentity
      || current.status !== "success" || current.stdout !== listening.stdout) return binding;
    return { ...binding, sessionIds };
  } catch { return binding; }
}

async function query(socketPath: string, origin: string, home: string): Promise<string[]> {
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
    const matches: string[] = [];
    for (const threadId of loaded.data) {
      const read = await request("thread/read", { threadId, includeTurns: false });
      const thread = isRecord(read) ? read.thread : undefined;
      if (!isRecord(thread) || thread.id !== threadId || thread.parentThreadId !== null
        || thread.ephemeral !== false || !["cli", "vscode"].includes(String(thread.source))
        || typeof thread.path !== "string" || !path.isAbsolute(thread.path)) continue;
      // Startup drafts may already have a transport but no persisted conversation.
      const file = await realpath(thread.path).catch(() => undefined);
      if (!file || !file.startsWith(path.join(home, "sessions") + path.sep)
        || !(await stat(file)).isFile()) continue;
      const result = await request("mcpServerStatus/list", { threadId, serverName: "codex_tui", detail: "toolsAndAuthOnly", limit: 100 });
      if (!isRecord(result) || !Array.isArray(result.data) || result.nextCursor != null) throw new Error("Incomplete client inventory");
      const clients = result.data.filter(value => isRecord(value) && value.name === "codex_tui"
        && value.runtimeStatus === "connected" && value.httpOrigin === origin);
      if (clients.length > 1) throw new Error("Ambiguous client inventory");
      if (clients.length === 1) matches.push(threadId.toLowerCase());
    }
    return matches.sort();
  } finally { clearTimeout(timer); fail(); socket.terminate(); }
}
