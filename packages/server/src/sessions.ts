import {
  sessionSnapshotSchema,
  type ChatPage,
  type ClientMessage,
  type SessionSection,
  type ChatImage,
  type ChatPendingAction,
  type NativeHelperFocusTarget,
  type NativeHelperPiRestorationUpdate,
  type NativeHelperTerminalTarget,
  type SessionSnapshot,
  type SessionSummary,
} from "@agent-visor/protocol";
import { randomUUID } from "node:crypto";
import {
  chmodSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { readChatPage } from "./chat.js";

export type ProviderID = "claude_code" | "codex" | "pi" | "cursor" | "zed" | "auggie";

export type SessionControlTarget =
  | { kind: "application"; target: NativeHelperFocusTarget }
  | { kind: "terminal"; target: NativeHelperTerminalTarget }
  | { kind: "url"; url: string };

export type DiscoveredProviderSession = {
  id: string;
  provider: ProviderID;
  title?: string;
  subtitle?: string;
  project?: string;
  cwd: string;
  owner: string;
  section: SessionSection;
  updatedAt: string;
  canOpenOwner: boolean;
  canEnterChat: boolean;
  authority?: number;
  chatPath?: string;
  controlTarget?: SessionControlTarget;
  messageTransport?: "terminal" | "codex_app_server";
  modelCatalog?: Record<string, { displayName: string; contextWindow?: number }>;
};

export interface SessionControls {
  focus(session: DiscoveredProviderSession): Promise<void>;
  send(session: DiscoveredProviderSession, text: string, images: ChatImage[]): Promise<void>;
}

export interface SessionSnapshotSource {
  current(): SessionSnapshot;
  subscribe(listener: (snapshot: SessionSnapshot) => void): () => void;
  acknowledgeReady?(sessionId: string): void;
  chatPage?(sessionId: string, before?: number, limit?: number): Promise<ChatPage>;
  chatAction?(message: Extract<ClientMessage, { type: "send_chat" | "respond_chat" }>): Promise<string | undefined>;
  focusSession?(sessionId: string): Promise<string | undefined>;
}

export interface ProviderAdapter {
  readonly id: ProviderID;
  discover(): Promise<DiscoveredProviderSession[]>;
  noteHook?(event: HookSessionEvent): void;
}

export type HookSessionEvent = {
  sessionId: string;
  cwd: string;
  provider: Exclude<ProviderID, "zed">;
  event: string;
  status: string;
  receivedAt: string;
  activityAt?: string;
  pid?: number;
  tty?: string;
  expectsResponse?: boolean;
  isIdle?: boolean;
  sessionFile?: string;
  tool?: string;
  toolInput?: Record<string, unknown>;
  toolUseId?: string;
  permissionSuggestions?: unknown[];
};

export type HookResponse = {
  decision: "allow" | "deny";
  reason?: string;
  updated_input?: Record<string, unknown>;
  updated_permissions?: unknown[];
};

const piReadyRecoveryWindowMs = 90_000;
// ponytail: keep this aligned with Swift's TranscriptPhaseInferrer.defaultStaleCeiling;
// move the value into the shared protocol if another runtime needs to enforce the policy.
const piHookReadyStaleCeilingMs = 30 * 60 * 1_000;
const distantPast = "1970-01-01T00:00:00.000Z";
const maxPiRuntimeLinks = 64;
const maxPiRuntimeStateBytes = 1_048_576;

type SessionRepositoryOptions = {
  piRuntimeStatePath?: string;
  bootSessionUUID?: string;
  now?: () => Date;
};

type PiRuntimeState = {
  path: string;
  bootSessionUUID: string;
};

type PersistedPiRuntimeLink = {
  sessionId: string;
  cwd: string;
  pid: number;
  tty: string;
  sessionFile: string;
};

const providerNames: Record<ProviderID, string> = {
  claude_code: "Claude Code",
  codex: "Codex",
  pi: "Pi",
  cursor: "Cursor",
  zed: "Zed",
  auggie: "Auggie",
};

export class SessionRepository {
  private revision = 0;
  private fingerprint: string | undefined;
  private snapshotValue: SessionSnapshot = {
    type: "session_snapshot",
    revision: 0,
    sessions: [],
  };
  private readonly lastByProvider = new Map<ProviderID, DiscoveredProviderSession[]>();
  private readonly latestHookAtBySession = new Map<string, string>();
  private readonly hookBySession = new Map<string, HookSessionEvent>();
  private readonly piRuntimeBySession = new Map<string, HookSessionEvent>();
  private readonly acknowledgedReadyIDs = new Set<string>();
  private readonly piRuntimeDiscoveryGeneration = new Map<string, number>();
  private readonly piRemovedRestorationSessionIds = new Set<string>();
  private piDiscoveryGeneration = 0;
  private piRestorationFingerprint: string | undefined;
  private piRuntimeState: PiRuntimeState | undefined;
  private piRuntimeStateFingerprint: string | undefined;
  private readonly piRestorationListeners = new Set<(
    update: NativeHelperPiRestorationUpdate,
  ) => void>();
  private readonly chatBySession = new Map<string, DiscoveredProviderSession>();
  private readonly listeners = new Set<(snapshot: SessionSnapshot) => void>();
  private readonly controlBySession = new Map<string, DiscoveredProviderSession>();
  private readonly externalActions = new Map<string, {
    pending: ChatPendingAction;
    receivedAt: string;
    respond(message: Extract<ClientMessage, { type: "respond_chat" }>): Promise<void>;
  }>();
  private controls: SessionControls | undefined;
  private readonly now: () => Date;
  private readonly hookResponders = new Map<string, {
    sessionId: string;
    respond(response: HookResponse): void;
  }>();

  constructor(
    private readonly providers: ProviderAdapter[],
    options: SessionRepositoryOptions = {},
  ) {
    this.now = options.now ?? (() => new Date());
    const bootSessionUUID = canonicalBootSessionUUID(options.bootSessionUUID);
    if (!options.piRuntimeStatePath || !bootSessionUUID) return;
    this.piRuntimeState = { path: options.piRuntimeStatePath, bootSessionUUID };
    for (const event of readPiRuntimeLinks(this.piRuntimeState)) {
      this.latestHookAtBySession.set(event.sessionId, event.receivedAt);
      this.piRuntimeBySession.set(event.sessionId, event);
      this.piRuntimeDiscoveryGeneration.set(event.sessionId, this.piDiscoveryGeneration);
      this.providers.find((provider) => provider.id === "pi")?.noteHook?.(event);
    }
    this.piRuntimeStateFingerprint = serializePiRuntimeState(
      this.piRuntimeState,
      this.piRuntimeBySession.values(),
    );
  }

  setControls(controls: SessionControls): void {
    this.controls = controls;
  }

  current(): SessionSnapshot {
    return structuredClone(this.snapshotValue);
  }

  subscribe(listener: (snapshot: SessionSnapshot) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  subscribePiRestoration(
    listener: (update: NativeHelperPiRestorationUpdate) => void,
  ): () => void {
    this.piRestorationListeners.add(listener);
    return () => this.piRestorationListeners.delete(listener);
  }

  chatRecord(sessionId: string): DiscoveredProviderSession | undefined {
    const record = this.chatBySession.get(sessionId);
    return record ? structuredClone(record) : undefined;
  }

  hookRecord(sessionId: string): HookSessionEvent | undefined {
    const record = this.hookBySession.get(sessionId);
    return record ? structuredClone(record) : undefined;
  }

  piRestorationUpdate(): NativeHelperPiRestorationUpdate {
    const piSessions = new Map(
      (this.lastByProvider.get("pi") ?? []).map((session) => [session.id, session]),
    );
    const candidates = [...this.piRuntimeBySession.values()].flatMap((hook) => {
      const session = piSessions.get(hook.sessionId);
      const target = session?.controlTarget;
      if (hook.provider !== "pi" || hook.event === "SessionEnd"
        || hook.pid === undefined || !hook.tty || !hook.sessionFile
        || !isPersistedRegularFile(hook.sessionFile) || !isExistingDirectory(hook.cwd)
        || session?.provider !== "pi" || session.owner !== "Ghostty"
        || !session.chatPath
        || path.resolve(session.chatPath) !== path.resolve(hook.sessionFile)
        || session.cwd !== hook.cwd
        || target?.kind !== "terminal" || target.target.application !== "Ghostty"
        || target.target.cwd !== hook.cwd
        || normalizedTTY(target.target.tty) !== normalizedTTY(hook.tty)) return [];
      return [{
        sessionId: hook.sessionId,
        sessionFile: hook.sessionFile,
        cwd: hook.cwd,
        ...(session.title ? { sessionName: session.title } : {}),
        pid: hook.pid,
        tty: hook.tty,
      }];
    }).sort((left, right) => left.sessionId.localeCompare(right.sessionId));
    const removeCandidateSessionIds = new Set(this.piRemovedRestorationSessionIds);
    for (const [sessionId, hook] of this.piRuntimeBySession) {
      const session = piSessions.get(sessionId);
      const hasFreshDiscovery = (this.piRuntimeDiscoveryGeneration.get(sessionId) ?? Infinity)
        < this.piDiscoveryGeneration;
      if ((hook.sessionFile && !isPersistedRegularFile(hook.sessionFile))
        || !isExistingDirectory(hook.cwd)
        || (hasFreshDiscovery && session?.owner !== "Ghostty")) {
        removeCandidateSessionIds.add(sessionId);
      }
    }
    return {
      candidates,
      liveSessionIds: [...this.piRuntimeBySession.keys()].sort(),
      removeCandidateSessionIds: [...removeCandidateSessionIds].sort(),
      cleanTermination: false,
    };
  }

  pendingAction(sessionId: string): ChatPendingAction | undefined {
    const pending = this.externalActions.get(sessionId)?.pending
      ?? pendingChatAction(this.hookBySession.get(sessionId));
    return pending ? structuredClone(pending) : undefined;
  }

  registerExternalAction(
    sessionId: string,
    pending: ChatPendingAction,
    respond: (message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void>,
  ): () => void {
    this.externalActions.set(sessionId, {
      pending: structuredClone(pending), receivedAt: new Date().toISOString(), respond,
    });
    this.publish([...this.lastByProvider.values()].flat());
    return () => {
      if (this.externalActions.get(sessionId)?.respond === respond) {
        this.externalActions.delete(sessionId);
        this.publish([...this.lastByProvider.values()].flat());
      }
    };
  }

  registerHookResponder(
    sessionId: string,
    toolUseId: string,
    respond: (response: HookResponse) => void,
  ): () => void {
    this.hookResponders.set(toolUseId, { sessionId, respond });
    return () => {
      const current = this.hookResponders.get(toolUseId);
      if (current?.respond !== respond) return;
      this.hookResponders.delete(toolUseId);
      const hook = this.hookBySession.get(sessionId);
      if (hook?.expectsResponse && hook.toolUseId === toolUseId) {
        this.hookBySession.delete(sessionId);
        this.publish([...this.lastByProvider.values()].flat());
      }
    };
  }

  async chatPage(sessionId: string, before?: number, limit?: number): Promise<ChatPage> {
    const hook = this.hookBySession.get(sessionId);
    const discovered = this.chatBySession.get(sessionId);
    const record = discovered ?? (hook ? hookSession(hook) : undefined);
    if (!record) return unavailableChatPage(sessionId, "This session is no longer available.");
    const page = await readChatPage(record, before, limit);
    const pendingAction = this.pendingAction(sessionId);
    if (pendingAction) {
      page.pendingAction = pendingAction;
      page.capabilities.canApprove = pendingAction.type === "approval";
      page.capabilities.canAnswer = pendingAction.type === "question";
    }
    return page;
  }

  async focusSession(sessionId: string): Promise<string | undefined> {
    const session = this.controlBySession.get(sessionId);
    if (!session?.controlTarget || !this.controls) return "Exact session focus is unavailable.";
    this.acknowledgeReady(sessionId);
    try {
      await this.controls.focus(structuredClone(session));
      return undefined;
    } catch (error) {
      return error instanceof Error ? error.message : "Exact session focus failed.";
    }
  }

  acknowledgeReady(sessionId: string): void {
    const session = this.snapshotValue.sessions.find(({ id }) => id === sessionId);
    if (session?.section !== "ready" || this.acknowledgedReadyIDs.has(sessionId)) return;
    this.acknowledgedReadyIDs.add(sessionId);
    this.publish([...this.lastByProvider.values()].flat());
  }

  async chatAction(
    message: Extract<ClientMessage, { type: "send_chat" | "respond_chat" }>,
  ): Promise<string | undefined> {
    if (message.type === "send_chat") {
      const session = this.chatBySession.get(message.sessionId);
      if (!session?.messageTransport || !this.controls) {
        return "Continue in the source app while native message transport is unavailable.";
      }
      try {
        await this.controls.send(structuredClone(session), message.text, message.images);
        return undefined;
      } catch (error) {
        return error instanceof Error ? error.message : "The message could not be delivered.";
      }
    }
    const external = this.externalActions.get(message.sessionId);
    if (external && external.pending.toolUseId === message.toolUseId) {
      try {
        await external.respond(message);
        this.externalActions.delete(message.sessionId);
        this.publish([...this.lastByProvider.values()].flat());
        return undefined;
      } catch (error) {
        return error instanceof Error ? error.message : "The response could not be delivered.";
      }
    }
    const pending = this.hookResponders.get(message.toolUseId);
    const hook = this.hookBySession.get(message.sessionId);
    if (!pending || pending.sessionId !== message.sessionId || !hook) {
      return "This action is no longer waiting for a response.";
    }
    const response = hookResponse(message, hook);
    pending.respond(response);
    this.hookResponders.delete(message.toolUseId);
    this.hookBySession.delete(message.sessionId);
    this.publish([...this.lastByProvider.values()].flat());
    return undefined;
  }

  async refresh(): Promise<SessionSnapshot> {
    const discovered = await Promise.all(this.providers.map(async (provider) => {
      try {
        const sessions = await provider.discover();
        this.lastByProvider.set(provider.id, structuredClone(sessions));
        if (provider.id === "pi") this.piDiscoveryGeneration += 1;
        return sessions;
      } catch {
        return this.lastByProvider.get(provider.id) ?? [];
      }
    }));
    this.removeConcludedPiRuntimes();
    this.expireStalePiReadyHooks();
    const snapshot = this.publish(discovered.flat());
    this.publishPiRestoration();
    return snapshot;
  }

  applyHook(event: HookSessionEvent): SessionSnapshot {
    const latestAt = this.latestHookAtBySession.get(event.sessionId);
    if (!latestAt || latestAt <= event.receivedAt) {
      this.latestHookAtBySession.set(event.sessionId, event.receivedAt);
      const previous = this.hookBySession.get(event.sessionId);
      if (!shouldIgnorePiHeartbeat(event, previous)) {
        this.providers.find((provider) => provider.id === event.provider)?.noteHook?.(event);
        if (event.provider === "pi") {
          if (event.event === "SessionEnd") {
            this.piRuntimeBySession.delete(event.sessionId);
            this.piRuntimeDiscoveryGeneration.delete(event.sessionId);
            this.rememberPiRestorationRemoval(event.sessionId);
          } else if (event.pid !== undefined && event.sessionFile) {
            if (event.event === "SessionStart") {
              for (const [sessionId, runtime] of this.piRuntimeBySession) {
                if (sessionId !== event.sessionId && runtime.pid === event.pid) {
                  this.piRuntimeBySession.delete(sessionId);
                  this.piRuntimeDiscoveryGeneration.delete(sessionId);
                  this.rememberPiRestorationRemoval(sessionId);
                }
              }
            }
            this.piRuntimeBySession.set(event.sessionId, structuredClone(event));
            this.piRuntimeDiscoveryGeneration.set(event.sessionId, this.piDiscoveryGeneration);
            this.piRemovedRestorationSessionIds.delete(event.sessionId);
          }
          this.persistPiRuntimeLinks();
        }
        if (isPiHeartbeat(event)) {
          const current = this.snapshotValue.sessions.find((session) => session.id === event.sessionId);
          const recovered = piHeartbeatPresentation(event, current, previous);
          if (recovered) this.hookBySession.set(event.sessionId, recovered);
        } else {
          this.hookBySession.set(event.sessionId, structuredClone(event));
        }
      }
    }
    const snapshot = this.publish([...this.lastByProvider.values()].flat());
    if (event.provider === "pi") this.publishPiRestoration();
    return snapshot;
  }

  private publishPiRestoration(): void {
    const update = this.piRestorationUpdate();
    const fingerprint = JSON.stringify(update);
    if (fingerprint === this.piRestorationFingerprint) return;
    this.piRestorationFingerprint = fingerprint;
    for (const listener of this.piRestorationListeners) listener(structuredClone(update));
  }

  private rememberPiRestorationRemoval(sessionId: string): void {
    this.piRemovedRestorationSessionIds.delete(sessionId);
    this.piRemovedRestorationSessionIds.add(sessionId);
    // ponytail: the helper accepts 64 IDs; add acknowledged batches if that ceiling is reached.
    while (this.piRemovedRestorationSessionIds.size > 64) {
      this.piRemovedRestorationSessionIds.delete(
        this.piRemovedRestorationSessionIds.values().next().value!,
      );
    }
  }

  private persistPiRuntimeLinks(): void {
    const state = this.piRuntimeState;
    if (!state) return;
    const serialized = serializePiRuntimeState(state, this.piRuntimeBySession.values());
    if (serialized === this.piRuntimeStateFingerprint) return;
    const temporaryPath = `${state.path}.${process.pid}.${randomUUID()}.tmp`;
    try {
      mkdirSync(path.dirname(state.path), { recursive: true, mode: 0o700 });
      writeFileSync(temporaryPath, serialized, {
        encoding: "utf8",
        flag: "wx",
        mode: 0o600,
      });
      chmodSync(temporaryPath, 0o600);
      renameSync(temporaryPath, state.path);
      this.piRuntimeStateFingerprint = serialized;
    } catch {
      try { rmSync(temporaryPath, { force: true }); } catch { /* best-effort cache */ }
    }
  }

  private removeConcludedPiRuntimes(): void {
    const sessions = new Map(
      (this.lastByProvider.get("pi") ?? []).map((session) => [session.id, session]),
    );
    for (const sessionId of this.piRuntimeBySession.keys()) {
      const hasFreshDiscovery = (this.piRuntimeDiscoveryGeneration.get(sessionId) ?? Infinity)
        < this.piDiscoveryGeneration;
      if (!hasFreshDiscovery || sessions.get(sessionId)?.canOpenOwner) continue;
      this.piRuntimeBySession.delete(sessionId);
      this.piRuntimeDiscoveryGeneration.delete(sessionId);
      this.rememberPiRestorationRemoval(sessionId);
    }
    this.persistPiRuntimeLinks();
  }

  private expireStalePiReadyHooks(): void {
    const now = this.now().valueOf();
    for (const [sessionId, hook] of this.hookBySession) {
      if (hook.provider !== "pi" || hookPhase(hook).section !== "ready") continue;
      const observedAt = Date.parse(hook.receivedAt);
      if (!Number.isFinite(observedAt) || now - observedAt <= piHookReadyStaleCeilingMs) continue;
      this.hookBySession.delete(sessionId);
    }
  }

  private publish(discovered: DiscoveredProviderSession[]): SessionSnapshot {
    this.chatBySession.clear();
    const authoritative = new Map<string, DiscoveredProviderSession>();
    for (const record of discovered) {
      const existing = authoritative.get(record.id);
      if (!existing || (record.authority ?? 1) > (existing.authority ?? 1)) {
        authoritative.set(record.id, record);
      }
    }
    for (const record of discovered) {
      if (!record.chatPath) continue;
      const existing = this.chatBySession.get(record.id);
      if (!existing || (record.authority ?? 1) >= (existing.authority ?? 1)) {
        const authority = authoritative.get(record.id);
        const owner = authority?.owner ?? record.owner;
        this.chatBySession.set(record.id, structuredClone({
          ...record,
          owner,
          ...(authority?.controlTarget ? { controlTarget: authority.controlTarget } : {}),
          ...(owner === "Zed" ? { messageTransport: undefined } : {}),
        }));
      }
    }
    const merged = applyHooks(discovered, this.hookBySession);
    for (const record of merged) {
      if (this.externalActions.has(record.id)) {
        record.section = "needs_you";
        record.subtitle = "Approval required";
        record.updatedAt = this.externalActions.get(record.id)!.receivedAt;
      }
      // Codex's discovery age gate applies to source-only history, not a
      // tracked Ready/working/Needs-you session with a canonical transcript.
      // Chat send/cancel authority remains separate from this read-only entry.
      if (record.provider === "codex" && record.owner === "Codex"
        && record.section !== "history" && record.chatPath) {
        record.canEnterChat = true;
      }
    }
    this.controlBySession.clear();
    for (const record of merged) {
      const existing = this.controlBySession.get(record.id);
      if (!existing || (record.authority ?? 1) > (existing.authority ?? 1)) {
        this.controlBySession.set(record.id, structuredClone(record));
      }
    }
    const sessions = normalize(merged);
    const previousSections = new Map(
      this.snapshotValue.sessions.map(({ id, section }) => [id, section]),
    );
    const sessionIDs = new Set(sessions.map(({ id }) => id));
    for (const sessionId of this.acknowledgedReadyIDs) {
      if (!sessionIDs.has(sessionId)) this.acknowledgedReadyIDs.delete(sessionId);
    }
    for (const session of sessions) {
      if (session.section !== "ready" || previousSections.get(session.id) !== "ready") {
        this.acknowledgedReadyIDs.delete(session.id);
      }
      session.attentionTier = session.section === "ready" && this.acknowledgedReadyIDs.has(session.id)
        ? "acknowledged_ready"
        : session.section;
    }
    const fingerprint = JSON.stringify(sessions);
    if (fingerprint !== this.fingerprint) {
      this.fingerprint = fingerprint;
      this.revision += 1;
      this.snapshotValue = sessionSnapshotSchema.parse({
        type: "session_snapshot",
        revision: this.revision,
        sessions,
      });
      for (const listener of this.listeners) listener(this.current());
    }
    return this.current();
  }
}

function canonicalBootSessionUUID(value: unknown): string | undefined {
  if (typeof value !== "string"
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    return undefined;
  }
  return value.toUpperCase();
}

function readPiRuntimeLinks(state: PiRuntimeState): HookSessionEvent[] {
  try {
    const metadata = lstatSync(state.path);
    if (!metadata.isFile() || metadata.size > maxPiRuntimeStateBytes) return [];
    const value: unknown = JSON.parse(readFileSync(state.path, "utf8"));
    if (!isRecord(value) || value.version !== 1
      || canonicalBootSessionUUID(value.bootSessionUUID) !== state.bootSessionUUID
      || !Array.isArray(value.links) || value.links.length > maxPiRuntimeLinks) return [];
    return value.links.flatMap((link) => {
      const persisted = persistedPiRuntimeLink(link);
      return persisted ? [{
        ...persisted,
        provider: "pi" as const,
        event: "SessionHeartbeat",
        status: "alive",
        receivedAt: distantPast,
      }] : [];
    });
  } catch {
    return [];
  }
}

function serializePiRuntimeState(
  state: PiRuntimeState,
  events: Iterable<HookSessionEvent>,
): string {
  // ponytail: keep the helper's 64-session ceiling; page only if concurrent Pi use reaches it.
  const links = [...events].flatMap((event) => {
    const persisted = persistedPiRuntimeLink(event);
    return persisted ? [persisted] : [];
  }).slice(-maxPiRuntimeLinks)
    .sort((left, right) => left.sessionId.localeCompare(right.sessionId));
  return JSON.stringify({ version: 1, bootSessionUUID: state.bootSessionUUID, links });
}

function persistedPiRuntimeLink(value: unknown): PersistedPiRuntimeLink | undefined {
  if (!isRecord(value)) return undefined;
  const sessionId = boundedString(value.sessionId, 256);
  const cwd = boundedString(value.cwd, 4_096);
  const tty = boundedString(value.tty, 128);
  const sessionFile = boundedString(value.sessionFile, 4_096);
  const pid = value.pid;
  if (!sessionId || !cwd || !tty || !sessionFile
    || !path.isAbsolute(cwd) || !path.isAbsolute(sessionFile)
    || !Number.isSafeInteger(pid) || (pid as number) < 1
    || !isExistingDirectory(cwd) || !isPersistedRegularFile(sessionFile)) return undefined;
  return { sessionId, cwd, pid: pid as number, tty, sessionFile };
}

function boundedString(value: unknown, maxLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed && trimmed.length <= maxLength ? trimmed : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function applyHooks(
  discovered: DiscoveredProviderSession[],
  hookBySession: Map<string, HookSessionEvent>,
): DiscoveredProviderSession[] {
  const sessions = discovered.map((session) => ({ ...session }));
  for (const hook of hookBySession.values()) {
    const phase = hookPhase(hook);
    const existing = sessions.find((session) => session.id === hook.sessionId);
    if (existing) {
      existing.section = phase.section;
      existing.subtitle = phase.subtitle;
      existing.updatedAt = hook.activityAt ?? hook.receivedAt;
      continue;
    }
    if (hook.provider === "codex" || hook.provider === "pi"
      || (hook.provider === "claude_code" && !hook.tty)) continue;
    sessions.push({
      id: hook.sessionId,
      provider: hook.provider,
      cwd: hook.cwd,
      owner: hookOwner(hook),
      section: phase.section,
      subtitle: phase.subtitle,
      updatedAt: hook.activityAt ?? hook.receivedAt,
      canOpenOwner: Boolean(hook.pid || hook.tty),
      canEnterChat: hookCanEnterChat(hook),
      chatPath: hook.sessionFile,
    });
  }
  return sessions;
}

function normalizedTTY(value: string): string {
  return value.replace(/^\/dev\//, "");
}

function isPersistedRegularFile(value: string): boolean {
  try {
    return statSync(value).isFile();
  } catch {
    return false;
  }
}

function isExistingDirectory(value: string): boolean {
  try {
    return statSync(value).isDirectory();
  } catch {
    return false;
  }
}

function isPiHeartbeat(event: HookSessionEvent): boolean {
  return event.provider === "pi" && event.event === "SessionHeartbeat";
}

function shouldIgnorePiHeartbeat(
  event: HookSessionEvent,
  previous: HookSessionEvent | undefined,
): boolean {
  return isPiHeartbeat(event) && (
    event.pid === undefined
    || (previous?.event === "SessionEnd" && previous.pid === event.pid)
  );
}

function piHeartbeatPresentation(
  event: HookSessionEvent,
  current: SessionSummary | undefined,
  previous: HookSessionEvent | undefined,
): HookSessionEvent | undefined {
  if (current?.section !== "working") {
    if (current) return previous;
    return {
      ...structuredClone(event),
      status: "inactive",
      activityAt: transcriptModifiedAt(event) ?? distantPast,
    };
  }
  if (event.isIdle !== true) return previous;

  const completionAt = transcriptModifiedAt(event);
  const age = completionAt
    ? Date.parse(event.receivedAt) - Date.parse(completionAt)
    : Number.POSITIVE_INFINITY;
  if (age <= piReadyRecoveryWindowMs) {
    return {
      ...structuredClone(event),
      event: "Stop",
      status: "idle",
      activityAt: event.receivedAt,
    };
  }
  return {
    ...structuredClone(event),
    status: "inactive",
    activityAt: completionAt ?? current.updatedAt,
  };
}

function transcriptModifiedAt(event: HookSessionEvent): string | undefined {
  if (!event.sessionFile) return undefined;
  try {
    return statSync(event.sessionFile).mtime.toISOString();
  } catch {
    return undefined;
  }
}

function hookPhase(event: HookSessionEvent): { section: SessionSection; subtitle: string } {
  const status = event.status.trim().toLowerCase();
  if (event.event === "Stop") {
    return { section: "ready", subtitle: "Ready to continue" };
  }
  if (event.expectsResponse || event.event === "PermissionRequest"
    || status.includes("approval") || status === "waiting_for_input") {
    return { section: "needs_you", subtitle: "Approval required" };
  }
  if (event.event === "SessionEnd"
    || ["ended", "exited", "closed", "inactive", "stopped", "terminated"].includes(status)) {
    return { section: "history", subtitle: "Session ended" };
  }
  if (!isPiHeartbeat(event) && (event.isIdle === true || status === "idle")) {
    return { section: "ready", subtitle: "Ready to continue" };
  }
  return { section: "working", subtitle: "Agent is working" };
}

function hookOwner(event: HookSessionEvent): string {
  if (event.tty) return "Terminal";
  if (event.provider === "cursor") return "Cursor";
  if (event.provider === "codex") return "Codex";
  if (event.provider === "claude_code") return "Claude";
  return providerNames[event.provider];
}

function hookCanEnterChat(hook: HookSessionEvent): boolean {
  return hook.provider !== "auggie"
    && (hook.provider !== "codex" || hook.sessionFile !== undefined);
}

function hookSession(hook: HookSessionEvent): DiscoveredProviderSession {
  return {
    id: hook.sessionId,
    provider: hook.provider,
    cwd: hook.cwd,
    owner: hookOwner(hook),
    section: hookPhase(hook).section,
    updatedAt: hook.activityAt ?? hook.receivedAt,
    canOpenOwner: hook.provider !== "codex" && Boolean(hook.pid || hook.tty),
    canEnterChat: hookCanEnterChat(hook),
    chatPath: hook.sessionFile,
  };
}

function unavailableChatPage(sessionId: string, readOnlyReason: string): ChatPage {
  return {
    type: "chat_page",
    sessionId,
    items: [],
    hasMoreBefore: false,
    capabilities: {
      canSendText: false,
      canSendImages: false,
      canApprove: false,
      canAnswer: false,
      readOnlyReason,
    },
    pendingAction: null,
  };
}

function pendingChatAction(hook: HookSessionEvent | undefined): ChatPage["pendingAction"] {
  if (!hook?.expectsResponse || !hook.toolUseId || !hook.tool) return null;
  if (hook.tool === "AskUserQuestion") {
    const raw = Array.isArray(hook.toolInput?.questions) ? hook.toolInput.questions : [];
    const questions = raw.flatMap((value) => {
      if (typeof value !== "object" || value === null || Array.isArray(value)) return [];
      const question = value as Record<string, unknown>;
      const prompt = typeof question.question === "string" ? question.question.trim() : "";
      if (!prompt) return [];
      const options = Array.isArray(question.options) ? question.options : [];
      const choices = options.flatMap((option) => {
        if (typeof option === "string") return [option];
        if (typeof option !== "object" || option === null || Array.isArray(option)) return [];
        const label = (option as Record<string, unknown>).label;
        return typeof label === "string" && label.trim() ? [label.trim()] : [];
      });
      return [{
        id: prompt,
        question: prompt,
        choices,
        multiple: question.multiSelect === true,
      }];
    });
    return questions.length ? { type: "question", toolUseId: hook.toolUseId, questions } : null;
  }
  return {
    type: "approval",
    toolUseId: hook.toolUseId,
    toolName: hook.tool,
    input: hook.toolInput ?? {},
    canPersist: hook.permissionSuggestions !== undefined,
  };
}

function hookResponse(
  message: Extract<ClientMessage, { type: "respond_chat" }>,
  hook: HookSessionEvent,
): HookResponse {
  if (message.decision === "deny") {
    return { decision: "deny", ...(message.reason ? { reason: message.reason } : {}) };
  }
  if (message.decision === "answer") {
    return {
      decision: "allow",
      updated_input: {
        ...(hook.toolInput ?? {}),
        answers: Object.fromEntries(Object.entries(message.answers ?? {}).map(([question, answer]) => [
          question,
          Array.isArray(answer) ? answer.join(", ") : answer,
        ])),
      },
    };
  }
  return {
    decision: "allow",
    ...(message.reason ? { reason: message.reason } : {}),
    ...(message.decision === "allow_always" && hook.permissionSuggestions
      ? { updated_permissions: hook.permissionSuggestions } : {}),
  };
}

function normalize(discovered: DiscoveredProviderSession[]): SessionSummary[] {
  const byID = new Map<string, DiscoveredProviderSession>();
  for (const session of discovered) {
    const existing = byID.get(session.id);
    if (!existing || (session.authority ?? 1) > (existing.authority ?? 1)) {
      byID.set(session.id, session);
    }
  }

  return [...byID.values()]
    .map((session): SessionSummary => ({
      id: session.id,
      title: session.title?.trim() || `${providerNames[session.provider]} session`,
      subtitle: session.subtitle?.trim() ?? "",
      source: providerNames[session.provider],
      project: session.project?.trim() || path.basename(session.cwd) || session.cwd,
      owner: session.owner,
      cwd: session.cwd,
      section: session.section,
      updatedAt: session.updatedAt,
      canOpenOwner: session.canOpenOwner,
      canEnterChat: session.canEnterChat,
    }))
    .sort((left, right) =>
      right.updatedAt.localeCompare(left.updatedAt) || left.id.localeCompare(right.id));
}
