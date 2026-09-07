import { spawn, type ChildProcess } from "node:child_process";
import { access, appendFile, mkdir, rename, stat } from "node:fs/promises";
import { constants } from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import os from "node:os";
import type {
  ChatPendingAction,
  ChatSettings,
  ChatSettingsPatch,
  ClientMessage,
} from "@agent-visor/protocol";
import { agentVisorVersion } from "./runtime-version.js";

export type CodexActionRegistrar = (
  sessionId: string,
  pending: ChatPendingAction,
  respond: (message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void>,
  generation?: number,
) => () => void;

export type CodexTurnSettings = ChatSettingsPatch;
export type CodexSettingsCatalog = Pick<ChatSettings, "models" | "permissionProfiles">;

/**
 * The provider's JSON-RPC id is only unique within one app-server process.
 * Keep approval routing tied to every non-sensitive owner coordinate instead
 * of exposing that id (or any prompt content) to the renderer. The process
 * instance id is generated once per app-server child and prevents two
 * concurrent children from colliding when they reuse the same JSON-RPC ids.
 */
export type CodexApprovalOwner = {
  sessionId: string;
  threadId: string;
  turnId?: string;
  deliveryId: string;
  requestId?: string;
  generation?: number;
  appServerRequestId: string | number;
  appServerInstanceId: string;
};

export function codexApprovalId(owner: CodexApprovalOwner): string {
  const ownerIdentity = JSON.stringify([
    ["session", owner.sessionId],
    ["thread", owner.threadId],
    ["turn", owner.turnId],
    ["delivery", owner.deliveryId],
    ["request", owner.requestId ?? null],
    ["generation", owner.generation ?? null],
    ["rpc", owner.appServerRequestId],
    ["process", owner.appServerInstanceId],
  ]);
  return `codex-approval-${createHash("sha256").update(ownerIdentity, "utf8").digest("hex")}`;
}

type ActiveTurn = {
  stop(error?: Error): void;
  interrupt(): Promise<boolean>;
};

const activeTurns = new Set<ActiveTurn>();
const activeTurnsByIdentity = new Map<string, Set<ActiveTurn>>();
const activeDeliveryIDsByThread = new Map<string, Set<string>>();
/**
 * A child exit after turn/start acceptance leaves the provider outcome
 * uncertain. Retain the exact native turn identity briefly for diagnostics
 * and read-only state projection, while never exposing it as cancellable.
 */
const uncertainCodexTurnByThread = new Map<string, {
  turnId?: string;
  deliveryId?: string;
  expiresAt: number;
}>();
const uncertainCodexTurnTtlMs = 5 * 60_000;
const recentCodexTerminalByThread = new Map<string, {
  turnId: string;
  outcome: Extract<CodexTurnOutcome, "completed" | "failed" | "interrupted">;
  expiresAt: number;
}>();
const codexTerminalTtlMs = 5 * 60_000;
const maxCodexTerminals = 64;
const recentCodexTurnIdentityByThread = new Map<string, Map<string, {
  deliveryId?: string;
  requestId?: string;
  expiresAt: number;
}>>();
const codexTurnIdentityTtlMs = 5 * 60_000;
const maxRecentCodexTurnIdentities = 64;
const codexRouteEventListeners = new Set<(event: CodexRouteEvent) => void>();
const codexRouteDiagnosticsLog: CodexRouteDiagnostic[] = [];
const maxCodexRouteDiagnostics = 256;
const codexRouteDiagnosticsDirectory = process.env.AGENT_VISOR_DATA_DIR?.trim();
const codexRouteDiagnosticsFile = codexRouteDiagnosticsDirectory
  ? `${codexRouteDiagnosticsDirectory}/codex-route-diagnostics.jsonl`
  : undefined;
const codexRouteDiagnosticsBackup = codexRouteDiagnosticsFile
  ? `${codexRouteDiagnosticsFile}.1`
  : undefined;
const maxCodexRouteDiagnosticsBytes = 256 * 1_024;
let codexRouteDiagnosticsBytes = 0;
let codexRouteDiagnosticsWrite = Promise.resolve();

export type CodexRouteProbe = {
  routeState: "available" | "unavailable";
  unavailableReason?: "owner_only" | "provider_unavailable";
  routeOwnership?: "owned" | "unverified" | "external";
  /** The previous route child is still closing; do not acquire a contender. */
  releasePending?: true;
  /** Provider-owned state observed while opening or on this route. */
  turnState?: "working" | "ready" | "unknown";
  turnId?: string;
  /** A terminal notification was confirmed after the route child closed. */
  confirmedTerminal?: true;
};

export type CodexRouteRecoveryResult = {
  recovered: boolean;
  probe: CodexRouteProbe;
  reason?: "release_pending" | "identity_unavailable" | "identity_mismatch";
};

export type CodexRouteRelinquishResult = "not_owned" | "released" | "blocked";

/**
 * Redacted native lifecycle evidence. Provider content is deliberately not
 * carried across this seam; the rollout reader remains the source of truth
 * for rendered text and the exact item ID is the only delivery correlation.
 */
export type CodexRouteEvent =
  | {
    type: "turn_started";
    threadId: string;
    turnId: string;
    deliveryId?: string;
  }
  | {
    type: "turn_completed";
    threadId: string;
    turnId: string;
    outcome: "completed" | "failed" | "interrupted" | "unknown";
    deliveryId?: string;
  }
  | {
    type: "item_started" | "item_completed";
    threadId: string;
    turnId: string;
    itemId: string;
    itemType?: string;
    deliveryId?: string;
    requestId?: string;
  }
  | {
    type: "agent_message_delta";
    threadId: string;
    turnId: string;
    itemId: string;
    deltaLength: number;
    deliveryId?: string;
  };

export type CodexRouteDiagnostic = {
  at: string;
  type:
    | "route_opening"
    | "route_opened"
    | "route_owner_rejected"
    | "route_failed"
    | "turn_admitted"
    | "turn_accepted"
    | "turn_failed"
    | "native_event"
    | "route_release_requested"
    | "route_release_confirmed";
  threadId: string;
  turnId?: string;
  deliveryId?: string;
  itemId?: string;
  eventType?: CodexRouteEvent["type"];
  outcome?: "completed" | "failed" | "interrupted" | "unknown";
  reason?: "owner_only" | "provider_unavailable" | "transport";
};

export function subscribeCodexRouteEvents(
  listener: (event: CodexRouteEvent) => void,
): () => void {
  codexRouteEventListeners.add(listener);
  return () => codexRouteEventListeners.delete(listener);
}

/** Return only bounded, redacted native route metadata for local diagnostics. */
export function codexRouteDiagnostics(): CodexRouteDiagnostic[] {
  return codexRouteDiagnosticsLog.map((entry) => ({ ...entry }));
}

function emitCodexRouteEvent(event: CodexRouteEvent): void {
  // Delta notifications can arrive once per token. Keep them on the event
  // subscription for refresh coalescing, but omit them from the retained
  // diagnostics ring so a long answer cannot evict route/turn/item evidence.
  if (event.type !== "agent_message_delta") {
    recordCodexRouteDiagnostic({
      type: "native_event",
      threadId: event.threadId,
      ...(event.turnId ? { turnId: event.turnId } : {}),
      ...(event.deliveryId ? { deliveryId: event.deliveryId } : {}),
      ...(typeof event === "object" && "itemId" in event && event.itemId
        ? { itemId: event.itemId } : {}),
      eventType: event.type,
      ...(event.type === "turn_completed" ? { outcome: event.outcome } : {}),
    });
  }
  for (const listener of codexRouteEventListeners) listener(event);
}

function recordCodexRouteDiagnostic(
  entry: Omit<CodexRouteDiagnostic, "at">,
): void {
  const diagnostic = { at: new Date().toISOString(), ...entry };
  codexRouteDiagnosticsLog.push(diagnostic);
  while (codexRouteDiagnosticsLog.length > maxCodexRouteDiagnostics) {
    codexRouteDiagnosticsLog.shift();
  }
  if (!codexRouteDiagnosticsFile || !codexRouteDiagnosticsBackup) return;
  const line = `${JSON.stringify(diagnostic)}\n`;
  // Keep this sink best-effort and serialized. A filesystem failure must
  // never affect provider delivery or expose a prompt/tool payload.
  codexRouteDiagnosticsWrite = codexRouteDiagnosticsWrite.then(async () => {
    await mkdir(codexRouteDiagnosticsDirectory!, { recursive: true });
    if (codexRouteDiagnosticsBytes === 0) {
      codexRouteDiagnosticsBytes = await stat(codexRouteDiagnosticsFile)
        .then((value) => value.size)
        .catch(() => 0);
    }
    if (codexRouteDiagnosticsBytes + Buffer.byteLength(line, "utf8") > maxCodexRouteDiagnosticsBytes) {
      try {
        await rename(codexRouteDiagnosticsFile, codexRouteDiagnosticsBackup);
      } catch (error) {
        // A missing source is safe to recreate. Other rotation failures must
        // abort this best-effort append so the active file never grows past
        // its advertised cap.
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") return;
      }
      codexRouteDiagnosticsBytes = 0;
    }
    await appendFile(codexRouteDiagnosticsFile, line, { encoding: "utf8", mode: 0o600 });
    codexRouteDiagnosticsBytes += Buffer.byteLength(line, "utf8");
  }).catch(() => {
    // Diagnostics are advisory; leave the delivery path untouched.
  });
}

/**
 * Optional durable thread context used when the exact provider row is opened.
 * Omitting a field preserves the configuration already stored by Codex.
 */
export type CodexRouteContext = {
  cwd?: string;
};

type RouteTurn = {
  deliveryId?: string;
  requestId?: string;
  generation?: number;
  registerAction?: CodexActionRegistrar;
  turnId?: string;
  completedTurnIds: Set<string>;
  accepted: boolean;
  cancelRequested: boolean;
  registeredIdentity: boolean;
  startSettled: boolean;
  /** Admission guard used only before turn/start is written. */
  isAdmissionCurrent: () => boolean;
  activeTurn: ActiveTurn;
  unregisters: Map<string, () => void>;
  pendingActions: Map<string, CodexRPCMessage>;
  /** Native lifecycle messages received before authoritative turn/start ack. */
  preAckNativeEvents: CodexRPCMessage[];
};

type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

type CodexRPCMessage = Record<string, unknown>;

const codexRPCRequestTimeoutMs = 10_000;
const codexMaxPartialFrameBytes = 8 * 1024 * 1024;
const maxCodexRoutes = 64;

/** One long-lived provider connection owns one exact thread at a time. */
class CodexRouteConnection {
  readonly instanceId = randomUUID();
  private child: ChildProcess | undefined;
  private buffer = "";
  private nextRequestId = 1;
  private closed = false;
  private readonly pending = new Map<string, PendingRequest>();
  private readonly listeners = new Set<(message: CodexRPCMessage) => void>();
  private readonly closeListeners = new Set<(error?: Error) => void>();
  private childExitPromise: Promise<void> | undefined;
  private childExitResolve: (() => void) | undefined;

  constructor(
    readonly threadId: string,
    private readonly executable: string,
  ) {}

  onMessage(listener: (message: CodexRPCMessage) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  onClose(listener: (error?: Error) => void): () => void {
    this.closeListeners.add(listener);
    return () => this.closeListeners.delete(listener);
  }

  async open(context?: CodexRouteContext): Promise<CodexRouteResumeState> {
    if (this.child || this.closed) throw new Error("The Codex route is closed.");
    const child = spawn(this.executable, ["app-server", "--listen", "stdio://"], {
      detached: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child = child;
    this.childExitPromise = new Promise<void>((resolve) => {
      this.childExitResolve = resolve;
    });
    child.once("error", (error) => this.fail(error));
    child.once("close", (code, signal) => {
      this.childExitResolve?.();
      this.childExitResolve = undefined;
      if (!this.closed) this.fail(new Error(
        `Codex app-server exited with status ${code ?? signal ?? "unknown"}.`,
      ));
    });
    child.stdin?.on("error", (error) => this.fail(error));
    child.stdout?.on("error", (error) => this.fail(error));
    // Stderr is diagnostic output, not part of the JSON-RPC stream. Drain it
    // without making a valid long-lived route expire because the provider has
    // been verbose over its lifetime.
    child.stderr?.resume();
    child.stdout?.on("data", (chunk: Buffer) => this.ingest(chunk));

    await this.request("initialize", {
      clientInfo: { name: "agent-visor", version: agentVisorVersion() },
      capabilities: { experimentalApi: true },
    });
    this.write({ method: "initialized" });
    const result = await this.request("thread/resume", {
      threadId: this.threadId,
      // Resume metadata is enough to establish route ownership. Avoid
      // hydrating the complete persisted transcript on every Chat open.
      excludeTurns: true,
      ...(context?.cwd ? { cwd: context.cwd } : {}),
    });
    const resumed = codexRouteResumeState(result);
    if (resumed.threadId !== this.threadId) {
      throw new Error("Codex resumed a different thread than requested.");
    }
    return resumed;
  }

  request(method: string, params?: unknown): Promise<unknown> {
    if (this.closed) return Promise.reject(new Error("The Codex route is unavailable."));
    const id = this.nextRequestId++;
    const key = String(id);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(key);
        reject(new Error(`Codex ${method} timed out.`));
      }, codexRPCRequestTimeoutMs);
      timer.unref?.();
      this.pending.set(key, { resolve, reject, timer });
      try {
        this.write({ id, method, ...(params === undefined ? {} : { params }) });
      } catch (error) {
        this.pending.delete(key);
        clearTimeout(timer);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  respond(message: unknown): void {
    this.write(message);
  }

  close(error?: Error): void {
    this.fail(error);
  }

  async waitForExit(timeoutMs = 2_000): Promise<boolean> {
    const exit = this.childExitPromise;
    if (!exit) return true;
    let timedOut = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([
      exit,
      new Promise<void>((resolve) => {
        timer = setTimeout(() => {
          timedOut = true;
          resolve();
        }, timeoutMs);
        timer.unref?.();
      }),
    ]);
    if (timer) clearTimeout(timer);
    return !timedOut;
  }

  waitForExitConfirmed(): Promise<void> {
    return this.childExitPromise ?? Promise.resolve();
  }

  private ingest(chunk: Buffer): void {
    if (this.closed) return;
    this.buffer += chunk.toString("utf8");
    while (this.buffer.includes("\n")) {
      const newline = this.buffer.indexOf("\n");
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      let message: CodexRPCMessage;
      try { message = JSON.parse(line) as CodexRPCMessage; } catch { continue; }
      // Provider requests such as approval prompts carry both an id and a
      // method. Deliver those to the route first; only response messages
      // should settle an outstanding request.
      if (typeof message.method === "string") {
        for (const listener of this.listeners) listener(message);
      }
      const responseID = codexRPCID(message.id);
      if (responseID === undefined || typeof message.method === "string") continue;
      const pending = this.pending.get(String(responseID));
      if (!pending) continue;
      this.pending.delete(String(responseID));
      clearTimeout(pending.timer);
      if (message.error !== undefined) pending.reject(new Error(codexError(message.error)));
      else pending.resolve(message.result);
    }
    // A missing newline must not retain an unbounded provider payload. A
    // single oversized JSON-RPC frame is a protocol failure; ordinary output
    // remains bounded by the line buffer rather than a lifetime byte counter.
    if (Buffer.byteLength(this.buffer, "utf8") > codexMaxPartialFrameBytes) {
      this.fail(new Error("Codex app-server returned an oversized message."));
    }
  }

  private write(message: unknown): void {
    if (this.closed || !this.child?.stdin || this.child.stdin.destroyed) {
      throw new Error("The Codex route is unavailable.");
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  private fail(error?: Error): void {
    if (this.closed) return;
    this.closed = true;
    const reason = error ?? new Error("The Codex route is unavailable.");
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(reason);
    }
    this.pending.clear();
    const child = this.child;
    child?.stdin?.destroy();
    child?.stdout?.destroy();
    if (child) stop(child);
    for (const listener of this.closeListeners) listener(reason);
    this.closeListeners.clear();
    this.listeners.clear();
  }
}

type CodexRouteResumeState = {
  threadId: string;
  turnState: "working" | "ready" | "unknown";
  turnId?: string;
};

class CodexRoute {
  private active: RouteTurn | undefined;
  private closed = false;
  private resumedTurnState: CodexRouteResumeState["turnState"] = "unknown";
  private resumedTurnId: string | undefined;

  constructor(
    readonly threadId: string,
    private readonly connection: CodexRouteConnection,
    private readonly onIdle: () => void,
    private readonly onClosed: (error?: Error) => void,
  ) {
    connection.onMessage((message) => this.handleMessage(message));
    connection.onClose((error) => {
      this.closed = true;
      const active = this.active;
      if (active) {
        if (!active.completedTurnIds.size || (active.turnId && !active.completedTurnIds.has(active.turnId))) {
          rememberUncertainCodexTurn(this.threadId, active.turnId, active.deliveryId);
        }
        this.finish(active, error ?? new Error("The Codex route closed."));
      }
      this.onClosed(error);
    });
  }

  async open(context?: CodexRouteContext): Promise<CodexRouteProbe> {
    recordCodexRouteDiagnostic({ type: "route_opening", threadId: this.threadId });
    const resumed = await this.connection.open(context);
    this.resumedTurnState = resumed.turnState;
    this.resumedTurnId = resumed.turnId;
    recordCodexRouteDiagnostic({
      type: "route_opened",
      threadId: this.threadId,
      ...(resumed.turnId ? { turnId: resumed.turnId } : {}),
    });
    return this.probe();
  }

  hasActiveTurn(): boolean {
    return this.active !== undefined || this.resumedTurnState === "working";
  }

  probe(): CodexRouteProbe {
    if (this.closed) {
      return { routeState: "unavailable", unavailableReason: "provider_unavailable" };
    }
    const turnId = this.active?.turnId ?? this.resumedTurnId;
    return {
      routeState: "available",
      routeOwnership: "owned",
      turnState: this.active ? "working" : this.resumedTurnState,
      ...(turnId ? { turnId } : {}),
    };
  }

  async startTurn(options: {
    text: string;
    imagePaths: string[];
    registerAction?: CodexActionRegistrar;
    deliveryId?: string;
    requestId?: string;
    generation?: number;
    settings?: CodexTurnSettings;
    isCurrent: () => boolean;
  }): Promise<void> {
    // No verified typeahead/steering operation exists in the provider
    // protocol. A second send remains a renderer draft instead of waiting
    // here and becoming an unexpected competing turn.
    if (this.active) {
      throw new Error("Codex turn is still in progress. Wait for this turn to finish before sending.");
    }
    if (this.closed) throw new Error("The Codex route is unavailable.");
    if (this.resumedTurnState === "working") {
      throw new Error("Codex turn is still in progress. Wait for this turn to finish before sending.");
    }
    if (!options.isCurrent()) throw new Error("The chat send is no longer current.");
    const context = {
      completedTurnIds: new Set<string>(),
      accepted: false,
      cancelRequested: false,
      registeredIdentity: false,
      startSettled: false,
      isAdmissionCurrent: options.isCurrent,
      pendingActions: new Map<string, CodexRPCMessage>(),
      unregisters: new Map<string, () => void>(),
      preAckNativeEvents: [],
      activeTurn: undefined as unknown as ActiveTurn,
    } as RouteTurn;
    const activeTurn: ActiveTurn = {
      stop: (error) => {
        this.finish(context, error ?? new Error("Codex message delivery stopped."));
        this.connection.close(error);
      },
      interrupt: async () => {
        if (context.cancelRequested || !context.turnId || this.closed) return false;
        context.cancelRequested = true;
        // The app-server schema requires the exact thread and turn IDs. A
        // failed interrupt closes the route so a caller cannot claim a stop
        // succeeded while the provider may still own an unknown turn.
        try {
          await this.connection.request("turn/interrupt", {
            threadId: this.threadId,
            turnId: context.turnId,
          });
          return true;
        } catch (error) {
          const failure = error instanceof Error ? error : new Error(String(error));
          this.close(failure);
          throw failure;
        }
      },
    };
    Object.assign(context, {
      deliveryId: options.deliveryId,
      requestId: options.requestId,
      generation: options.generation,
      registerAction: options.registerAction,
      accepted: false,
      cancelRequested: false,
      registeredIdentity: false,
      activeTurn,
    });
    this.active = context;
    recordCodexRouteDiagnostic({
      type: "turn_admitted",
      threadId: this.threadId,
      ...(options.deliveryId ? { deliveryId: options.deliveryId } : {}),
    });
    try {
      // Keep this check immediately adjacent to the provider write. The
      // repository currentness callback can change while the route resumes.
      if (!context.isAdmissionCurrent()) throw new Error("The chat send is no longer current.");
      const result = await this.connection.request("turn/start", {
        threadId: this.threadId,
        ...(options.settings?.modelId ? { model: options.settings.modelId } : {}),
        ...(options.settings?.reasoningEffort ? { effort: options.settings.reasoningEffort } : {}),
        ...(options.settings?.permissionProfile ? { permissions: options.settings.permissionProfile } : {}),
        input: [
          ...(options.text ? [{ type: "text", text: options.text }] : []),
          ...options.imagePaths.map((path) => ({ type: "localImage", path })),
        ],
      });
      const responseTurnId = codexTurnID(result);
      if (responseTurnId && context.turnId && responseTurnId !== context.turnId) {
        throw new Error("Codex turn/start returned a different turn ID than its started event.");
      }
      context.turnId = context.turnId ?? responseTurnId;
      if (!context.turnId) throw new Error("Codex did not return a concrete turn ID.");
      context.accepted = true;
      context.startSettled = true;
      rememberCodexTurnIdentity(this.threadId, context.turnId, context);
      this.flushPreAckNativeEvents(context);
      recordCodexRouteDiagnostic({
        type: "turn_accepted",
        threadId: this.threadId,
        turnId: context.turnId,
        ...(context.deliveryId ? { deliveryId: context.deliveryId } : {}),
      });
      if (context.completedTurnIds.has(context.turnId)) {
        if (this.active === context) this.finish(context);
        else this.onIdle();
      } else if (this.active === context) {
        this.registerActiveIdentity(context);
        this.flushPendingActions(context);
      } else {
        // A matching completion can arrive before the turn/start response.
        // The provider has already finished this turn; do not resurrect Stop
        // authority after the response settles.
        this.onIdle();
      }
    } catch (error) {
      const originalError = error instanceof Error ? error : new Error(String(error));
      const failure = isCodexOwnerConflict(originalError)
        ? codexOwnerOnlyError()
        : originalError;
      // A turn/start timeout has an uncertain provider outcome. Close this
      // connection so it cannot be reused or advertised as ready while the
      // provider may still be executing the turn.
      if (/Codex turn\/start timed out\./.test(originalError.message)) {
        this.connection.close(originalError);
      }
      context.startSettled = true;
      recordCodexRouteDiagnostic({
        type: "turn_failed",
        threadId: this.threadId,
        ...(context.turnId ? { turnId: context.turnId } : {}),
        ...(context.deliveryId ? { deliveryId: context.deliveryId } : {}),
        reason: isCodexOwnerConflict(originalError)
          ? "owner_only" : "transport",
      });
      this.finish(context, failure);
      throw failure;
    }
  }

  close(error?: Error): void {
    if (this.closed) return;
    this.closed = true;
    const active = this.active;
    if (active) this.finish(active, error);
    this.connection.close(error);
  }

  waitForExit(timeoutMs = 2_000): Promise<boolean> {
    return this.connection.waitForExit(timeoutMs);
  }

  waitForExitConfirmed(): Promise<void> {
    return this.connection.waitForExitConfirmed();
  }

  private handleMessage(message: CodexRPCMessage): void {
    const method = typeof message.method === "string" ? message.method : undefined;
    if (!method) return;
    const context = this.active;
    if (method === "turn/started") {
      if (codexThreadID(message.params) !== this.threadId) return;
      const startedTurnId = codexTurnID(message.params);
      if (!startedTurnId) return;
      if (context && !context.startSettled && !context.turnId) {
        this.queuePreAckNativeEvent(context, message);
        return;
      }
      if (context?.turnId && context.turnId !== startedTurnId) return;
      this.resumedTurnState = "working";
      this.resumedTurnId = startedTurnId;
      if (context) {
        context.turnId = startedTurnId;
        rememberCodexTurnIdentity(this.threadId, startedTurnId, context);
        if (context.completedTurnIds.has(startedTurnId)) this.finish(context);
        else this.registerActiveIdentity(context);
        this.flushPendingActions(context);
      }
      emitCodexRouteEvent({
        type: "turn_started",
        threadId: this.threadId,
        turnId: startedTurnId,
        ...(context?.deliveryId ? { deliveryId: context.deliveryId } : {}),
      });
      return;
    }
    if (method === "turn/completed") {
      if (codexThreadID(message.params) !== this.threadId) return;
      const completedTurnId = codexTurnID(message.params);
      // Both identities are required. Missing or stale notifications must
      // never release the current turn's Stop/send authority.
      if (!completedTurnId) return;
      if (context && !context.startSettled && !context.turnId) {
        this.queuePreAckNativeEvent(context, message);
        return;
      }
      if (context?.turnId && context.turnId !== completedTurnId) return;
      if (!context && this.resumedTurnId !== completedTurnId) return;
      const outcome = codexTurnOutcome(message.params);
      clearUncertainCodexTurn(this.threadId, completedTurnId);
      if (outcome !== "unknown") rememberCodexTerminal(this.threadId, completedTurnId, outcome);
      if (context) {
        rememberCodexTurnIdentity(this.threadId, completedTurnId, context);
        context.completedTurnIds.add(completedTurnId);
        if (context.turnId && completedTurnId === context.turnId) this.finish(context);
      } else if (this.resumedTurnId === completedTurnId) {
        this.resumedTurnState = "ready";
        this.resumedTurnId = undefined;
        this.onIdle();
      }
      emitCodexRouteEvent({
        type: "turn_completed",
        threadId: this.threadId,
        turnId: completedTurnId,
        outcome,
        ...(context?.deliveryId ? { deliveryId: context.deliveryId } : {}),
      });
      return;
    }
    if (method === "thread/status/changed") {
      if (codexThreadID(message.params) !== this.threadId) return;
      const state = codexThreadStatus(message.params);
      if (!state) return;
      this.resumedTurnState = state;
      if (state !== "working" && !this.active) this.resumedTurnId = undefined;
      return;
    }
    if (method === "item/started" || method === "item/completed") {
      if (context && !context.startSettled && !context.turnId) {
        this.queuePreAckNativeEvent(context, message);
        return;
      }
      const event = codexItemLifecycleEvent(method, message.params, context, this.threadId);
      if (event) emitCodexRouteEvent(event);
      return;
    }
    if (method === "item/agentMessage/delta") {
      if (context && !context.startSettled && !context.turnId) {
        this.queuePreAckNativeEvent(context, message);
        return;
      }
      const event = codexAgentMessageDeltaEvent(message.params, context, this.threadId);
      if (event) emitCodexRouteEvent(event);
      return;
    }
    if (!context) return;
    const requestID = codexRPCID(message.id);
    if (requestID === undefined) return;
    const pending = codexPendingAction(method, message.params);
    if (!pending) {
      this.respondToProvider({ id: message.id, error: { code: -32601, message: "Unsupported Codex request." } });
      return;
    }
    const requestKey = String(requestID);
    if (context.unregisters.has(requestKey) || context.pendingActions.has(requestKey)) {
      this.respondToProvider({ id: message.id, error: { code: -32000, message: "This Codex approval request is already pending." } });
      return;
    }
    if (!context.turnId || !context.deliveryId || !context.registerAction) {
      // A provider may ask for approval before the turn/start response. Keep
      // the exact request envelope until the started event or response gives
      // us a complete owner identity; notifications without an RPC id never
      // enter this map.
      if (!context.startSettled) {
        context.pendingActions.set(requestKey, message);
        return;
      }
      this.respondToProvider({ id: message.id, error: { code: -32000, message: "This Codex approval has no complete owner identity." } });
      return;
    }
    this.registerPendingAction(context, message);
  }

  private flushPendingActions(context: RouteTurn): void {
    if (!context.turnId || !context.deliveryId || !context.registerAction) return;
    for (const message of context.pendingActions.values()) this.registerPendingAction(context, message);
    context.pendingActions.clear();
  }

  private queuePreAckNativeEvent(context: RouteTurn, message: CodexRPCMessage): void {
    // A provider can emit a stale same-thread notification while turn/start is
    // still awaiting its authoritative response. Keep only a small metadata
    // envelope until that response supplies the exact turn ID; stale IDs are
    // discarded by replay rather than binding the delivery early. Deltas are
    // expendable before acknowledgement: the rollout/file revision will
    // trigger a later content refresh and must not evict a user identity.
    const priority = preAckNativeEventPriority(message);
    if (priority === 0) return;
    if (context.preAckNativeEvents.length >= 64) {
      const evict = context.preAckNativeEvents.findIndex((candidate) =>
        preAckNativeEventPriority(candidate) < priority);
      if (evict < 0) return;
      context.preAckNativeEvents.splice(evict, 1);
    }
    context.preAckNativeEvents.push(message);
  }

  private flushPreAckNativeEvents(context: RouteTurn): void {
    const pending = context.preAckNativeEvents.splice(0);
    for (const message of pending) this.handleMessage(message);
  }

  private registerPendingAction(context: RouteTurn, message: CodexRPCMessage): void {
    if (!context.turnId || !context.deliveryId || !context.registerAction) return;
    const requestID = codexRPCID(message.id);
    const method = typeof message.method === "string" ? message.method : undefined;
    if (requestID === undefined || !method) return;
    const requestKey = String(requestID);
    const pending = codexPendingAction(method, message.params);
    if (!pending) return;
    const approvalId = codexApprovalId({
      sessionId: this.threadId,
      threadId: this.threadId,
      turnId: context.turnId,
      deliveryId: context.deliveryId,
      ...(context.requestId ? { requestId: context.requestId } : {}),
      ...(context.generation !== undefined ? { generation: context.generation } : {}),
      appServerRequestId: requestID,
      appServerInstanceId: this.connection.instanceId,
    });
    let unregister: () => void = () => undefined;
    const respond = async (response: Extract<ClientMessage, { type: "respond_chat" }>): Promise<void> => {
      if (this.active !== context || context.unregisters.get(requestKey) !== unregister) {
        throw new Error("This Codex approval is no longer pending.");
      }
      // Do not unregister until the exact provider response has been written.
      // A JSON-RPC error or closed route must remain observable to the caller.
      this.connection.respond(codexResponseFor(message.id!, method, message.params, response));
      unregister();
      context.unregisters.delete(requestKey);
    };
    unregister = context.registerAction(
      this.threadId,
      { ...pending, approvalId },
      respond,
      context.generation,
    );
    context.unregisters.set(requestKey, unregister);
  }

  private respondToProvider(response: unknown): void {
    try {
      this.connection.respond(response);
    } catch (error) {
      this.close(error instanceof Error ? error : new Error(String(error)));
    }
  }

  private registerActiveIdentity(context: RouteTurn): void {
    if (context.registeredIdentity || !context.turnId || !context.deliveryId) return;
    const key = activeTurnKey(this.threadId, context.deliveryId);
    let turns = activeTurnsByIdentity.get(key);
    if (!turns) {
      turns = new Set();
      activeTurnsByIdentity.set(key, turns);
    }
    turns.add(context.activeTurn);
    let deliveryIDs = activeDeliveryIDsByThread.get(this.threadId);
    if (!deliveryIDs) {
      deliveryIDs = new Set();
      activeDeliveryIDsByThread.set(this.threadId, deliveryIDs);
    }
    deliveryIDs.add(context.deliveryId);
    activeTurns.add(context.activeTurn);
    context.registeredIdentity = true;
  }

  private finish(context: RouteTurn, _error?: Error): void {
    if (this.active !== context) return;
    this.active = undefined;
    activeTurns.delete(context.activeTurn);
    if (context.registeredIdentity && context.deliveryId) {
      const key = activeTurnKey(this.threadId, context.deliveryId);
      const turns = activeTurnsByIdentity.get(key);
      turns?.delete(context.activeTurn);
      if (turns?.size === 0) {
        activeTurnsByIdentity.delete(key);
        const deliveryIDs = activeDeliveryIDsByThread.get(this.threadId);
        deliveryIDs?.delete(context.deliveryId);
        if (deliveryIDs?.size === 0) activeDeliveryIDsByThread.delete(this.threadId);
      }
    }
    for (const unregister of context.unregisters.values()) unregister();
    context.unregisters.clear();
    context.pendingActions.clear();
    context.preAckNativeEvents.length = 0;
    if (!this.closed) {
      this.resumedTurnState = "ready";
      this.resumedTurnId = undefined;
    }
    if (context.startSettled) this.onIdle();
  }
}

type CodexRouteEntry = {
  route?: CodexRoute;
  references: number;
  opening: Promise<CodexRouteProbe>;
  context?: CodexRouteContext;
  ready: boolean;
  closing?: boolean;
  closingPromise?: Promise<void>;
  releasePending?: true;
};

const codexRoutes = new Map<string, CodexRouteEntry>();
const codexRouteCloseTimeoutMs = 2_000;

export async function acquireCodexRoute(
  threadId: string,
  retain = false,
  context?: CodexRouteContext,
): Promise<CodexRouteProbe> {
  let entry = codexRoutes.get(threadId);
  // A child exit after a turn/start write has no completion evidence. Do not
  // silently resume the same conversation and risk a duplicate turn; an
  // explicit retry/focus path must first establish a fresh provider outcome.
  if (!entry && uncertainCodexTurn(threadId)) return uncertainCodexRouteProbe(threadId);
  if (entry?.closingPromise || entry?.releasePending) {
    const confirmed = await waitForCodexRouteClose(entry);
    if (!confirmed) return codexRouteClosingProbe(threadId);
    if (codexRoutes.get(threadId) === entry) codexRoutes.delete(threadId);
    entry = undefined;
  }
  if (!entry && uncertainCodexTurn(threadId)) return uncertainCodexRouteProbe(threadId);
  if (!entry) {
    if (codexRoutes.size >= maxCodexRoutes) {
      return { routeState: "unavailable", unavailableReason: "provider_unavailable" };
    }
    entry = {
      references: retain ? 1 : 0,
      opening: Promise.resolve({ routeState: "unavailable" as const, unavailableReason: "provider_unavailable" as const }),
      ready: false,
      ...(context ? { context } : {}),
    };
    // Insert before *any* await, including executable resolution. Every
    // concurrent acquire now joins this exact opening promise.
    codexRoutes.set(threadId, entry);
    entry.opening = openCodexRoute(threadId, entry);
  } else if (retain) {
    // Count a retained reference at admission so a close that races the
    // provider handshake cannot leave a late reference behind.
    entry.references += 1;
  }
  const result = await entry.opening;
  if (result.routeState !== "available" && retain) {
    entry.references = Math.max(0, entry.references - 1);
  }
  if (result.routeState === "available" && (!entry.route || entry.closingPromise)) {
    return codexRouteClosingProbe(threadId);
  }
  return result;
}

async function openCodexRoute(threadId: string, entry: CodexRouteEntry): Promise<CodexRouteProbe> {
  const executable = await codexExecutable();
  if (codexRoutes.get(threadId) !== entry || entry.closing) {
    recordCodexRouteDiagnostic({
      type: "route_failed",
      threadId,
      reason: "provider_unavailable",
    });
    return { routeState: "unavailable", unavailableReason: "provider_unavailable" };
  }
  if (!executable) {
    if (codexRoutes.get(threadId) === entry) codexRoutes.delete(threadId);
    recordCodexRouteDiagnostic({
      type: "route_failed",
      threadId,
      reason: "provider_unavailable",
    });
    return { routeState: "unavailable", unavailableReason: "provider_unavailable" };
  }
  const connection = new CodexRouteConnection(threadId, executable);
  let route!: CodexRoute;
  route = new CodexRoute(
    threadId,
    connection,
    () => maybeCloseCodexRoute(threadId),
    (error) => {
      if (codexRoutes.get(threadId)?.route !== route) return;
      const current = codexRoutes.get(threadId);
      if (current) void closeCodexRouteEntry(threadId, current, error);
    },
  );
  entry.route = route;
  try {
    const probe = await route.open(entry.context);
    if (codexRoutes.get(threadId) !== entry) {
      route.close(new Error("The Codex route was released while opening."));
      return { routeState: "unavailable", unavailableReason: "provider_unavailable" };
    }
    entry.ready = true;
    // A non-retained probe has no lease. Close it as soon as the handshake
    // becomes idle; retained chat and temporary send leases stay alive.
    maybeCloseCodexRoute(threadId);
    return probe;
  } catch (error) {
    route.close(error instanceof Error ? error : new Error(String(error)));
    const failure = codexRouteFailure(error);
    recordCodexRouteDiagnostic({
      type: failure.unavailableReason === "owner_only" ? "route_owner_rejected" : "route_failed",
      threadId,
      ...(failure.unavailableReason ? { reason: failure.unavailableReason } : {}),
    });
    return failure;
  }
}

export function codexRouteStatus(threadId: string): CodexRouteProbe {
  const entry = codexRoutes.get(threadId);
  if (entry?.closingPromise || entry?.releasePending) return codexRouteClosingProbe(threadId);
  if (!entry || !entry.route || !entry.ready) {
    const uncertain = uncertainCodexTurn(threadId);
    if (uncertain) return uncertainCodexRouteProbe(threadId);
    const terminal = recentCodexTerminal(threadId);
    if (terminal) {
      return confirmedTerminalProbe(terminal.turnId);
    }
    return uncertainCodexRouteProbe(threadId);
  }
  const probe = entry.route.probe();
  if (probe.routeState === "unavailable") {
    const uncertain = uncertainCodexTurn(threadId);
    if (uncertain) return uncertainCodexRouteProbe(threadId);
    const terminal = recentCodexTerminal(threadId);
    if (terminal) return confirmedTerminalProbe(terminal.turnId);
  }
  return probe;
}

/**
 * Clear a sticky lost-turn marker only after a read-only exact provider
 * lifecycle check proves the same turn reached Ready. This never opens or
 * resumes an app-server route; the next explicit Send remains the writer
 * admission boundary.
 */
export function recoverCodexRoute(
  threadId: string,
  evidence: { turnState: "ready"; turnId: string },
): CodexRouteRecoveryResult {
  const current = codexRouteStatus(threadId);
  if (current.releasePending) {
    return { recovered: false, reason: "release_pending", probe: current };
  }
  const uncertain = uncertainCodexTurn(threadId);
  if (!uncertain) {
    if (current.routeState !== "available" || current.turnState !== "ready") {
      return { recovered: false, reason: "identity_unavailable", probe: current };
    }
    if (current.turnId && current.turnId !== evidence.turnId) {
      return { recovered: false, reason: "identity_mismatch", probe: current };
    }
    return {
      recovered: true,
      probe: current,
    };
  }
  if (!uncertain.turnId) {
    return { recovered: false, reason: "identity_unavailable", probe: current };
  }
  if (uncertain.turnId !== evidence.turnId) {
    return { recovered: false, reason: "identity_mismatch", probe: current };
  }
  clearUncertainCodexTurn(threadId, evidence.turnId);
  rememberCodexTerminal(threadId, evidence.turnId, "completed");
  return {
    recovered: true,
    probe: {
      routeState: "available",
      routeOwnership: "unverified",
      turnState: "ready",
      turnId: evidence.turnId,
      confirmedTerminal: true,
    },
  };
}

export function releaseCodexRoute(threadId: string): void {
  const entry = codexRoutes.get(threadId);
  if (!entry) return;
  entry.references = Math.max(0, entry.references - 1);
  maybeCloseCodexRoute(threadId);
}

/**
 * Relinquish an idle route before opening the owning desktop application.
 * Distinguish a writer we never acquired from a failed release. A released
 * writer has confirmed child exit; active or uncertain turns stay blocked.
 */
export async function relinquishIdleCodexRoute(threadId: string): Promise<CodexRouteRelinquishResult> {
  const entry = codexRoutes.get(threadId);
  if (!entry) return uncertainCodexTurn(threadId) ? "blocked" : "not_owned";
  if (entry.closingPromise || entry.releasePending) {
    return await waitForCodexRouteClose(entry) ? "released" : "blocked";
  }
  if (!entry.route || !entry.ready) return "blocked";
  const probe = entry.route.probe();
  if (probe.routeState !== "available" || probe.turnState !== "ready") return "blocked";
  entry.references = 0;
  closeCodexRouteEntry(threadId, entry);
  return await waitForCodexRouteClose(entry) ? "released" : "blocked";
}

export async function closeCodexRoutes(): Promise<void> {
  const closings: Promise<void>[] = [];
  for (const [threadId, entry] of codexRoutes) {
    entry.references = 0;
    closings.push(closeCodexRouteEntry(threadId, entry, new Error("Codex routes are shutting down.")));
  }
  await Promise.all(closings);
}

function maybeCloseCodexRoute(threadId: string): void {
  const entry = codexRoutes.get(threadId);
  if (!entry || entry.references > 0 || entry.closingPromise || entry.route?.hasActiveTurn()) return;
  if (!entry.route) {
    void closeCodexRouteEntry(threadId, entry);
    return;
  }
  void closeCodexRouteEntry(threadId, entry);
}

function closeCodexRouteEntry(
  threadId: string,
  entry: CodexRouteEntry,
  error?: Error,
): Promise<void> {
  if (entry.closingPromise) return entry.closingPromise;
  entry.closing = true;
  entry.releasePending = true;
  recordCodexRouteDiagnostic({
    type: "route_release_requested",
    threadId,
  });
  const route = entry.route;
  const exit = route?.waitForExitConfirmed() ?? Promise.resolve();
  entry.closingPromise = exit.then(() => {
    entry.releasePending = undefined;
    if (codexRoutes.get(threadId) === entry) codexRoutes.delete(threadId);
    recordCodexRouteDiagnostic({
      type: "route_release_confirmed",
      threadId,
    });
  });
  route?.close(error);
  return entry.closingPromise;
}

async function waitForCodexRouteClose(
  entry: CodexRouteEntry,
  timeout = true,
): Promise<boolean> {
  const closing = entry.closingPromise;
  if (!closing) return true;
  if (!timeout) {
    await closing;
    return true;
  }
  let timedOut = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  await Promise.race([
    closing,
    new Promise<void>((resolve) => {
      timer = setTimeout(() => {
        timedOut = true;
        resolve();
      }, codexRouteCloseTimeoutMs);
      timer.unref?.();
    }),
  ]);
  if (timer) clearTimeout(timer);
  return !timedOut;
}

function codexRouteClosingProbe(threadId?: string): CodexRouteProbe {
  const uncertain = threadId ? uncertainCodexTurn(threadId) : undefined;
  const terminal = threadId ? recentCodexTerminal(threadId) : undefined;
  if (uncertain) {
    return {
      routeState: "unavailable",
      unavailableReason: "provider_unavailable",
      releasePending: true,
      ...(uncertain.turnId ? { turnId: uncertain.turnId } : {}),
    };
  }
  return {
    routeState: "unavailable",
    unavailableReason: "provider_unavailable",
    releasePending: true,
    ...(terminal ? {
      turnState: "ready" as const,
      confirmedTerminal: true as const,
      turnId: terminal.turnId,
    } : {}),
  };
}

function uncertainCodexRouteProbe(threadId: string): CodexRouteProbe {
  const uncertain = uncertainCodexTurn(threadId);
  return {
    routeState: "unavailable",
    unavailableReason: "provider_unavailable",
    ...(uncertain?.turnId ? { turnId: uncertain.turnId } : {}),
  };
}

function confirmedTerminalProbe(turnId: string): CodexRouteProbe {
  return {
    // The old route has exited. A recent terminal event proves the turn
    // boundary, not that this process owns a new writer. The next Send still
    // performs the atomic route admission.
    routeState: "available",
    routeOwnership: "unverified",
    turnState: "ready",
    confirmedTerminal: true,
    turnId,
  };
}

function codexRouteFailure(error: unknown): CodexRouteProbe {
  const message = error instanceof Error ? error.message : String(error);
  return isCodexOwnerConflict(message)
    ? { routeState: "unavailable", unavailableReason: "owner_only", routeOwnership: "external" }
    : { routeState: "unavailable", unavailableReason: "provider_unavailable" };
}

const codexOwnerOnlyMessage = "This conversation is owned by another Codex session. Continue there.";

function isCodexOwnerConflict(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /active writer|writer lock|already loaded|already has an active|owned by another Codex session/i.test(message);
}

function codexOwnerOnlyError(): Error {
  return new Error(codexOwnerOnlyMessage);
}

export async function sendCodexTurn(
  threadId: string,
  text: string,
  imagePaths: string[],
  registerAction?: CodexActionRegistrar,
  deliveryId?: string,
  requestId?: string,
  generation?: number,
  settings?: CodexTurnSettings,
  /** Re-check the exact repository target before each provider write. */
  isCurrent: () => boolean = () => true,
  routeContext?: CodexRouteContext,
): Promise<void> {
  if (!isCurrent()) throw new Error("The chat send is no longer current.");
  // A direct send owns a temporary reference while the route resumes and
  // accepts turn/start. The reference is released after acceptance; an
  // active turn then keeps the route alive until its exact completion event.
  const result = await acquireCodexRoute(threadId, true, routeContext);
  if (result.routeState !== "available") {
    throw new Error(result.unavailableReason === "owner_only"
      ? "This conversation is owned by another Codex session. Continue there."
      : "Codex message delivery is unavailable.");
  }
  try {
    const entry = codexRoutes.get(threadId);
    if (!entry?.route || !entry.ready) throw new Error("Codex message delivery is unavailable.");
    await entry.route.startTurn({
      text,
      imagePaths,
      registerAction,
      deliveryId,
      requestId,
      generation,
      settings,
      isCurrent,
    });
  } finally {
    releaseCodexRoute(threadId);
  }
}

/**
 * Read the provider-owned model and permission catalogs. These are the
 * read-only `model/list` and `permissionProfile/list` app-server methods from
 * the generated Codex schema (`codex app-server generate-json-schema
 * --experimental`); they are intentionally separate from turn delivery.
 */
export async function readCodexSettingsCatalog(
  home = os.homedir(),
  cwd?: string,
): Promise<CodexSettingsCatalog | undefined> {
  const executable = await codexExecutable(home);
  if (!executable) return undefined;
  return new Promise<CodexSettingsCatalog | undefined>((resolve) => {
    const child = spawn(executable, ["app-server", "--listen", "stdio://"], {
      detached: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let buffer = "";
    let outputBytes = 0;
    let modelList: unknown;
    let permissionList: unknown;
    let settled = false;
    const timer = setTimeout(() => finish(undefined), 10_000);
    timer.unref?.();
    child.stderr?.resume();

    child.once("error", () => finish(undefined));
    child.once("close", () => finish(undefined));
    child.stdout.on("data", (chunk: Buffer) => {
      if (settled) return;
      outputBytes += chunk.length;
      if (outputBytes > 1_048_576) return finish(undefined);
      buffer += chunk.toString("utf8");
      while (buffer.includes("\n")) {
        const newline = buffer.indexOf("\n");
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        let message: Record<string, unknown>;
        try { message = JSON.parse(line) as Record<string, unknown>; } catch { continue; }
        if (message.error) return finish(undefined);
        if (message.id === 1) {
          write({ method: "initialized" });
          write({ id: 2, method: "model/list", params: { includeHidden: false, limit: 100 } });
          write({ id: 3, method: "permissionProfile/list", params: { cwd: cwd ?? null, limit: 100 } });
        } else if (message.id === 2) {
          modelList = message.result;
          if (permissionList !== undefined) finish(parseCodexSettingsCatalog(modelList, permissionList));
        } else if (message.id === 3) {
          permissionList = message.result;
          if (modelList !== undefined) finish(parseCodexSettingsCatalog(modelList, permissionList));
        }
      }
    });

    write({
      id: 1,
      method: "initialize",
      params: {
        clientInfo: { name: "agent-visor", version: agentVisorVersion() },
        capabilities: { experimentalApi: true },
      },
    });

    function write(message: unknown): void {
      if (!settled) child.stdin.write(`${JSON.stringify(message)}\n`);
    }

    function finish(value: CodexSettingsCatalog | undefined): void {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.stdin.destroy();
      stop(child);
      resolve(value);
    }
  });
}

function parseCodexSettingsCatalog(
  modelResult: unknown,
  permissionResult: unknown,
): CodexSettingsCatalog | undefined {
  const modelRows = array(record(modelResult)?.data);
  const models = modelRows.flatMap((value): ChatSettings["models"] => {
    const row = record(value);
    const id = boundedCatalogText(row?.id ?? row?.model, 256);
    const displayName = boundedCatalogText(row?.displayName, 256);
    if (!id || !displayName) return [];
    const reasoningEfforts = array(row?.supportedReasoningEfforts).flatMap((effort) => {
      const option = record(effort);
      const value = boundedCatalogText(option?.reasoningEffort, 64);
      const description = boundedCatalogText(option?.description, 512);
      return value && description ? [{ value, description }] : [];
    }).slice(0, 16);
    const defaultReasoningEffort = boundedCatalogText(row?.defaultReasoningEffort, 64);
    if (!defaultReasoningEffort || !reasoningEfforts.some(({ value }) => value === defaultReasoningEffort)) return [];
    const modalities = array(row?.inputModalities);
    return [{
      id,
      displayName,
      description: boundedCatalogText(row?.description, 2_048),
      reasoningEfforts,
      defaultReasoningEffort,
      supportsImages: modalities.includes("image"),
      isDefault: row?.isDefault === true,
    }];
  });
  const permissionRows = array(record(permissionResult)?.data);
  const permissionProfiles = permissionRows.flatMap((value): ChatSettings["permissionProfiles"] => {
    const row = record(value);
    const id = boundedCatalogText(row?.id, 256);
    if (!id || typeof row?.allowed !== "boolean") return [];
    const description = boundedCatalogText(row?.description, 512);
    return [{
      id,
      displayName: permissionDisplayName(id),
      ...(description ? { description } : {}),
      allowed: row.allowed,
    }];
  });
  if (!models.length && !permissionProfiles.length) return undefined;
  return { models, permissionProfiles };
}

function permissionDisplayName(id: string): string {
  if (id === ":danger-full-access") return "Full access";
  if (id === ":workspace") return "Workspace";
  if (id === ":read-only") return "Read only";
  return id.replace(/^:/, "").replace(/[-_]+/g, " ").replace(/\b\w/g, (value) => value.toUpperCase());
}

function boundedCatalogText(value: unknown, maxLength: number): string {
  return typeof value === "string" && value.length > 0 && value.length <= maxLength ? value : "";
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

export function stopCodexTurns(): void {
  for (const turn of [...activeTurns]) turn.stop(new Error("Codex message delivery stopped."));
}

/** Interrupt one daemon-owned Codex turn. Returns false when no live turn is known. */
export async function stopCodexTurn(threadId: string, deliveryId?: string): Promise<boolean> {
  if (!deliveryId) return false;
  const turns = activeTurnsByIdentity.get(activeTurnKey(threadId, deliveryId));
  if (!turns?.size) return false;
  let interrupted = false;
  for (const turn of turns) interrupted = await turn.interrupt() || interrupted;
  return interrupted;
}

export function hasActiveCodexTurn(threadId: string, deliveryId?: string): boolean {
  if (!deliveryId) return false;
  return (activeTurnsByIdentity.get(activeTurnKey(threadId, deliveryId))?.size ?? 0) > 0;
}

/**
 * Return the newest exact active delivery only after its concrete turn is
 * registered. Renderer state follows the newest submitted delivery, so the
 * provider capability must select that same insertion-order policy when more
 * than one daemon-owned turn is live.
 */
export function activeCodexTurnDeliveryId(threadId: string): string | undefined {
  const deliveryIDs = activeDeliveryIDsByThread.get(threadId);
  const deliveryId = deliveryIDs ? [...deliveryIDs].at(-1) : undefined;
  return typeof deliveryId === "string" ? deliveryId : undefined;
}

function activeTurnKey(threadId: string, deliveryId: string): string {
  return JSON.stringify([threadId, deliveryId]);
}

export function codexPendingAction(method: string, value: unknown): ChatPendingAction | undefined {
  const params = record(value) ?? {};
  const toolUseId = `codex-${String(params.itemId ?? params.callId ?? method)}`.slice(0, 512);
  if (method === "item/tool/requestUserInput") {
    const questions = Array.isArray(params.questions) ? params.questions.flatMap((value) => {
      const question = record(value);
      const id = string(question?.id);
      const prompt = string(question?.question) || string(question?.prompt);
      if (!id || !prompt) return [];
      const choices = Array.isArray(question?.options) ? question.options.flatMap((option) => {
        const item = record(option);
        const label = typeof option === "string" ? option : string(item?.label);
        return label ? [label] : [];
      }) : [];
      return [{ id, question: prompt, choices, multiple: question?.multiSelect === true }];
    }) : [];
    return questions.length ? { type: "question", toolUseId, questions } : undefined;
  }
  if (!approvalMethods.has(method)) return undefined;
  return {
    type: "approval",
    toolUseId,
    toolName: approvalName(method),
    input: params,
    canPersist: true,
  };
}

export function codexResponseFor(
  id: unknown,
  method: string,
  paramsValue: unknown,
  response: Extract<ClientMessage, { type: "respond_chat" }>,
): Record<string, unknown> {
  if (method === "item/tool/requestUserInput") {
    if (response.decision !== "answer") {
      return { id, error: { code: -32000, message: "Cancelled by user." } };
    }
    return {
      id,
      result: {
        answers: Object.fromEntries(Object.entries(response.answers ?? {}).map(([key, answer]) => [
          key, { answers: Array.isArray(answer) ? answer : [answer] },
        ])),
      },
    };
  }
  const allowed = response.decision === "allow" || response.decision === "allow_always";
  const persistent = response.decision === "allow_always";
  if (method === "item/permissions/requestApproval") {
    const permissions = record(paramsValue)?.permissions;
    return {
      id,
      result: {
        permissions: allowed && record(permissions) ? permissions : {},
        scope: persistent ? "session" : "turn",
        strictAutoReview: false,
      },
    };
  }
  const modern = method === "item/commandExecution/requestApproval"
    || method === "item/fileChange/requestApproval";
  return {
    id,
    result: {
      decision: modern
        ? allowed ? persistent ? "acceptForSession" : "accept" : "decline"
        : allowed ? persistent ? "approved_for_session" : "approved" : "denied",
    },
  };
}

const approvalMethods = new Set([
  "item/commandExecution/requestApproval",
  "item/fileChange/requestApproval",
  "item/permissions/requestApproval",
  "execCommandApproval",
  "applyPatchApproval",
]);

function approvalName(method: string): string {
  if (method.includes("fileChange") || method === "applyPatchApproval") return "File change";
  if (method.includes("permissions")) return "Permissions";
  return "Command";
}

function codexError(value: unknown): string {
  const message = record(value)?.message;
  return typeof message === "string" && message ? message : "Codex rejected the message.";
}

function codexRPCID(value: unknown): string | number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function codexThreadID(value: unknown): string | undefined {
  const params = record(value);
  const id = params?.threadId ?? params?.thread_id;
  return typeof id === "string" && id.length > 0 ? id : undefined;
}

function codexThreadStatus(
  value: unknown,
): CodexRouteResumeState["turnState"] | undefined {
  const params = record(value);
  const status = params?.status;
  const statusRecord = record(status);
  const type = typeof status === "string" ? status : statusRecord?.type;
  if (type === "active") return "working";
  if (type === "idle") return "ready";
  if (type === "notLoaded" || type === "systemError") return "unknown";
  return undefined;
}

function codexRouteResumeState(value: unknown): CodexRouteResumeState {
  const result = record(value);
  const thread = record(result?.thread);
  const threadId = typeof thread?.id === "string" ? thread.id : undefined;
  if (!threadId) throw new Error("Codex thread/resume returned no concrete thread ID.");
  const turnState = codexThreadStatus({ status: thread?.status }) ?? "unknown";
  const turnId = codexTurnID(thread?.turn);
  return { threadId, turnState, ...(turnId ? { turnId } : {}) };
}

function codexTurnID(value: unknown): string | undefined {
  const recordValue = record(value);
  const nested = record(recordValue?.turn);
  const id = nested?.id ?? recordValue?.turnId ?? recordValue?.turn_id ?? recordValue?.id;
  return typeof id === "string" && id ? id : undefined;
}

type CodexTurnOutcome = "completed" | "failed" | "interrupted" | "unknown";

function codexTurnOutcome(value: unknown): CodexTurnOutcome {
  const params = record(value);
  const turn = record(params?.turn);
  const statusValue = turn?.status ?? params?.status;
  const status = record(statusValue);
  const type = typeof statusValue === "string" ? statusValue : status?.type;
  if (type === "completed") return "completed";
  if (type === "failed" || type === "error" || type === "systemError") return "failed";
  if (type === "interrupted" || type === "cancelled" || type === "canceled") {
    return "interrupted";
  }
  return "unknown";
}

function preAckNativeEventPriority(message: CodexRPCMessage): number {
  if (message.method === "turn/completed") return 4;
  if (message.method === "turn/started") return 2;
  if (message.method === "item/started" || message.method === "item/completed") {
    const item = record(record(message.params)?.item);
    return item?.type === "userMessage" ? 3 : 1;
  }
  return 0;
}

function codexNativeItemID(value: unknown): string | undefined {
  const id = record(value)?.id;
  return typeof id === "string" && id.length > 0 && id.length <= 512 ? id : undefined;
}

function codexNativeItemType(value: unknown): string | undefined {
  const type = record(value)?.type;
  return typeof type === "string" && type.length > 0 && type.length <= 128 ? type : undefined;
}

function codexItemLifecycleEvent(
  method: "item/started" | "item/completed",
  value: unknown,
  context: RouteTurn | undefined,
  threadId: string,
): Extract<CodexRouteEvent, { type: "item_started" | "item_completed" }> | undefined {
  const params = record(value);
  if (codexThreadID(params) !== threadId) return undefined;
  const turnId = codexTurnID(params);
  const item = record(params?.item);
  const itemId = codexNativeItemID(item);
  if (!turnId || !itemId) return undefined;
  if (context?.turnId && context.turnId !== turnId) return undefined;
  const identity = nativeTurnIdentity(threadId, turnId, context);
  return {
    type: method === "item/started" ? "item_started" : "item_completed",
    threadId,
    turnId,
    itemId,
    ...(codexNativeItemType(item) ? { itemType: codexNativeItemType(item) } : {}),
    ...(identity.deliveryId ? { deliveryId: identity.deliveryId } : {}),
    ...(identity.requestId ? { requestId: identity.requestId } : {}),
  };
}

function codexAgentMessageDeltaEvent(
  value: unknown,
  context: RouteTurn | undefined,
  threadId: string,
): Extract<CodexRouteEvent, { type: "agent_message_delta" }> | undefined {
  const params = record(value);
  if (codexThreadID(params) !== threadId) return undefined;
  const turnId = codexTurnID(params);
  const itemIdValue = params?.itemId ?? params?.item_id;
  const itemId = typeof itemIdValue === "string" && itemIdValue.length > 0 && itemIdValue.length <= 512
    ? itemIdValue
    : undefined;
  const delta = params?.delta;
  if (!turnId || !itemId || typeof delta !== "string") return undefined;
  if (context?.turnId && context.turnId !== turnId) return undefined;
  const identity = nativeTurnIdentity(threadId, turnId, context);
  return {
    type: "agent_message_delta",
    threadId,
    turnId,
    itemId,
    deltaLength: Math.min(delta.length, 100_000),
    ...(identity.deliveryId ? { deliveryId: identity.deliveryId } : {}),
  };
}

function rememberCodexTurnIdentity(
  threadId: string,
  turnId: string | undefined,
  context: Pick<RouteTurn, "deliveryId" | "requestId">,
): void {
  if (!turnId || (!context.deliveryId && !context.requestId)) return;
  let identities = recentCodexTurnIdentityByThread.get(threadId);
  if (!identities) {
    identities = new Map();
    recentCodexTurnIdentityByThread.set(threadId, identities);
  }
  identities.set(turnId, {
    ...(context.deliveryId ? { deliveryId: context.deliveryId } : {}),
    ...(context.requestId ? { requestId: context.requestId } : {}),
    expiresAt: Date.now() + codexTurnIdentityTtlMs,
  });
  for (const [id, identity] of identities) {
    if (identity.expiresAt <= Date.now()) identities.delete(id);
  }
  while (identities.size > maxRecentCodexTurnIdentities) {
    identities.delete(identities.keys().next().value!);
  }
}

function nativeTurnIdentity(
  threadId: string,
  turnId: string,
  context?: Pick<RouteTurn, "turnId" | "deliveryId" | "requestId">,
): { deliveryId?: string; requestId?: string } {
  if (context?.turnId === turnId && (context.deliveryId || context.requestId)) {
    return {
      ...(context.deliveryId ? { deliveryId: context.deliveryId } : {}),
      ...(context.requestId ? { requestId: context.requestId } : {}),
    };
  }
  const identities = recentCodexTurnIdentityByThread.get(threadId);
  const identity = identities?.get(turnId);
  if (!identity || identity.expiresAt <= Date.now()) {
    if (identity) identities?.delete(turnId);
    return {};
  }
  return {
    ...(identity.deliveryId ? { deliveryId: identity.deliveryId } : {}),
    ...(identity.requestId ? { requestId: identity.requestId } : {}),
  };
}

function rememberUncertainCodexTurn(
  threadId: string,
  turnId: string | undefined,
  deliveryId?: string,
): void {
  const now = Date.now();
  // The exact native identity is bounded by the TTL, but the uncertainty
  // marker itself is sticky until a matching completion arrives. Expiring an
  // ID must never be treated as proof that the lost turn finished.
  uncertainCodexTurnByThread.set(threadId, {
    ...(turnId ? { turnId } : {}),
    ...(deliveryId ? { deliveryId } : {}),
    expiresAt: now + uncertainCodexTurnTtlMs,
  });
}

function clearUncertainCodexTurn(threadId: string, turnId?: string): void {
  const current = uncertainCodexTurnByThread.get(threadId);
  if (!current) return;
  if (turnId && current.turnId && current.turnId !== turnId) return;
  uncertainCodexTurnByThread.delete(threadId);
}

function uncertainCodexTurn(
  threadId: string,
): { turnId?: string; deliveryId?: string } | undefined {
  const current = uncertainCodexTurnByThread.get(threadId);
  if (!current) return undefined;
  // The exact turn identity is recovery evidence, not a disposable
  // diagnostic field. Keep it until matching ready lifecycle evidence clears
  // the uncertainty; diagnostics remain bounded independently.
  return {
    ...(current.turnId ? { turnId: current.turnId } : {}),
    ...(current.deliveryId ? { deliveryId: current.deliveryId } : {}),
  };
}

function rememberCodexTerminal(
  threadId: string,
  turnId: string,
  outcome: Extract<CodexTurnOutcome, "completed" | "failed" | "interrupted">,
): void {
  const now = Date.now();
  for (const [id, value] of recentCodexTerminalByThread) {
    if (value.expiresAt <= now) recentCodexTerminalByThread.delete(id);
  }
  recentCodexTerminalByThread.set(threadId, {
    turnId,
    outcome,
    expiresAt: now + codexTerminalTtlMs,
  });
  while (recentCodexTerminalByThread.size > maxCodexTerminals) {
    recentCodexTerminalByThread.delete(recentCodexTerminalByThread.keys().next().value!);
  }
}

function recentCodexTerminal(
  threadId: string,
): { turnId: string; outcome: Extract<CodexTurnOutcome, "completed" | "failed" | "interrupted"> } | undefined {
  const current = recentCodexTerminalByThread.get(threadId);
  if (!current) return undefined;
  if (current.expiresAt <= Date.now()) {
    recentCodexTerminalByThread.delete(threadId);
    return undefined;
  }
  return { turnId: current.turnId, outcome: current.outcome };
}

async function codexExecutable(home = os.homedir()): Promise<string | undefined> {
  const explicit = process.env.CODEX_BINARY;
  if (explicit) {
    try {
      await access(explicit, constants.X_OK);
      return explicit;
    } catch {
      // An explicit binary is authoritative. Do not silently fall back to a
      // stale Homebrew or system installation when it cannot be executed.
      return undefined;
    }
  }
  for (const candidate of [
    `${home}/.local/bin/codex`,
    "/Applications/ChatGPT.app/Contents/Resources/codex",
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
  ]) {
    try {
      await access(candidate, constants.X_OK);
      return candidate;
    } catch { /* try the next known path */ }
  }
  return undefined;
}

function stop(child: ChildProcess): void {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try {
    if (child.pid) process.kill(-child.pid, "SIGTERM");
    else child.kill("SIGTERM");
  } catch { child.kill("SIGTERM"); }
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown> : undefined;
}

function string(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}
