import type { NativeHelperGhosttyBinding } from "@agent-visor/protocol";
import { randomBytes, randomUUID } from "node:crypto";
import { createConnection } from "node:net";
import { lstat, open } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { isDeepStrictEqual } from "node:util";
import { machineWork, runProcess } from "../machine.js";
import { isRecord, isVerifiableProcessInstanceToken, processInstanceToken } from "./shared.js";

export type HerdrProcessContext = {
  provider: "claude_code" | "codex"; pid: number; processStartToken: string;
  sessionId: string; cwd: string; serverPID: number; serverProcessStartToken: string;
  socketPath: string; paneId: string;
};
type ClientReference = { boot_id: string; client_id: number; generation: number };
type ProcessInstance = { pid: number; start: number };
type NavigationTarget = { boot_id: string; pane_id: string; terminal_id: string;
  process: ProcessInstance; session: unknown };
export type HerdrSurfaceTarget = HerdrProcessContext & {
  socketIdentity: string; target: NavigationTarget; client: ClientReference;
  clientProcess: ProcessInstance; viewRevision: number; projectionRevision: number;
};
const unavailable = () => new Error("Exact Herdr navigation is unavailable. The Herdr server and client may need the navigation update.");
const bounded = (value: unknown): value is string => typeof value === "string"
  && value.length > 0 && value.length <= 128 && !/[\u0000-\u001f]/.test(value);
const positive = (value: unknown): value is number => Number.isSafeInteger(value) && Number(value) > 0;
const revision = (value: unknown): value is number => Number.isSafeInteger(value) && Number(value) >= 0;
const uuid = (value: string) => /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
function processInstance(value: unknown): value is ProcessInstance {
  return isRecord(value) && positive(value.pid) && value.pid <= 2_147_483_647 && positive(value.start);
}
function clientReference(value: unknown): value is ClientReference {
  return isRecord(value) && bounded(value.boot_id) && positive(value.client_id) && positive(value.generation);
}
function contextValid(value: HerdrProcessContext): boolean {
  return (value.provider === "claude_code" || value.provider === "codex")
    && isVerifiableProcessInstanceToken(value.pid, value.processStartToken)
    && isVerifiableProcessInstanceToken(value.serverPID, value.serverProcessStartToken)
    && uuid(value.sessionId) && path.isAbsolute(value.cwd) && value.cwd.length <= 4096
    && path.isAbsolute(value.socketPath) && Buffer.byteLength(value.socketPath) <= 103
    && /^w[1-9]\d*:p[1-9]\d*$/.test(value.paneId)
    && !/[\u0000-\u001f]/.test(value.cwd + value.socketPath);
}

type NativeBindingHost = {
  ghosttyBindingStatus?(): Promise<boolean>;
  resolveGhosttyBinding?(nonce: string): Promise<NativeHelperGhosttyBinding>;
  focusGhosttyBinding?(target: NativeHelperGhosttyBinding): Promise<void>;
};
const same = isDeepStrictEqual;

