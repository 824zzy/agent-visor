import { randomUUID } from "node:crypto";
import { createConnection } from "node:net";
import { lstat, open } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { machineWork, runProcess } from "../machine.js";
import { navigationStep } from "../navigation-diagnostics.js";
import { isRecord, isVerifiableProcessInstanceToken, processInstanceToken } from "./shared.js";

export type CmuxProcessContext = {
  pid: number; processStartToken: string;
  applicationPID: number; applicationProcessStartToken: string;
  sessionId: string; cwd: string;
  socketPath: string; workspaceId: string; surfaceId: string;
};
export type CmuxSurfaceTarget = CmuxProcessContext & { windowId: string };
type CmuxSystem = {
  run: typeof runProcess;
  readMetadata(pid: number): Promise<string | undefined>;
};
const liveSystem: CmuxSystem = {
  run: runProcess,
  async readMetadata(pid) {
    const file = await open(path.join(os.homedir(), ".claude/sessions", `${pid}.json`));
    try {
      const buffer = Buffer.alloc(16 * 1_024 + 1);
      const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
      return bytesRead > 16 * 1_024 ? undefined : buffer.subarray(0, bytesRead).toString();
    } finally { await file.close(); }
  },
};

export class CmuxClient {
  constructor(
    private readonly readContext?: (pid: number) => Promise<CmuxProcessContext | undefined>,
    private readonly deadlineMs = 750,
    private readonly system: CmuxSystem = liveSystem,
  ) {}
  async resolve(pid: number, sessionId: string, cwd: string): Promise<CmuxSurfaceTarget | undefined> {
    try {
      const context = await this.processContext(pid);
      if (!context || !validContext(context) || context.pid !== pid
        || context.sessionId !== sessionId || context.cwd !== cwd) return undefined;
      const result = await this.rpc(context.socketPath, "system.identify", {
        caller: { workspace_id: context.workspaceId, surface_id: context.surfaceId },
      });
      const caller = result.caller;
      if (result.socket_path !== context.socketPath
        || (result.bundle_identifier !== undefined && result.bundle_identifier !== "com.cmuxterm.app")
        || !isRecord(caller) || !sameID(caller.workspace_id, context.workspaceId)
        || !sameID(caller.surface_id, context.surfaceId) || !uuid(caller.window_id)
        || caller.surface_type !== "terminal") return undefined;
      return { ...context, windowId: caller.window_id };
    } catch { return undefined; }
  }
  async focus(target: CmuxSurfaceTarget, isCurrent = () => true): Promise<void> {
    const current = await this.resolve(target.pid, target.sessionId, target.cwd);
    if (!current || !sameTarget(current, target)) throw new Error("The requested cmux surface is no longer available.");
    const latest = await this.processContext(target.pid);
    if (!latest || !validContext(latest) || !sameTarget({ ...latest, windowId: current.windowId }, current)) {
      throw new Error("The cmux conversation changed before focus.");
    }
    if (!isCurrent()) return;
    await this.rpc(current.socketPath, "surface.focus", {
      window_id: current.windowId, workspace_id: current.workspaceId, surface_id: current.surfaceId,
    });
    navigationStep("cmux_focus", { windowId: current.windowId, workspaceId: current.workspaceId,
      surfaceId: current.surfaceId, outcome: "accepted" });
    // Unscoped identify can return cmux's published read snapshot from before
    // selection. Read the exact window's live selection instead, allowing brief
    // focus restoration without repeating focus or sending terminal input.
    for (let attempt = 0; attempt < 4; attempt++) {
      if (!isCurrent()) { navigationStep("superseded"); return; }
      const result = await this.rpc(current.socketPath, "system.identify", { window_id: current.windowId });
      const focused = result.focused;
      const identityMatch = isRecord(focused) && sameID(focused.window_id, current.windowId)
        && sameID(focused.workspace_id, current.workspaceId) && sameID(focused.surface_id, current.surfaceId);
      navigationStep("cmux_readback", { windowId: current.windowId, workspaceId: current.workspaceId,
        surfaceId: current.surfaceId, focusedWindowId: isRecord(focused) ? focused.window_id : undefined,
        focusedWorkspaceId: isRecord(focused) ? focused.workspace_id : undefined,
        focusedSurfaceId: isRecord(focused) ? focused.surface_id : undefined,
        attempt: attempt + 1, identityMatch, scope: "window" });
      if (identityMatch) return;
      if (attempt < 3) await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error("The requested cmux surface could not be focused.");
  }

  private async processContext(pid: number): Promise<CmuxProcessContext | undefined> {
    try { return await (this.readContext ? this.readContext(pid) : readLiveContext(pid, this.system)); }
    catch { return undefined; }
  }

  /** Only identity reads and exact focus. No input, attach, resume, or creation methods. */
  private async rpc(socketPath: string, method: "system.identify" | "surface.focus", params: object): Promise<Record<string, unknown>> {
    const info = await lstat(socketPath);
    if (!info.isSocket() || info.uid !== process.getuid?.()) throw new Error("cmux socket is unavailable.");
    return new Promise((resolve, reject) => {
      const id = randomUUID(); const socket = createConnection(socketPath);
      let input = ""; let bytes = 0; let settled = false;
      const finish = (result?: Record<string, unknown>, error?: string) => {
        if (settled) return;
        settled = true; clearTimeout(timer); socket.destroy();
        if (result) resolve(result); else reject(new Error(error ?? "cmux socket access is unavailable."));
      };
      const timer = setTimeout(() => finish(undefined, "cmux did not respond in time."), this.deadlineMs);
      socket.setEncoding("utf8");
      socket.on("connect", () => socket.write(JSON.stringify({ id, method, params }) + "\n"));
      socket.on("error", () => finish()); socket.on("close", () => finish());
      socket.on("data", chunk => {
        bytes += Buffer.byteLength(chunk); if (bytes > 64 * 1_024) { finish(); return; }
        input += chunk; const end = input.indexOf("\n"); if (end < 0) return;
        try {
          const frame = JSON.parse(input.slice(0, end));
          if (!isRecord(frame) || frame.id !== id || frame.ok !== true || !isRecord(frame.result)) {
            finish(); return;
          }
          finish(frame.result);
        } catch { finish(); }
      });
    });
  }
}
const uuid = (value: unknown): value is string => typeof value === "string"
  && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const sameID = (a: unknown, b: string) => uuid(a) && a.toLowerCase() === b.toLowerCase();
function validContext(value: CmuxProcessContext): boolean {
  return uuid(value.sessionId) && uuid(value.workspaceId) && uuid(value.surfaceId)
    && isVerifiableProcessInstanceToken(value.pid, value.processStartToken)
    && isVerifiableProcessInstanceToken(value.applicationPID, value.applicationProcessStartToken)
    && path.isAbsolute(value.cwd) && value.cwd.length <= 4_096
    && path.isAbsolute(value.socketPath) && Buffer.byteLength(value.socketPath) <= 103
    && !/[\u0000-\u001f]/.test(value.cwd + value.socketPath);
}
function sameTarget(a: CmuxSurfaceTarget, b: CmuxSurfaceTarget): boolean {
  return a.pid === b.pid && a.processStartToken === b.processStartToken
    && a.applicationPID === b.applicationPID && a.applicationProcessStartToken === b.applicationProcessStartToken
    && a.sessionId === b.sessionId && a.cwd === b.cwd && a.socketPath === b.socketPath
    && sameID(a.workspaceId, b.workspaceId) && sameID(a.surfaceId, b.surfaceId) && sameID(a.windowId, b.windowId);
}

/** Whitelisted local process metadata only; never retain/log argv, credentials, or terminal text. */
async function readLiveContext(pid: number, system: CmuxSystem): Promise<CmuxProcessContext | undefined> {
  if (!Number.isInteger(pid) || pid <= 0) return undefined;
  const [commands, environment] = await Promise.all([
    machineWork.run(() => system.run("/usr/bin/env", ["TZ=UTC", "LC_ALL=C", "/bin/ps", "-axww", "-o", "pid=,ppid=,lstart=,comm="],
      { deadlineMs: 1_000, maxOutputBytes: 4 * 1_048_576 })),
    machineWork.run(() => system.run("/bin/ps", ["eww", "-p", String(pid), "-o", "command="],
      { deadlineMs: 1_000, maxOutputBytes: 128 * 1_024 })),
  ]);
  if (commands.status !== "success" || environment.status !== "success") return undefined;
  const processes = new Map(commands.stdout.split("\n").flatMap(line => {
    const match = /^\s*(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+[\d:]+\s+\d+)\s+(.+)$/.exec(line);
    return match ? [[Number(match[1]), { parent: Number(match[2]), started: match[3]!, command: match[4]! }] as const] : [];
  }));
  const child = processes.get(pid); if (!child) return undefined;
  let ancestor = pid; const visited = new Set<number>(); let applicationPID: number | undefined;
  while (!visited.has(ancestor)) {
    visited.add(ancestor); const row = processes.get(ancestor); if (!row) break;
    if (row.command.endsWith("/cmux.app/Contents/MacOS/cmux")) { applicationPID = ancestor; break; }
    ancestor = row.parent;
  }
  if (!applicationPID) return undefined;
  const processStartToken = processInstanceToken(pid, child.started + " UTC");
  const applicationProcessStartToken = processInstanceToken(applicationPID, processes.get(applicationPID)!.started + " UTC");
  if (!processStartToken || !applicationProcessStartToken) return undefined;
  const get = (key: string) => {
    const matches = [...environment.stdout.matchAll(new RegExp("(?:^| )" + key + "=(.*?)(?= [A-Za-z_][A-Za-z0-9_]*=|$)", "g"))];
    return matches.length === 1 ? matches[0]![1]?.trim() : undefined;
  };
  const socketPath = get("CMUX_SOCKET_PATH"), workspaceId = get("CMUX_WORKSPACE_ID"), surfaceId = get("CMUX_SURFACE_ID");
  if (!socketPath || !workspaceId || !surfaceId) return undefined;
  const data = await system.readMetadata(pid); if (!data) return undefined;
  const row = JSON.parse(data);
  if (!isRecord(row) || row.pid !== pid || row.kind !== "interactive" || row.parkedJobId !== undefined
    || !uuid(row.sessionId) || typeof row.cwd !== "string" || typeof row.procStart !== "string") return undefined;
  // Claude writes UTC ctime; ps is explicitly UTC as well. ISO offsets remain explicit.
  const started = /^\w{3} \w{3}\s+\d+ [\d:]+ \d{4}$/.test(row.procStart) ? row.procStart + " UTC" : row.procStart;
  if (Date.parse(started) !== Date.parse(child.started + " UTC")) return undefined;
  return { pid, processStartToken, applicationPID, applicationProcessStartToken, sessionId: row.sessionId,
    cwd: row.cwd, socketPath, workspaceId, surfaceId };
}

export const focusCmuxSurface = (target: CmuxSurfaceTarget, isCurrent: () => boolean) => new CmuxClient().focus(target, isCurrent);
