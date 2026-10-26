import { readFile, stat } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import path from "node:path";
import { WebSocket } from "ws";
import type { PaseoAgent, PaseoSource, PaseoSnapshot } from "./paseo.js";
import { isRecord } from "./shared.js";

/** Read-only local daemon directory. Never starts, resumes, or writes to an agent. */
export class PaseoClient implements PaseoSource {
  private cached?: PaseoSnapshot;
  private expiresAt = 0;
  private pending?: Promise<PaseoSnapshot | undefined>;
  constructor(private readonly home: string) {}
  async read(fresh = false): Promise<PaseoSnapshot | undefined> {
    if (this.pending) return this.pending;
    if (!fresh && Date.now() < this.expiresAt) return this.cached;
    const operation = this.query().then(snapshot => {
      this.cached = snapshot; this.expiresAt = Date.now() + 3_000; return snapshot;
    });
    this.pending = operation;
    try { return await operation; }
    finally { if (this.pending === operation) this.pending = undefined; }
  }
  private async query(): Promise<PaseoSnapshot | undefined> {
    try {
      const root = path.join(this.home, ".paseo");
      const instance = JSON.parse(await readSmall(path.join(root, "paseo.pid"), 4_096));
      if (!/^127\.0\.0\.1:\d{1,5}$/.test(instance.listen)
        || !/^[a-zA-Z0-9_-]{1,128}$/.test(instance.serverId)) return undefined;
      const token = (await readSmall(path.join(root, "local-credential"), 4_096)).trim();
      if (!token) return undefined;
      const config = JSON.parse(await readSmall(path.join(root, "config.json"), 1_048_576));
      const providers: Record<string, string> = {};
      for (const [name, value] of Object.entries(config.agents?.providers ?? {})) {
        if (value && typeof value === "object" && "extends" in value && value.extends === "claude") {
          providers[name] = "claude";
        }
      }
      return await new Promise<PaseoSnapshot | undefined>(resolve => {
        const socket = new WebSocket(`ws://${instance.listen}/ws`, { maxPayload: 1_048_576 });
        let requestId = randomUUID();
        const agents: PaseoSnapshot["agents"] = [];
        const cursors = new Set<string>();
        let requested = false;
        let settled = false;
        const finish = (result?: PaseoSnapshot) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer); socket.terminate(); resolve(result);
        };
        const timer = setTimeout(() => finish(), 2_000);
        const request = (cursor?: string) => socket.send(JSON.stringify({ type: "session", message: {
          type: "fetch_agents_request", requestId, filter: { includeArchived: true },
          page: { limit: 200, ...(cursor ? { cursor } : {}) },
        } }));
        socket.on("error", () => finish());
        socket.on("close", () => finish());
        socket.on("open", () => socket.send(JSON.stringify({
          type: "hello", clientId: `agent-visor-${randomUUID()}`, clientType: "cli", protocolVersion: 1,
          auth: { kind: "localCredential", token }, capabilities: {
            all_providers: true, explicit_event_subscriptions: true, selective_agent_timeline: true,
            hello_rejection: true,
          },
        })));
        socket.on("message", (data, binary) => {
          if (binary || settled) return;
          try {
            const frame = JSON.parse(data.toString()); const message = frame.message ?? frame;
            if (frame.type === "hello.rejected") { finish(); return; }
            if (message.payload?.status === "server_info" && !requested) {
              if (message.payload.serverId !== instance.serverId) { finish(); return; }
              requested = true;
              request();
            }
            if (message.type === "fetch_agents_response" && message.payload.requestId === requestId) {
              if (!Array.isArray(message.payload.entries) || message.payload.entries.length > 200) {
                finish(); return;
              }
              agents.push(...message.payload.entries.map((entry: { agent: unknown }) => parseAgent(entry.agent)));
              const page = message.payload.pageInfo;
              if (typeof page?.hasMore !== "boolean") { finish(); return; }
              if (agents.length > 2_048) { finish(); return; }
              if (page.hasMore) {
                if (typeof page.nextCursor !== "string" || !page.nextCursor || page.nextCursor.length > 4_096
                  || cursors.has(page.nextCursor) || cursors.size >= 16) {
                  finish(); return;
                }
                cursors.add(page.nextCursor); requestId = randomUUID(); request(page.nextCursor);
              } else finish({ serverId: instance.serverId, providers, agents });
            }
          } catch { finish(); }
        });
      });
    } catch { return undefined; }
  }
}

/** Retain presence/state only, never permission inputs, transcript text, or provider secrets. */
function parseAgent(value: unknown): PaseoAgent {
  if (!isRecord(value) || !safeId(value.id) || !safeId(value.provider)
    || typeof value.cwd !== "string" || !path.isAbsolute(value.cwd) || value.cwd.length > 4_096
    || /[\u0000-\u001f]/.test(value.cwd) || typeof value.status !== "string" || value.status.length > 64
    || !date(value.updatedAt) || (value.title != null && (typeof value.title !== "string" || value.title.length > 512))
    || (value.pendingPermissions !== undefined && (!Array.isArray(value.pendingPermissions) || value.pendingPermissions.length > 128))
    || (value.requiresAttention !== undefined && typeof value.requiresAttention !== "boolean")) {
    throw new Error("Invalid Paseo directory");
  }
  const sessionId = isRecord(value.runtimeInfo) && safeId(value.runtimeInfo.sessionId) ? value.runtimeInfo.sessionId
    : isRecord(value.persistence) && safeId(value.persistence.sessionId) ? value.persistence.sessionId : undefined;
  return {
    id: value.id, provider: value.provider, cwd: value.cwd, status: value.status,
    updatedAt: date(value.updatedAt)!, title: value.title as string | null | undefined,
    archivedAt: typeof value.archivedAt === "string" ? value.archivedAt : undefined,
    internal: value.internal === true, parentAgentId: safeId(value.parentAgentId) ? value.parentAgentId : undefined,
    pendingPermissions: Array.isArray(value.pendingPermissions) ? value.pendingPermissions.map(() => ({})) : [],
    requiresAttention: value.requiresAttention as boolean | undefined,
    attentionReason: typeof value.attentionReason === "string" ? value.attentionReason : undefined,
    attentionTimestamp: date(value.attentionTimestamp),
    ...(sessionId ? { runtimeInfo: { sessionId } } : {}),
  };
}
function safeId(value: unknown): value is string {
  return typeof value === "string" && /^[a-zA-Z0-9_-]{1,128}$/.test(value);
}
function date(value: unknown): string | undefined {
  return typeof value === "string" && /^\d{4}-\d\d-\d\dT/.test(value) && Number.isFinite(Date.parse(value))
    ? new Date(value).toISOString() : undefined;
}
async function readSmall(file: string, maxBytes: number): Promise<string> {
  const info = await stat(file);
  if (!info.isFile() || info.size > maxBytes) throw new Error("Invalid Paseo local state");
  const value = await readFile(file, "utf8");
  if (Buffer.byteLength(value) > maxBytes) throw new Error("Invalid Paseo local state");
  return value;
}