/** Read-only discovery. Native marker leases are reserved for explicit clicks. */
export class HerdrClient {
  constructor(private readonly readContext?: (pid: number) => Promise<HerdrProcessContext | undefined>,
              private readonly deadlineMs = 400, private readonly system: HerdrSystem = liveSystem) {}
  async resolve(pid: number, sessionId: string, cwd: string, ownLeaseNonce?: string): Promise<HerdrSurfaceTarget | undefined> {
    try {
      const context = await (this.readContext ? this.readContext(pid) : readLiveContext(pid, sessionId, cwd, this.system));
      if (!context || !contextValid(context) || context.pid !== pid
        || context.sessionId !== sessionId || context.cwd !== cwd) return undefined;
      const identity = await this.socketIdentity(context.socketPath);
      const result = await this.rpc(context.socketPath, identity, "client.target", { pane_id: context.paneId });
      const target = result.target;
      if (!isRecord(target) || !bounded(target.boot_id) || target.pane_id !== context.paneId
        || !bounded(target.terminal_id) || !processInstance(target.process) || target.process.pid !== context.pid) return undefined;
      // Claude's current per-PID session metadata proves its UUID. Codex
      // additionally needs the runtime's native session reference, not cwd.
      if ((context.provider === "codex" || target.session != null) && !sameSession(target.session, context)) return undefined;
      const listed = await this.rpc(context.socketPath, identity, "client.list", {});
      if (listed.boot_id !== target.boot_id || listed.unclassified_connections !== 0
        || !revision(listed.view_revision) || !Array.isArray(listed.clients) || listed.clients.length !== 1) return undefined;
      const client = listed.clients[0];
      if (!isRecord(client) || !clientReference(client.client) || client.client.boot_id !== target.boot_id
        || client.presentation_capable !== true || client.binding_capable !== true || client.surface_active !== true
        || !revision(client.projection_revision) || !processInstance(client.local_process)) return undefined;
      if (client.binding != null && (!isRecord(client.binding)
        || typeof client.binding.nonce !== "string" || !/^[0-9a-f]{32}$/.test(client.binding.nonce)
        || (client.binding.state !== "released"
          && !(ownLeaseNonce && client.binding.nonce === ownLeaseNonce && client.binding.state === "applied")))) return undefined;
      return { ...context, socketIdentity: identity, target: target as NavigationTarget,
        client: client.client, clientProcess: client.local_process,
        viewRevision: listed.view_revision, projectionRevision: client.projection_revision };
    } catch { return undefined; }
  }

  async focus(expected: HerdrSurfaceTarget, native: NativeBindingHost, isCurrent = () => true): Promise<void> {
    if (!native.ghosttyBindingStatus || !native.resolveGhosttyBinding || !native.focusGhosttyBinding
      || !await native.ghosttyBindingStatus()) {
      throw new Error("Exact Herdr focus needs Ghostty Automation access for the Agent Visor native helper.");
    }
    const deadline = performance.now() + 4500;
    const nonce = randomBytes(16).toString("hex");
    let leaseAttempted = false;
    const check = () => { if (!isCurrent() || performance.now() > deadline) throw unavailable(); };
    const refresh = async () => {
      check();
      const fresh = await this.resolve(expected.pid, expected.sessionId, expected.cwd, leaseAttempted ? nonce : undefined);
      if (!fresh || !sameRoute(fresh, expected)) throw unavailable();
      check(); return fresh;
    };
    let fresh = await refresh();
    const request = (method: string, params: object) => this.rpc(fresh.socketPath, fresh.socketIdentity, method, params);
    const readClient = async () => {
      check();
      const response = await request("client.get", { client: fresh.client });
      const client = response.client;
      if (!isRecord(client) || !same(client.client, fresh.client)
        || !same(client.local_process, fresh.clientProcess) || client.surface_active !== true) throw unavailable();
      return client;
    };
    const waitFor = async (accept: (client: Record<string, unknown>) => boolean) => {
      for (let attempt = 0; attempt < 12; attempt++) {
        const client = await readClient(); if (accept(client)) return client;
        await new Promise(resolve => setTimeout(resolve, 35));
      }
      throw unavailable();
    };
    try {
      leaseAttempted = true;
      await request("client.bind_begin", { client: fresh.client, nonce, ttl_ms: 5000 });
      await waitFor(client => isRecord(client.binding) && client.binding.nonce === nonce && client.binding.state === "applied");
      check();
      const binding = await native.resolveGhosttyBinding(nonce);
      if (binding.nonce !== nonce) throw unavailable();
      fresh = await refresh();
      const navigationId = randomUUID();
      const accepted = await request("client.focus_exclusive", {
        client: fresh.client, navigation_id: navigationId, expected_view_revision: fresh.viewRevision,
        expected_projection_revision: fresh.projectionRevision, pane_id: fresh.paneId,
        terminal_id: fresh.target.terminal_id, target: fresh.target,
      });
      if (accepted.status !== "accepted" || !same(accepted.client, fresh.client)
        || accepted.navigation_id !== navigationId || !revision(accepted.minimum_projection_revision)) throw unavailable();
      const applied = (client: Record<string, unknown>) => {
        const receipt = client.applied_navigation;
        if (!isRecord(receipt) || !isRecord(receipt.projection)) return false;
        return receipt.projection.navigation_id === navigationId && same(receipt.projection.client, fresh.client)
          && same(receipt.projection.target, fresh.target)
          && revision(receipt.projection_revision) && receipt.projection_revision >= Number(accepted.minimum_projection_revision)
          && positive(receipt.surface_revision) && client.pane_id === fresh.paneId
          && client.terminal_id === fresh.target.terminal_id;
      };
      await waitFor(applied);
      check(); await native.focusGhosttyBinding(binding); check();
      if (!applied(await readClient())) throw unavailable();
      const current = await this.resolve(expected.pid, expected.sessionId, expected.cwd, nonce);
      if (!current || !sameRoute(current, fresh)) throw unavailable();
      await request("client.bind_end", { client: fresh.client, nonce });
      await waitFor(client => isRecord(client.binding) && client.binding.nonce === nonce && client.binding.state === "released");
      leaseAttempted = false;
      check();
    } finally {
      // Lost replies are uncertain, so release even when admission failed.
      // The client also restores its own title after the hard five-second TTL.
      if (leaseAttempted) await request("client.bind_end", { client: fresh.client, nonce }).catch(() => {});
    }
  }

