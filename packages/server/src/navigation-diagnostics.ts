import { AsyncLocalStorage } from "node:async_hooks";
import { createHash, randomUUID } from "node:crypto";
import { appendFile, chmod, mkdir, rename, stat } from "node:fs/promises";
import path from "node:path";
import { nativeHelperFocusFailureReasonSchema } from "@agent-visor/protocol";

type Stage = "received" | "dismissed" | "chat" | "target" | "helper_request"
  | "helper_response" | "failed" | "completed" | "superseded"
  | "cmux_focus" | "cmux_readback";
type Details = {
  targetKind?: string; pid?: number; home?: string; requestId?: string;
  method?: string; outcome?: string; reason?: string; systemCode?: number;
  windowId?: unknown; workspaceId?: unknown; surfaceId?: unknown;
  focusedWindowId?: unknown; focusedWorkspaceId?: unknown; focusedSurfaceId?: unknown;
  attempt?: number; identityMatch?: boolean; scope?: "ambient" | "window";
};
type Recorder = (stage: Stage, details?: Details) => void;
const context = new AsyncLocalStorage<Recorder>();
const targetKinds = new Set(["url", "cursor_workspace", "codex_thread", "claude_background", "terminal", "application", "cmux_surface"]);
const methods = new Set(["focus", "open_codex_thread", "focus_terminal", "open_claude_attach", "focus_ghostty_terminal"]);
const outcomes = new Set(["accepted", "failed", "timeout", "connection_closed", "invalid_response"]);
const fingerprint = (value: string) => createHash("sha256").update(value).digest("hex").slice(0, 16);
const identityHashes = (details: Details) => Object.fromEntries([
  ["windowId", "windowHash"], ["workspaceId", "workspaceHash"], ["surfaceId", "surfaceHash"],
  ["focusedWindowId", "focusedWindowHash"], ["focusedWorkspaceId", "focusedWorkspaceHash"], ["focusedSurfaceId", "focusedSurfaceHash"],
].flatMap(([key, output]) => {
  const value = details[key as keyof Details];
  return typeof value === "string" && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value)
    ? [[output, fingerprint(value.toLowerCase())]] : [];
}));

/** Capture at request creation: socket callbacks do not inherit a click's async context. */
export function navigationRecorder(method?: string): Recorder {
  return method !== undefined && !methods.has(method) ? () => {} : context.getStore() ?? (() => {});
}
export function navigationStep(stage: Stage, details?: Details): void { navigationRecorder()(stage, details); }

/** Local, bounded, allowlisted traces. No titles, prompts, paths, argv, or free-form errors. */
export class NavigationDiagnostics {
  private writes = Promise.resolve();
  private queued = 0;

  constructor(private readonly dataRoot: string) {}

  run<T>(sessionId: string, intent: "standard" | "chat" | "dismiss", action: () => Promise<T>, origin: "pill" | "sessions" = "pill"): Promise<T> {
    const clickId = randomUUID();
    const started = performance.now();
    const sessionHash = fingerprint(sessionId);
    const record: Recorder = (stage, details = {}) => {
      const safe = {
        observedAt: new Date().toISOString(), clickId, sessionHash, intent, origin, stage,
        elapsedMs: Math.round(performance.now() - started),
        ...(targetKinds.has(details.targetKind ?? "") ? { targetKind: details.targetKind } : {}),
        ...(Number.isInteger(details.pid) && details.pid! > 0 && details.pid! <= 2_147_483_647 ? { pid: details.pid } : {}),
        ...(typeof details.home === "string" ? { homeHash: fingerprint(details.home) } : {}),
        ...(typeof details.requestId === "string" && /^[0-9a-f-]{36}$/i.test(details.requestId) ? { requestId: details.requestId } : {}),
        ...(methods.has(details.method ?? "") ? { method: details.method } : {}),
        ...(outcomes.has(details.outcome ?? "") ? { outcome: details.outcome } : {}),
        ...(nativeHelperFocusFailureReasonSchema.safeParse(details.reason).success ? { reason: details.reason } : {}),
        ...(Number.isInteger(details.systemCode) && Math.abs(details.systemCode!) <= 2_147_483_648 ? { systemCode: details.systemCode } : {}),
        ...identityHashes(details),
        ...(Number.isInteger(details.attempt) && details.attempt! >= 1 && details.attempt! <= 4 ? { attempt: details.attempt } : {}),
        ...(typeof details.identityMatch === "boolean" ? { identityMatch: details.identityMatch } : {}),
        ...(["ambient", "window"].includes(details.scope ?? "") ? { scope: details.scope } : {}),
      };
      this.append(JSON.stringify(safe) + "\n");
    };
    return context.run(record, async () => {
      record("received");
      try { return await action(); }
      catch (error) { record("failed"); throw error; }
    });
  }

  async flush(): Promise<void> { await this.writes; }

  private append(line: string): void {
    // Discovery never logs here. A burst of clicks cannot create an unbounded write queue.
    if (this.queued >= 128) return;
    this.queued++;
    this.writes = this.writes.then(async () => {
      const directory = path.join(this.dataRoot, "diagnostics");
      const file = path.join(directory, "pill-navigation.jsonl");
      await mkdir(directory, { recursive: true, mode: 0o700 });
      let bytes = 0;
      try { bytes = (await stat(file)).size; } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
      if (bytes + Buffer.byteLength(line) > 262_144) await rename(file, file + ".previous");
      await appendFile(file, line, { mode: 0o600 });
      await chmod(file, 0o600);
    }).catch(() => {
      // A logging failure must not reject or retry the user's navigation.
    }).finally(() => { this.queued--; });
  }
}