  private async socketIdentity(socketPath: string): Promise<string> {
    const info = await lstat(socketPath);
    if (!info.isSocket() || info.uid !== process.getuid?.()) throw unavailable();
    return `${info.dev}:${info.ino}:${info.uid}`;
  }
  private async rpc(socketPath: string, identity: string, method: string, params: object): Promise<Record<string, unknown>> {
    if (await this.socketIdentity(socketPath) !== identity) throw unavailable();
    return new Promise((resolve, reject) => {
      const id = randomUUID(); const socket = createConnection(socketPath);
      let input = ""; let bytes = 0; let done = false;
      const finish = (result?: Record<string, unknown>) => {
        if (done) return; done = true; clearTimeout(timer); socket.destroy();
        if (result) resolve(result); else reject(unavailable());
      };
      const timer = setTimeout(() => finish(), this.deadlineMs);
      socket.setEncoding("utf8"); socket.on("error", () => finish()); socket.on("close", () => finish());
      socket.on("connect", () => socket.write(JSON.stringify({ id, method, params }) + "\n"));
      socket.on("data", chunk => {
        bytes += Buffer.byteLength(chunk); if (bytes > 65_536) { finish(); return; }
        input += chunk; const end = input.indexOf("\n"); if (end < 0) return;
        try {
          const response = JSON.parse(input.slice(0, end));
          finish(isRecord(response) && response.id === id && response.error === undefined && isRecord(response.result)
            ? response.result : undefined);
        } catch { finish(); }
      });
    });
  }
}

function sameRoute(a: HerdrSurfaceTarget, b: HerdrSurfaceTarget): boolean {
  return a.pid === b.pid && a.processStartToken === b.processStartToken && a.sessionId === b.sessionId
    && a.cwd === b.cwd && a.paneId === b.paneId && a.socketPath === b.socketPath && a.socketIdentity === b.socketIdentity
    && a.serverPID === b.serverPID && a.serverProcessStartToken === b.serverProcessStartToken
    && same(a.target, b.target) && same(a.client, b.client) && same(a.clientProcess, b.clientProcess);
}

function sameSession(value: unknown, context: HerdrProcessContext): boolean {
  if (!isRecord(value) || typeof value.value !== "string" || typeof value.agent !== "string") return false;
  const agent = value.agent.toLowerCase().replaceAll(" ", "_");
  if (context.provider === "claude_code" ? !["claude", "claude_code"].includes(agent) : agent !== "codex") return false;
  const id = value.kind === "id" ? value.value
    : value.kind === "path" && path.isAbsolute(value.value) ? path.basename(value.value, ".jsonl") : "";
  return id.toLowerCase() === context.sessionId.toLowerCase();
}

export type HerdrSystem = {
  run: typeof runProcess;
  readClaudeMetadata(pid: number, configRoot?: string): Promise<string | undefined>;
};
const liveSystem: HerdrSystem = {
  run: runProcess,
  async readClaudeMetadata(pid, configRoot) {
    const filePath = path.join(configRoot ?? path.join(os.homedir(), ".claude"), "sessions", `${pid}.json`);
    const info = await lstat(filePath);
    if (!info.isFile() || info.uid !== process.getuid?.() || info.size > 32_768) return undefined;
    const file = await open(filePath);
    try {
      const data = await file.readFile(); return data.length <= 32_768 ? data.toString("utf8") : undefined;
    } finally { await file.close(); }
  },
};

/** Whitelisted routing fields only. Raw process/environment output is never retained or logged. */
async function readLiveContext(pid: number, sessionId: string, cwd: string, system: HerdrSystem): Promise<HerdrProcessContext | undefined> {
  if (!positive(pid) || !uuid(sessionId)) return undefined;
  const table = await machineWork.run(() => system.run("/usr/bin/env", ["TZ=UTC", "LC_ALL=C", "/bin/ps", "-axww", "-o", "pid=,ppid=,lstart=,comm="],
    { deadlineMs: 1000, maxOutputBytes: 4 * 1_048_576 }));
  if (table.status !== "success") return undefined;
  const processes = new Map(table.stdout.split("\n").flatMap(line => {
    const match = /^\s*(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+[\d:]+\s+\d+)\s+(.+)$/.exec(line);
    return match ? [[Number(match[1]), { parent: Number(match[2]), started: match[3]! + " UTC", command: match[4]! }] as const] : [];
  }));
  const child = processes.get(pid); if (!child) return undefined;
  let ancestor = pid; let serverPID: number | undefined; const visited = new Set<number>();
  while (!visited.has(ancestor)) {
    visited.add(ancestor); const row = processes.get(ancestor); if (!row) break;
    if (path.basename(row.command) === "herdr") { serverPID = ancestor; break; }
    ancestor = row.parent;
  }
  if (!serverPID) return undefined;
  const provider = path.basename(child.command) === "codex" ? "codex" : "claude_code";
  if (provider === "claude_code" && path.basename(child.command) !== "claude"
    && !/\/\.local\/share\/claude\/versions\/\d+\.\d+\.\d+$/.test(child.command)) return undefined;
  const environment = await machineWork.run(() => system.run("/bin/ps", ["eww", "-p", String(pid), "-o", "command="],
    { deadlineMs: 1000, maxOutputBytes: 128 * 1024 }));
  if (environment.status !== "success") return undefined;
  const field = (key: string) => {
    const values = [...environment.stdout.matchAll(new RegExp("(?:^| )" + key + "=(.*?)(?= [A-Za-z_][A-Za-z0-9_]*=|$)", "g"))];
    return values.length === 1 ? values[0]![1]?.trim() : undefined;
  };
  const socketPath = field("HERDR_SOCKET_PATH"), paneId = field("HERDR_PANE_ID");
  if (!socketPath || !paneId) return undefined;
  const configRoot = field("CLAUDE_CONFIG_DIR");
  if (configRoot && (!path.isAbsolute(configRoot) || configRoot.length > 4096 || /[\u0000-\u001f]/.test(configRoot))) return undefined;
  if (provider === "claude_code") {
    const metadata = await system.readClaudeMetadata(pid, configRoot); if (!metadata) return undefined;
    const row = JSON.parse(metadata);
    if (!isRecord(row) || row.pid !== pid || row.kind !== "interactive" || row.parkedJobId !== undefined
      || row.sessionId !== sessionId || row.cwd !== cwd || typeof row.procStart !== "string") return undefined;
    const started = /^\w{3} \w{3}\s+\d+ [\d:]+ \d{4}$/.test(row.procStart) ? row.procStart + " UTC" : row.procStart;
    if (Date.parse(started) !== Date.parse(child.started)) return undefined;
  }
  const token = processInstanceToken(pid, child.started);
  const serverToken = processInstanceToken(serverPID, processes.get(serverPID)!.started);
  if (!token || !serverToken) return undefined;
  return { provider, pid, processStartToken: token, sessionId, cwd,
    serverPID, serverProcessStartToken: serverToken, socketPath, paneId };
}

export const focusHerdrSurface = (target: HerdrSurfaceTarget, native: NativeBindingHost, isCurrent: () => boolean) =>
  new HerdrClient().focus(target, native, isCurrent);
