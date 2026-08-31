import {
  sessionSnapshotSchema,
  type ChatPage,
  type ChatCommands,
  type ClientMessage,
  type SessionSection,
  type ChatImage,
  type ChatItem,
  type ChatUsageGlance,
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
import { chatCapabilities, normalizeChatText, readChatPage } from "./chat.js";
import { loadSlashCommandCatalog } from "./slash-commands.js";

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
  codexLifecycle?: import("./providers/codex-lifecycle.js").CodexLifecycle;
};

export type ChatDeliveryEvidence = {
  /** Bounded IDs from the authoritative latest page before the send. */
  baselineUserEntryIds: string[];
  /** True only when the baseline page was not truncated before its oldest row. */
  baselineComplete: boolean;
  /** Provider-normalized text used only as a bounded fallback matcher. */
  submittedText: string;
  /** The daemon request identity, when the provider transcript preserves it. */
  requestId?: string;
  /** Renderer generation that owns this delivery's temporary resources. */
  generation?: number;
  /** False when the baseline probe was missing, empty, malformed, or partial. */
  authoritativeComplete?: boolean;
  /** Monotonic provider-time boundary for content-only fallback. */
  submittedAt?: string;
  /** Newest source timestamp in the authoritative baseline, when known. */
  baselineSourceTimestamp?: string;
};

/**
 * Operation-owned guard for a send that may wait behind native controls.
 * Implementations must check it at the provider-write boundary, not only
 * when the repository first admits the action.
 */
export type ChatSendCurrentness = () => boolean;

export type ChatCanonicalUserEntry = Pick<Extract<ChatItem, { kind: "user" }>,
  "id" | "text" | "requestId" | "deliveryId" | "providerMessageId">;

export interface SessionControls {
  /** False when the native helper cannot currently execute terminal actions. */
  isAvailable?(): boolean;
  focus(session: DiscoveredProviderSession): Promise<void>;
  send(
    session: DiscoveredProviderSession,
    text: string,
    images: ChatImage[],
    deliveryId?: string,
    evidence?: ChatDeliveryEvidence,
    isCurrent?: ChatSendCurrentness,
  ): Promise<void>;
  /** Return the exact live delivery targeted by the provider cancel route. */
  activeCancelDeliveryId?(session: DiscoveredProviderSession): string | undefined;
  /** Return true only when this exact live session has a provider cancel route. */
  canCancel?(session: DiscoveredProviderSession, deliveryId?: string): boolean;
  cancel?(session: DiscoveredProviderSession, deliveryId?: string): Promise<void>;
  /** Return true only when Claude's verified terminal can receive Shift+Tab. */
  canCyclePermissionMode?(session: DiscoveredProviderSession): boolean;
  cyclePermissionMode?(session: DiscoveredProviderSession): Promise<void>;
  /** Reconcile provider lifecycle and exact native target identity. */
  reconcile?(session: DiscoveredProviderSession): void;
  /** Reconcile a terminal delivery against authoritative canonical transcript rows. */
  reconcileChatPage?(
    session: DiscoveredProviderSession,
    page: ChatPage,
    authoritativeLatest?: boolean,
  ): void;
  /** Clear a completed or failed delivery from the native control registry. */
  clear?(sessionId: string, deliveryId?: string): void;
  /** Forget all state for a session that has left the authoritative catalog. */
  forget?(sessionId: string): void;
}

export interface SessionSnapshotSource {
  current(): SessionSnapshot;
  subscribe(listener: (snapshot: SessionSnapshot) => void): () => void;
  acknowledgeReady?(sessionId: string): void;
  chatPage?(
    sessionId: string,
    before?: number,
    limit?: number,
    generation?: number,
  ): Promise<ChatPage>;
  chatCommands?(sessionId: string): Promise<ChatCommands>;
  chatAction?(message: Extract<ClientMessage, {
    type: "send_chat" | "cancel_chat" | "respond_chat" | "cycle_permission_mode";
  }>): Promise<string | undefined>;
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
// ponytail: this bounds the pre-send transcript scan used to prove a new
// terminal turn. Keep it aligned with the page parser cap and raise it only
// with an explicit memory/latency review.
const maxTerminalBaselineUserEntryIds = 512;
// ponytail: bound queued + running chat operations per session before any
// transcript evidence or image payload is retained. Raise only with a
// memory/latency review; all exits release the operation reservation.
export const MAX_CHAT_ACTIONS_PER_SESSION = 32;

type SessionRepositoryOptions = {
  piRuntimeStatePath?: string;
  bootSessionUUID?: string;
  now?: () => Date;
  /** Deterministic page-read seam for proving async session replacement. */
  chatPageReader?: (
    session: DiscoveredProviderSession,
    before?: number,
    limit?: number,
  ) => Promise<ChatPage>;
  /** Optional provider-authoritative quota seam. Missing data stays absent. */
  chatUsageGlance?: (
    session: DiscoveredProviderSession,
  ) => Promise<ChatUsageGlance | undefined>;
};

type ChatStateOperationReservation = {
  epoch: number;
  active: boolean;
};

type ChatPageReadReservation = {
  /** Exact session key used to look up current state after the await. */
  sessionId: string;
  /** Monotonic read request for this session; newer work supersedes it. */
  requestEpoch: number;
  /** Session-state epoch rejects reads that outlive forget/reuse. */
  stateEpoch: number;
  /** Renderer generation and session identity guard the captured record. */
  generation: number;
  sessionFingerprint: string;
  /** Optional operation identity for a delivery-owned baseline read. */
  deliveryKey?: string;
  active: boolean;
};

type ChatSendInFlight = {
  epoch: number;
  reservation: ChatStateOperationReservation;
  promise: Promise<string | undefined>;
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

type ExternalApprovalState = "pending" | "responding" | "completed" | "uncertain";

type ExternalApprovalRecord = {
  approvalId: string;
  pending: ChatPendingAction;
  receivedAt: string;
  generation: number;
  respond: (message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void>;
  state: ExternalApprovalState;
  responseFingerprint?: string;
  responseToken: number;
  result?: string;
  inFlight?: Promise<string | undefined>;
  expiresAt: number;
  expiryTimer?: ReturnType<typeof setTimeout>;
};

// ponytail: completed approval results are retained briefly so a lost
// response can be replayed without invoking the provider twice. Keep this
// cap coordinated with the provider action queue and evict only terminal
// records; pending approvals are never silently replaced.
export const MAX_EXTERNAL_APPROVAL_RECORDS = 64;
export const EXTERNAL_APPROVAL_TTL_MS = 5 * 60_000;
export const EXTERNAL_APPROVAL_RESPONSE_TIMEOUT_MS = 30_000;

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
  private readonly externalActions = new Map<string, Map<string, ExternalApprovalRecord>>();
  private controls: SessionControls | undefined;
  private readonly now: () => Date;
  private readonly chatPageReader: NonNullable<SessionRepositoryOptions["chatPageReader"]>;
  private readonly chatUsageGlance: SessionRepositoryOptions["chatUsageGlance"];
  private readonly hookResponders = new Map<string, {
    sessionId: string;
    respond(response: HookResponse): void;
  }>();
  // Renderer generations are request identity, not provider state. Keep the
  // highest generation observed per live session so an old renderer cannot
  // send after an async transcript/evidence read.
  private readonly chatGenerationBySession = new Map<string, number>();
  private readonly chatSendRequestIdentity = new Map<string, string>();
  private readonly chatSendDeliveryIdentity = new Map<string, string>();
  private readonly chatSendIdentityOrder: Array<{
    sessionId: string;
    requestKey: string;
    deliveryKey: string;
    pairKey: string;
  }> = [];
  private readonly chatSendResults = new Map<string, string | undefined>();
  private readonly chatSendInFlight = new Map<string, ChatSendInFlight>();
  private readonly chatStateEpochBySession = new Map<string, number>();
  // Operation-owned reservations survive bounded epoch-history eviction. A
  // delayed provider result must stay stale after 513 unrelated removals and
  // old session-ID reuse; it cannot recreate dedupe/cache state.
  // ponytail: reservations are released in the operation finally path; add a
  // durable operation journal before retaining them beyond settled promises.
  private readonly chatStateReservationsBySession = new Map<string, Set<ChatStateOperationReservation>>();
  // A page/baseline reader is also operation-owned. Its monotonic request
  // epoch prevents an older transcript result from mutating native delivery
  // evidence after a newer page or delivery has started.
  private readonly chatPageRequestEpochBySession = new Map<string, number>();
  // Renderer page reads and delivery baselines have different ownership. A
  // new page invalidates older delivery baselines, while another admitted
  // send must not invalidate a concurrent send's exact reservation.
  private readonly chatPageReadReservationsBySession = new Map<string, ChatPageReadReservation>();
  private readonly chatDeliveryPageReadReservationsBySession = new Map<string, Set<ChatPageReadReservation>>();

  constructor(
    private readonly providers: ProviderAdapter[],
    options: SessionRepositoryOptions = {},
  ) {
    this.now = options.now ?? (() => new Date());
    this.chatPageReader = options.chatPageReader ?? readChatPage;
    this.chatUsageGlance = options.chatUsageGlance;
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
    return this.pendingActions(sessionId)[0];
  }

  /** Return every still-actionable approval/question for one exact session. */
  pendingActions(sessionId: string): ChatPendingAction[] {
    const external = [...(this.externalActions.get(sessionId)?.values() ?? [])]
      .filter((record) => record.state === "pending" || record.state === "responding")
      .sort((left, right) => left.receivedAt.localeCompare(right.receivedAt))
      .map((record) => ({
        ...structuredClone(record.pending),
        ...(record.state === "responding" ? { responding: true } : {}),
      }));
    const hook = pendingChatAction(this.hookBySession.get(sessionId));
    if (hook) external.push(structuredClone(hook));
    return external;
  }

  registerExternalAction(
    sessionId: string,
    pending: ChatPendingAction,
    respond: (message: Extract<ClientMessage, { type: "respond_chat" }>) => Promise<void>,
    generation?: number,
  ): () => void {
    this.pruneExternalActions(sessionId);
    const currentGeneration = this.chatGenerationBySession.get(sessionId) ?? 1;
    if (generation !== undefined && generation !== currentGeneration) {
      // Codex can finish registering an approval after a page refresh. Do
      // not attach that provider callback to the newer renderer generation.
      return () => undefined;
    }
    const approvalId = pending.approvalId ?? pending.toolUseId;
    let records = this.externalActions.get(sessionId);
    if (!records) {
      records = new Map();
      this.externalActions.set(sessionId, records);
    }
    const existing = records.get(approvalId);
    if (existing) {
      // A provider replay for the same approval must not replace its responder
      // or reset an in-flight response. The first exact route owns the ID.
      return () => undefined;
    }
    if (this.externalActionCount() >= MAX_EXTERNAL_APPROVAL_RECORDS) {
      // Fail closed when every retained record is actionable. The provider
      // remains unacknowledged rather than silently routing it to another ID.
      return () => undefined;
    }
    const receivedAt = new Date().toISOString();
    const record: ExternalApprovalRecord = {
      approvalId,
      pending: structuredClone(pending),
      receivedAt,
      generation: generation ?? currentGeneration,
      respond,
      state: "pending",
      responseToken: 0,
      expiresAt: Date.now() + EXTERNAL_APPROVAL_TTL_MS,
    };
    record.expiryTimer = setTimeout(() => this.expireExternalAction(sessionId, approvalId), EXTERNAL_APPROVAL_TTL_MS);
    record.expiryTimer.unref?.();
    records.set(approvalId, record);
    this.publish([...this.lastByProvider.values()].flat());
    return () => {
      const current = this.externalActions.get(sessionId)?.get(approvalId);
      if (current?.respond === respond && current.state === "pending") {
        if (current.expiryTimer) clearTimeout(current.expiryTimer);
        const currentRecords = this.externalActions.get(sessionId);
        currentRecords?.delete(approvalId);
        if (currentRecords?.size === 0) this.externalActions.delete(sessionId);
        this.publish([...this.lastByProvider.values()].flat());
      }
    };
  }

  private externalActionCount(): number {
    let count = 0;
    for (const records of this.externalActions.values()) count += records.size;
    return count;
  }

  private pruneExternalActions(sessionId?: string): void {
    const entries = sessionId === undefined
      ? [...this.externalActions.entries()]
      : [[sessionId, this.externalActions.get(sessionId)] as const];
    const now = Date.now();
    for (const [id, records] of entries) {
      if (!records) continue;
      for (const [approvalId, record] of records) {
        if (record.state === "pending" || record.state === "responding") continue;
        if (record.expiresAt > now) continue;
        if (record.expiryTimer) clearTimeout(record.expiryTimer);
        records.delete(approvalId);
      }
      if (records.size === 0) this.externalActions.delete(id);
    }
  }

  private expireExternalAction(sessionId: string, approvalId: string): void {
    const record = this.externalActions.get(sessionId)?.get(approvalId);
    if (!record) return;
    if (record.state === "pending" || record.state === "responding") {
      record.state = "uncertain";
      record.result = "This approval expired before the provider confirmed it.";
      record.responseToken += 1;
      record.inFlight = undefined;
      record.expiresAt = Date.now() + EXTERNAL_APPROVAL_TTL_MS;
      record.expiryTimer = setTimeout(
        () => this.expireExternalAction(sessionId, approvalId),
        EXTERNAL_APPROVAL_TTL_MS,
      );
      record.expiryTimer.unref?.();
      this.publish([...this.lastByProvider.values()].flat());
      return;
    }
    const records = this.externalActions.get(sessionId);
    records?.delete(approvalId);
    if (records?.size === 0) this.externalActions.delete(sessionId);
  }

  private invalidateExternalActions(sessionId: string, reason: string): void {
    const records = this.externalActions.get(sessionId);
    if (!records) return;
    for (const record of records.values()) {
      if (record.state === "completed" || record.state === "uncertain") continue;
      record.state = "uncertain";
      record.result = reason;
      record.responseToken += 1;
      record.inFlight = undefined;
      if (record.expiryTimer) clearTimeout(record.expiryTimer);
      record.expiresAt = Date.now() + EXTERNAL_APPROVAL_TTL_MS;
      record.expiryTimer = setTimeout(
        () => this.expireExternalAction(sessionId, record.approvalId),
        EXTERNAL_APPROVAL_TTL_MS,
      );
      record.expiryTimer.unref?.();
    }
  }

  private respondExternalAction(
    sessionId: string,
    message: Extract<ClientMessage, { type: "respond_chat" }>,
  ): Promise<string | undefined> {
    const approvalId = message.approvalId ?? message.toolUseId;
    const record = this.externalActions.get(sessionId)?.get(approvalId);
    if (!record || record.pending.toolUseId !== message.toolUseId) {
      return Promise.resolve("This approval is no longer waiting for a response.");
    }
    if (message.generation !== undefined && message.generation !== record.generation) {
      return Promise.resolve("This approval belongs to an older session generation.");
    }
    const responseFingerprint = responseIdentity(message);
    if (record.state === "completed" || record.state === "uncertain") {
      if (record.responseFingerprint === undefined
        || record.responseFingerprint === responseFingerprint) {
        return Promise.resolve(record.result);
      }
      return Promise.resolve("This approval already has a different response.");
    }
    if (record.state === "responding") {
      if (record.responseFingerprint !== responseFingerprint) {
        return Promise.resolve("This approval is already responding with a different response.");
      }
      return record.inFlight ?? Promise.resolve("This approval response is still settling.");
    }
    // Reserve the exact approval synchronously before entering provider code.
    record.state = "responding";
    record.responseFingerprint = responseFingerprint;
    const responseToken = ++record.responseToken;
    const operation = this.invokeExternalResponse(sessionId, record, message, responseToken);
    record.inFlight = operation;
    return operation;
  }

  private async invokeExternalResponse(
    sessionId: string,
    record: ExternalApprovalRecord,
    message: Extract<ClientMessage, { type: "respond_chat" }>,
    responseToken: number,
  ): Promise<string | undefined> {
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const provider = Promise.resolve()
      .then(() => record.respond(message))
      .then(() => undefined, (error: unknown) => (
        error instanceof Error ? error.message : "The provider rejected this approval."
      ));
    const deadline = new Promise<string>((resolve) => {
      timeout = setTimeout(() => resolve("The provider approval response timed out."), EXTERNAL_APPROVAL_RESPONSE_TIMEOUT_MS);
      timeout.unref?.();
    });
    const result = await Promise.race([provider, deadline]);
    if (timeout) clearTimeout(timeout);
    if (record.responseToken !== responseToken || record.state !== "responding") {
      return record.result;
    }
    record.inFlight = undefined;
    record.result = result;
    record.state = result === undefined ? "completed" : "uncertain";
    record.expiresAt = Date.now() + EXTERNAL_APPROVAL_TTL_MS;
    if (record.expiryTimer) clearTimeout(record.expiryTimer);
    record.expiryTimer = setTimeout(
      () => this.expireExternalAction(
        sessionId,
        record.approvalId,
      ),
      EXTERNAL_APPROVAL_TTL_MS,
    );
    // sessionId is intentionally not taken from the response payload: use the
    // exact registration scope when scheduling result-cache cleanup.
    record.expiryTimer.unref?.();
    return result;
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

  async chatPage(
    sessionId: string,
    before?: number,
    limit?: number,
    generation?: number,
  ): Promise<ChatPage> {
    const hook = this.hookBySession.get(sessionId);
    const discovered = this.chatBySession.get(sessionId);
    const record = discovered ?? (hook ? hookSession(hook) : undefined);
    if (!record) {
      this.controls?.clear?.(sessionId);
      return unavailableChatPage(sessionId, "This session is no longer available.");
    }
    const generationError = generation === undefined
      ? this.ensureChatGeneration(sessionId)
      : this.acceptAuthoritativeChatGeneration(
        sessionId, generation, before === undefined,
      );
    if (generationError) {
      return unavailableChatPage(sessionId, generationError);
    }
    const pageGeneration = this.chatGenerationBySession.get(sessionId);
    if (pageGeneration === undefined) {
      return unavailableChatPage(sessionId, "This chat session has no authoritative generation.");
    }
    const pageReservation = this.reserveChatPageRead(
      sessionId,
      pageGeneration,
      record,
    );
    this.controls?.reconcile?.(record);
    try {
      const page = await this.chatPageReader(record, before, limit);
      // Revalidate before any post-read native reconciliation or capability
      // mutation. A late R1 is data for the renderer only; it cannot rewind
      // delivery evidence established by a newer R2/baseline.
      if (!this.isChatPageReadCurrent(pageReservation)) return page;
      if (before === undefined && this.chatUsageGlance) {
        try {
          const usage = await this.chatUsageGlance(record);
          const providerMatches = (record.provider === "codex" && usage?.provider === "codex")
            || (record.provider === "claude_code" && usage?.provider === "claude");
          if (this.isChatPageReadCurrent(pageReservation) && providerMatches && usage) {
            page.metadata = { ...(page.metadata ?? {}), usageGlance: usage };
          }
        } catch {
          // Usage is an optional status enhancement. A provider/tool failure
          // must leave the page valid and omit the value, never fabricate it.
        }
      }
      // Earlier pages are renderer history, never authoritative native
      // delivery evidence. Keep this call latest-only so a future control
      // implementation cannot accidentally treat `false` as permission.
      if (before === undefined) {
        this.controls?.reconcileChatPage?.(record, page, true);
      }
      if (record.messageTransport === "terminal" && this.controls?.isAvailable?.() === false) {
        const readOnlyReason = "The native helper is unavailable. Terminal chat is read only until it recovers.";
        page.capabilities.canSendText = false;
        page.capabilities.canSendImages = false;
        page.capabilities.canCancel = false;
        delete page.capabilities.cancelDeliveryId;
        page.capabilities.readOnlyReason = readOnlyReason;
      }
      const canCyclePermissionMode = page.capabilities.canCyclePermissionMode === true
        && this.controls?.canCyclePermissionMode?.(record) === true;
      page.capabilities.canCyclePermissionMode = canCyclePermissionMode;
      // A transcript transport is not enough to cancel. Keep the page honest
      // when the daemon has no live helper or daemon-owned Codex turn. The
      // capability and identity are derived from one live control lookup so a
      // page cannot advertise a route for an unrelated delivery.
      const cancelDeliveryId = this.controls?.activeCancelDeliveryId?.(record);
      const canCancel = cancelDeliveryId !== undefined
        && (this.controls?.canCancel?.(record, cancelDeliveryId) ?? false);
      page.capabilities.canCancel = canCancel;
      if (canCancel) page.capabilities.cancelDeliveryId = cancelDeliveryId;
      else delete page.capabilities.cancelDeliveryId;
      const pendingActions = this.pendingActions(sessionId);
      if (pendingActions.length) {
        page.pendingAction = pendingActions[0] ?? null;
        page.pendingActions = pendingActions;
        page.capabilities.canApprove = pendingActions.some((action) => action.type === "approval");
        page.capabilities.canAnswer = pendingActions.some((action) => action.type === "question");
      }
      return page;
    } finally {
      this.releaseChatPageRead(sessionId, pageReservation);
    }
  }

  async chatCommands(sessionId: string): Promise<ChatCommands> {
    const session = this.chatBySession.get(sessionId)
      ?? (this.hookBySession.get(sessionId)
        ? hookSession(this.hookBySession.get(sessionId)!)
        : undefined);
    if (!session) {
      return { type: "chat_commands", sessionId, commands: [], truncated: false };
    }
    const catalog = await loadSlashCommandCatalog(session.cwd);
    return {
      type: "chat_commands",
      sessionId,
      ...catalog,
    };
  }

  async focusSession(sessionId: string): Promise<string | undefined> {
    const session = this.controlBySession.get(sessionId);
    if (!session?.controlTarget || !this.controls) return "Exact session focus is unavailable.";
    const reservation = this.reserveChatStateOperation(
      sessionId,
      this.chatStateEpoch(sessionId),
    );
    if (!reservation) {
      return "Too many chat actions are queued for this session.";
    }
    this.acknowledgeReady(sessionId);
    try {
      await this.controls.focus(structuredClone(session));
      return undefined;
    } catch (error) {
      return error instanceof Error ? error.message : "Exact session focus failed.";
    } finally {
      this.releaseChatStateOperation(sessionId, reservation);
    }
  }

  acknowledgeReady(sessionId: string): void {
    const session = this.snapshotValue.sessions.find(({ id }) => id === sessionId);
    if (session?.section !== "ready" || this.acknowledgedReadyIDs.has(sessionId)) return;
    this.acknowledgedReadyIDs.add(sessionId);
    this.publish([...this.lastByProvider.values()].flat());
  }

  async chatAction(
    message: Extract<ClientMessage, {
      type: "send_chat" | "cancel_chat" | "respond_chat" | "cycle_permission_mode";
    }>,
  ): Promise<string | undefined> {
    if (message.type === "cycle_permission_mode") {
      const stateEpoch = this.chatStateEpoch(message.sessionId);
      const generationError = this.acceptChatGeneration(message.sessionId, message.generation);
      if (generationError) return generationError;
      const reservation = this.reserveChatStateOperation(message.sessionId, stateEpoch);
      if (!reservation) return "Too many chat actions are queued for this session.";
      try {
        const session = this.chatBySession.get(message.sessionId);
        if (!session || !this.controls?.cyclePermissionMode
          || !this.controls.canCyclePermissionMode?.(session)
          || !chatCapabilities(session).canCyclePermissionMode) {
          return "Permission mode cycling is unavailable for this session.";
        }
        const latest = await this.chatPageReader(
          session,
          undefined,
          maxTerminalBaselineUserEntryIds,
        );
        if (!this.isChatOperationCurrent(message.sessionId, stateEpoch, reservation)) {
          return "This chat session changed before permission mode could be changed.";
        }
        if (latest.metadata?.permissionMode !== message.expectedMode) {
          return "Permission mode changed before this request was delivered.";
        }
        await this.controls.cyclePermissionMode(structuredClone(session));
        if (!this.isChatOperationCurrent(message.sessionId, stateEpoch, reservation)) {
          return "This chat session changed before permission mode could be confirmed.";
        }
        return undefined;
      } catch (error) {
        return error instanceof Error ? error.message : "Permission mode could not be changed.";
      } finally {
        this.releaseChatStateOperation(message.sessionId, reservation);
      }
    }
    if (message.type === "send_chat") {
      const session = this.chatBySession.get(message.sessionId);
      const stateEpoch = this.chatStateEpoch(message.sessionId);
      const generationError = this.acceptChatGeneration(message.sessionId, message.generation);
      if (generationError) return generationError;
      const requestKey = chatSendRequestKey(message.sessionId, message.generation, message.id);
      const deliveryKey = chatSendDeliveryKey(
        message.sessionId, message.generation, message.deliveryId,
      );
      const pairKey = chatSendPairKey(
        message.sessionId, message.generation, message.id, message.deliveryId,
      );
      const inFlight = this.chatSendInFlight.get(pairKey);
      if (inFlight) {
        if (inFlight.reservation.active && inFlight.epoch === stateEpoch) return inFlight.promise;
        // A prior operation for this exact identity is still settling after
        // the session was removed/replaced. Never let the replacement
        // coalesce with that stale provider work.
        return "A previous send with this identity is still settling.";
      }
      const previousDelivery = this.chatSendRequestIdentity.get(requestKey);
      if (previousDelivery !== undefined && previousDelivery !== message.deliveryId) {
        return "This send request ID was already used for another delivery.";
      }
      const previousRequest = this.chatSendDeliveryIdentity.get(deliveryKey);
      if (previousRequest !== undefined && previousRequest !== message.id) {
        return "This delivery ID was already used for another request.";
      }
      const isNewIdentity = previousDelivery === undefined && previousRequest === undefined;
      if (!isNewIdentity && (previousDelivery !== message.deliveryId || previousRequest !== message.id)) {
        // A partially retained pair is an internal inconsistency. Fail closed
        // instead of reconstructing identity from one side of the registry.
        return "This send identity was already used by another request.";
      }
      if (this.chatSendResults.has(pairKey)) return this.chatSendResults.get(pairKey);
      const reservation = this.reserveChatStateOperation(message.sessionId, stateEpoch);
      if (!reservation) {
        return "Too many chat actions are queued for this session.";
      }
      if (isNewIdentity) {
        this.chatSendRequestIdentity.set(requestKey, message.deliveryId);
        this.chatSendDeliveryIdentity.set(deliveryKey, message.id);
        this.chatSendIdentityOrder.push({
          sessionId: message.sessionId, requestKey, deliveryKey, pairKey,
        });
        this.trimChatSendIdentityWindow();
      }
      const operation = this.performChatSend(
        message,
        session,
        () => this.isChatOperationCurrent(message.sessionId, stateEpoch, reservation),
        pairKey,
      );
      this.chatSendInFlight.set(pairKey, {
        epoch: stateEpoch,
        reservation,
        promise: operation,
      });
      let result: string | undefined;
      let operationWasCurrent = false;
      try {
        result = await operation;
        operationWasCurrent = this.isChatOperationCurrent(
          message.sessionId, stateEpoch, reservation,
        );
      } finally {
        this.releaseChatStateOperation(message.sessionId, reservation);
        if (this.chatSendInFlight.get(pairKey)?.promise === operation) {
          this.chatSendInFlight.delete(pairKey);
        }
      }
      // A removed session may have invalidated this operation while its
      // provider/evidence await was in flight. Do not resurrect its dedupe
      // result or any identity reservation after forgetChatState().
      if (!operationWasCurrent) {
        return "This chat session changed before the message could be delivered.";
      }
      this.chatSendResults.set(pairKey, result);
      // ponytail: this is a bounded replay-dedup window. Add a durable
      // request cursor before increasing it so renderer retries stay safe.
      while (this.chatSendResults.size > 512) {
        this.chatSendResults.delete(this.chatSendResults.keys().next().value!);
      }
      return result;
    }
    if (message.type === "cancel_chat") {
      const stateEpoch = this.chatStateEpoch(message.sessionId);
      const generationError = this.acceptChatGeneration(message.sessionId, message.generation);
      if (generationError) return generationError;
      const reservation = this.reserveChatStateOperation(message.sessionId, stateEpoch);
      if (!reservation) {
        return "Too many chat actions are queued for this session.";
      }
      try {
      const session = this.chatBySession.get(message.sessionId);
      // Re-read the latest canonical page before a terminal Escape. This is
      // the last authoritative opportunity to reject an external same-target
      // turn that arrived since the renderer's previous page refresh.
      if (session && this.controls?.reconcileChatPage) {
        const pageReservation = this.reserveChatPageRead(
          message.sessionId,
          message.generation,
          session,
        );
        try {
          const latest = await this.chatPageReader(session, undefined, maxTerminalBaselineUserEntryIds);
          if (this.isChatOperationCurrent(message.sessionId, stateEpoch, reservation)
            && this.isChatPageReadCurrent(pageReservation)) {
            this.controls.reconcileChatPage(session, latest, true);
          }
        } catch {
          if (this.isChatOperationCurrent(message.sessionId, stateEpoch, reservation)
            && this.isChatPageReadCurrent(pageReservation)) {
            this.controls.clear?.(message.sessionId, message.deliveryId);
          }
        } finally {
          this.releaseChatPageRead(message.sessionId, pageReservation);
        }
      }
      if (!session || !message.deliveryId || !this.controls?.canCancel?.(session, message.deliveryId)
        || !this.controls.cancel) {
        return "Cancellation is unavailable for this session.";
      }
      if (!this.isChatOperationCurrent(message.sessionId, stateEpoch, reservation)) {
        return "This chat session changed before cancellation could be delivered.";
      }
      try {
        await this.controls.cancel(structuredClone(session), message.deliveryId);
        if (!this.isChatOperationCurrent(message.sessionId, stateEpoch, reservation)) {
          return "This chat session changed before cancellation could be confirmed.";
        }
        this.controls.clear?.(message.sessionId, message.deliveryId);
        return undefined;
      } catch (error) {
        return error instanceof Error ? error.message : "The turn could not be cancelled.";
      }
      } finally {
        this.releaseChatStateOperation(message.sessionId, reservation);
      }
    }
    const approvalKey = message.approvalId ?? message.toolUseId;
    const externalRecords = this.externalActions.get(message.sessionId);
    if (externalRecords?.has(approvalKey)
      || [...(externalRecords?.values() ?? [])].some((record) => (
        record.pending.toolUseId === message.toolUseId
      ))) {
      const result = await this.respondExternalAction(message.sessionId, message);
      this.publish([...this.lastByProvider.values()].flat());
      return result;
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

  private async performChatSend(
    message: Extract<ClientMessage, { type: "send_chat" }>,
    initialSession: DiscoveredProviderSession | undefined,
    operationIsCurrent: () => boolean,
    deliveryKey: string,
  ): Promise<string | undefined> {
    const capabilities = initialSession ? chatCapabilities(initialSession) : undefined;
    if (!initialSession || !this.controls || !capabilities?.canSendText) {
      return "Chat sending is unavailable for this session.";
    }
    if (initialSession.messageTransport === "terminal" && this.controls.isAvailable?.() === false) {
      return "The native helper is unavailable. Terminal chat is read only until it recovers.";
    }
    if (message.images.length > 0 && !capabilities.canSendImages) {
      return "Image sending is unavailable for this session.";
    }
    const initialFingerprint = sessionActionFingerprint(initialSession);
    const submittedAt = this.now().toISOString();
    // A delivery baseline supersedes any page read that started earlier. The
    // baseline itself owns an exact page-read reservation, but
    // concurrent sends must remain independent: one send cannot make every
    // other admitted send stale merely because their evidence reads overlap.
    const pageReservation = isTerminalChatRoute(initialSession)
      ? (() => {
        this.invalidateChatPageReads(message.sessionId);
        return this.reserveChatPageRead(
          message.sessionId,
          message.generation,
          initialSession,
          deliveryKey,
        );
      })()
      : undefined;
    const isCurrent = (): boolean => {
      if (!operationIsCurrent()) return false;
      if (pageReservation && !this.isChatPageReadCurrent(pageReservation)) return false;
      const currentSession = this.chatBySession.get(message.sessionId);
      return currentSession !== undefined
        && this.chatGenerationBySession.get(message.sessionId) === message.generation
        && sessionActionFingerprint(currentSession) === initialFingerprint
        && chatCapabilities(currentSession).canSendText
        && (message.images.length === 0 || chatCapabilities(currentSession).canSendImages);
    };
    try {
      const evidence = await captureTerminalDeliveryEvidence(
        initialSession,
        message.text,
        message.id,
        message.images,
        this.chatPageReader,
        message.generation,
        submittedAt,
      );
      if ((pageReservation && !this.isChatPageReadCurrent(pageReservation)) || !operationIsCurrent()) {
        return "This chat session changed before the message could be delivered.";
      }
      const session = this.chatBySession.get(message.sessionId);
      const generation = this.chatGenerationBySession.get(message.sessionId);
      const liveCapabilities = session ? chatCapabilities(session) : undefined;
      if (!session
        || generation !== message.generation
        || sessionActionFingerprint(session) !== initialFingerprint
        || !liveCapabilities?.canSendText
        || (message.images.length > 0 && !liveCapabilities.canSendImages)) {
        return "This chat session changed before the message could be delivered.";
      }
      if (session.messageTransport === "terminal" && this.controls.isAvailable?.() === false) {
        return "The native helper is unavailable. Terminal chat is read only until it recovers.";
      }
      await this.controls.send(
        structuredClone(session), message.text, message.images, message.deliveryId, evidence,
        isCurrent,
      );
      return undefined;
    } catch (error) {
      // A queued native action can fail after its repository operation has
      // become stale. Never let that old failure clear a replacement control
      // record with the same delivery ID.
      if (isCurrent()) this.controls.clear?.(message.sessionId, message.deliveryId);
      return error instanceof Error ? error.message : "The message could not be delivered.";
    } finally {
      if (pageReservation) this.releaseChatPageRead(message.sessionId, pageReservation);
    }
  }

  private acceptChatGeneration(sessionId: string, generation: number): string | undefined {
    const current = this.chatGenerationBySession.get(sessionId);
    if (current === undefined) {
      return "This chat session has no authoritative generation.";
    }
    if (generation < current) {
      return "This chat request belongs to an older session view.";
    }
    if (generation > current) {
      return "This chat request belongs to a future session generation.";
    }
    return undefined;
  }

  private ensureChatGeneration(sessionId: string): string | undefined {
    if (this.chatGenerationBySession.has(sessionId)) return undefined;
    this.chatGenerationBySession.set(sessionId, 1);
    this.trimChatGenerationWindow();
    return undefined;
  }

  private acceptAuthoritativeChatGeneration(
    sessionId: string,
    generation: number,
    latest: boolean,
  ): string | undefined {
    const current = this.chatGenerationBySession.get(sessionId);
    if (current === undefined) {
      if (generation !== 1) {
        return "This chat open belongs to a future session generation.";
      }
      this.chatGenerationBySession.set(sessionId, generation);
      this.trimChatGenerationWindow();
      return undefined;
    }
    if (generation === current) return undefined;
    if (!latest || generation !== current + 1) {
      return generation < current
        ? "This chat open belongs to an older session generation."
        : "This chat open belongs to a future session generation.";
    }
    this.chatGenerationBySession.set(sessionId, generation);
    this.invalidateExternalActions(
      sessionId,
      "This approval belongs to an older session generation.",
    );
    return undefined;
  }

  private trimChatGenerationWindow(): void {
    // ponytail: bound renderer-generation state to the same 512-session
    // identity window as send dedupe; use a durable session cursor before
    // increasing this ceiling.
    while (this.chatGenerationBySession.size > 512) {
      this.chatGenerationBySession.delete(this.chatGenerationBySession.keys().next().value!);
    }
  }

  private chatStateEpoch(sessionId: string): number {
    return this.chatStateEpochBySession.get(sessionId) ?? 0;
  }

  private isChatStateCurrent(sessionId: string, epoch: number): boolean {
    return this.chatStateEpoch(sessionId) === epoch;
  }

  private reserveChatStateOperation(
    sessionId: string,
    epoch: number,
  ): ChatStateOperationReservation | undefined {
    const existing = this.chatStateReservationsBySession.get(sessionId);
    if ((existing?.size ?? 0) >= MAX_CHAT_ACTIONS_PER_SESSION) return undefined;
    const reservation: ChatStateOperationReservation = { epoch, active: true };
    let reservations = existing;
    if (!reservations) {
      reservations = new Set();
      this.chatStateReservationsBySession.set(sessionId, reservations);
    }
    reservations.add(reservation);
    return reservation;
  }

  private releaseChatStateOperation(
    sessionId: string,
    reservation: ChatStateOperationReservation,
  ): void {
    reservation.active = false;
    const reservations = this.chatStateReservationsBySession.get(sessionId);
    if (!reservations) return;
    reservations.delete(reservation);
    if (reservations.size === 0) this.chatStateReservationsBySession.delete(sessionId);
  }

  private isChatOperationCurrent(
    sessionId: string,
    epoch: number,
    reservation: ChatStateOperationReservation,
  ): boolean {
    return reservation.active && this.isChatStateCurrent(sessionId, epoch);
  }

  private reserveChatPageRead(
    sessionId: string,
    generation: number,
    session: DiscoveredProviderSession,
    deliveryKey?: string,
  ): ChatPageReadReservation {
    const currentEpoch = this.chatPageRequestEpochBySession.get(sessionId) ?? 0;
    const requestEpoch = deliveryKey === undefined ? currentEpoch + 1 : currentEpoch;
    if (!this.chatPageRequestEpochBySession.has(sessionId)) {
      this.chatPageRequestEpochBySession.set(sessionId, currentEpoch);
    }
    const reservation: ChatPageReadReservation = {
      sessionId,
      requestEpoch,
      stateEpoch: this.chatStateEpoch(sessionId),
      generation,
      sessionFingerprint: sessionActionFingerprint(session),
      ...(deliveryKey !== undefined ? { deliveryKey } : {}),
      active: true,
    };
    if (deliveryKey === undefined) {
      this.chatPageRequestEpochBySession.set(sessionId, requestEpoch);
      const previous = this.chatPageReadReservationsBySession.get(sessionId);
      if (previous) previous.active = false;
      this.chatPageReadReservationsBySession.set(sessionId, reservation);
    } else {
      let reservations = this.chatDeliveryPageReadReservationsBySession.get(sessionId);
      if (!reservations) {
        reservations = new Set();
        this.chatDeliveryPageReadReservationsBySession.set(sessionId, reservations);
      }
      reservations.add(reservation);
    }
    return reservation;
  }

  private releaseChatPageRead(
    sessionId: string,
    reservation: ChatPageReadReservation,
  ): void {
    reservation.active = false;
    if (this.chatPageReadReservationsBySession.get(sessionId) === reservation) {
      this.chatPageReadReservationsBySession.delete(sessionId);
    }
    const deliveryReservations = this.chatDeliveryPageReadReservationsBySession.get(sessionId);
    if (deliveryReservations) {
      deliveryReservations.delete(reservation);
      if (deliveryReservations.size === 0) {
        this.chatDeliveryPageReadReservationsBySession.delete(sessionId);
      }
    }
  }

  private invalidateChatPageReads(sessionId: string): void {
    // A new terminal delivery owns the next evidence boundary. Invalidate
    // only the renderer page reservation; concurrent delivery baselines keep
    // their own operation reservations and may proceed independently.
    const pageReservation = this.chatPageReadReservationsBySession.get(sessionId);
    if (pageReservation) pageReservation.active = false;
    this.chatPageReadReservationsBySession.delete(sessionId);
  }

  private isChatPageReadCurrent(reservation: ChatPageReadReservation): boolean {
    if (!reservation.active) return false;
    const currentSession = this.chatBySession.get(reservation.sessionId)
      ?? (this.hookBySession.has(reservation.sessionId)
        ? hookSession(this.hookBySession.get(reservation.sessionId)!)
        : undefined);
    return this.chatStateEpoch(reservation.sessionId) === reservation.stateEpoch
      && this.chatPageRequestEpochBySession.get(reservation.sessionId) === reservation.requestEpoch
      && this.chatGenerationBySession.get(reservation.sessionId) === reservation.generation
      && currentSession !== undefined
      && sessionActionFingerprint(currentSession) === reservation.sessionFingerprint;
  }

  private forgetChatState(sessionId: string): void {
    this.chatStateEpochBySession.set(sessionId, this.chatStateEpoch(sessionId) + 1);
    // In-flight operations carry their own reservation because the bounded
    // epoch tombstone may later be reclaimed. Invalidate those reservations
    // now; releaseChatStateOperation removes them only after the provider
    // promise has actually settled.
    for (const reservation of this.chatStateReservationsBySession.get(sessionId) ?? []) {
      reservation.active = false;
    }
    const pageReservation = this.chatPageReadReservationsBySession.get(sessionId);
    if (pageReservation) pageReservation.active = false;
    this.chatPageReadReservationsBySession.delete(sessionId);
    for (const reservation of this.chatDeliveryPageReadReservationsBySession.get(sessionId) ?? []) {
      reservation.active = false;
    }
    this.chatDeliveryPageReadReservationsBySession.delete(sessionId);
    this.chatPageRequestEpochBySession.delete(sessionId);
    this.invalidateExternalActions(sessionId, "This approval session is no longer available.");
    this.chatGenerationBySession.delete(sessionId);
    for (const entry of this.chatSendIdentityOrder) {
      if (entry.sessionId !== sessionId) continue;
      this.chatSendRequestIdentity.delete(entry.requestKey);
      this.chatSendDeliveryIdentity.delete(entry.deliveryKey);
      this.chatSendResults.delete(entry.pairKey);
    }
    for (let index = this.chatSendIdentityOrder.length - 1; index >= 0; index -= 1) {
      if (this.chatSendIdentityOrder[index]!.sessionId === sessionId) {
        this.chatSendIdentityOrder.splice(index, 1);
      }
    }
    // ponytail: this epoch map is only a bounded stale-operation tombstone;
    // removed session state above is deleted immediately.
    while (this.chatStateEpochBySession.size > 512) {
      this.chatStateEpochBySession.delete(this.chatStateEpochBySession.keys().next().value!);
    }
  }

  private trimChatSendIdentityWindow(): void {
    // Keep request and delivery reservations as one-to-one pairs. Do not
    // evict an in-flight pair; if all old entries are in flight, a temporary
    // overshoot is safer than allowing a replay to issue a duplicate send.
    while (this.chatSendIdentityOrder.length > 512) {
      const index = this.chatSendIdentityOrder.findIndex(
        (entry) => !this.chatSendInFlight.has(entry.pairKey),
      );
      if (index < 0) return;
      const [entry] = this.chatSendIdentityOrder.splice(index, 1);
      if (!entry) return;
      this.chatSendRequestIdentity.delete(entry.requestKey);
      this.chatSendDeliveryIdentity.delete(entry.deliveryKey);
      this.chatSendResults.delete(entry.pairKey);
    }
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
      if (this.pendingActions(record.id).some((action) => action.type === "approval" || action.type === "question")) {
        record.section = "needs_you";
        record.subtitle = "Approval required";
        const latestApproval = [...(this.externalActions.get(record.id)?.values() ?? [])]
          .find((action) => action.state === "pending");
        record.updatedAt = latestApproval?.receivedAt ?? new Date().toISOString();
      }
      // Codex's discovery age gate applies to source-only history, not a
      // tracked Ready/working/Needs-you session with a canonical transcript.
      // Chat send/cancel authority remains separate from this read-only entry.
      if (record.provider === "codex" && record.owner === "Codex"
        && record.section !== "history" && record.chatPath) {
        record.canEnterChat = true;
      }
    }
    const previousControlSessionIDs = new Set(this.controlBySession.keys());
    this.controlBySession.clear();
    for (const record of merged) {
      const existing = this.controlBySession.get(record.id);
      if (!existing || (record.authority ?? 1) > (existing.authority ?? 1)) {
        this.controlBySession.set(record.id, structuredClone(record));
      }
    }
    const sessions = normalize(merged);
    for (const sessionId of previousControlSessionIDs) {
      if (!this.controlBySession.has(sessionId)) {
        this.controls?.forget?.(sessionId);
        this.forgetChatState(sessionId);
      }
    }
    for (const session of this.controlBySession.values()) {
      this.ensureChatGeneration(session.id);
      this.controls?.reconcile?.(session);
    }
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
      // ponytail: desktop Codex can omit or deliver stale turn hooks. Never let
      // those replace the lifecycle boundary read from its own transcript.
      if (existing.codexLifecycle) {
        const approvalDuringTurn = existing.codexLifecycle.phase === "working"
          && phase.section === "needs_you"
          && hook.receivedAt >= existing.codexLifecycle.observedAt;
        if (!approvalDuringTurn) continue;
      }
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
      canCancel: false,
      canApprove: false,
      canAnswer: false,
      readOnlyReason,
    },
    pendingAction: null,
  };
}

async function captureTerminalDeliveryEvidence(
  session: DiscoveredProviderSession,
  text: string,
  requestId: string,
  _images: ChatImage[] = [],
  pageReader: (
    session: DiscoveredProviderSession,
    before?: number,
    limit?: number,
  ) => Promise<ChatPage> = readChatPage,
  generation?: number,
  submittedAt?: string,
): Promise<ChatDeliveryEvidence | undefined> {
  if (!isTerminalChatRoute(session)) return undefined;
  try {
    const page = await pageReader(session, undefined, maxTerminalBaselineUserEntryIds);
    const baselineUserEntryIds: string[] = [];
    const seen = new Set<string>();
    for (const item of page.items) {
      if (item.kind !== "user" || seen.has(item.id)) continue;
      seen.add(item.id);
      baselineUserEntryIds.push(item.id);
      if (baselineUserEntryIds.length >= maxTerminalBaselineUserEntryIds) break;
    }
    return {
      baselineUserEntryIds,
      baselineComplete: page.transcriptEvidence?.complete ?? !page.hasMoreBefore,
      // NativeSessionControls replaces this provisional text with Pi's exact
      // path-bearing prompt after it allocates image files. The text-only
      // fallback remains useful for Claude and for providers that omit IDs.
      submittedText: normalizeChatText(text),
      requestId,
      ...(generation !== undefined ? { generation } : {}),
      ...(submittedAt ? { submittedAt } : {}),
      // A custom/failed reader that does not provide an authority record is
      // deliberately non-authoritative. Exact provider identity can still
      // reconcile, but content-only fallback stays disabled.
      authoritativeComplete: page.transcriptEvidence?.authoritative === true
        && page.transcriptEvidence.complete === true,
      ...(page.transcriptEvidence?.sourceTimestamp
        ? { baselineSourceTimestamp: page.transcriptEvidence.sourceTimestamp }
        : {}),
    };
  } catch {
    // Sending may still be valid when a transcript is being rewritten, but
    // cancellation must remain fail-closed until a baseline is available.
    return undefined;
  }
}

function sessionActionFingerprint(session: DiscoveredProviderSession): string {
  return JSON.stringify([
    session.id,
    session.provider,
    session.section,
    session.cwd,
    session.chatPath,
    session.messageTransport,
    session.controlTarget,
  ]);
}

function chatSendRequestKey(sessionId: string, generation: number, requestId: string): string {
  return JSON.stringify([sessionId, generation, requestId]);
}

function chatSendDeliveryKey(sessionId: string, generation: number, deliveryId: string): string {
  return JSON.stringify([sessionId, generation, deliveryId]);
}

function chatSendPairKey(
  sessionId: string,
  generation: number,
  requestId: string,
  deliveryId: string,
): string {
  return JSON.stringify([sessionId, generation, requestId, deliveryId]);
}

function isTerminalChatRoute(session: DiscoveredProviderSession): boolean {
  return session.section === "working"
    && session.messageTransport === "terminal"
    && session.controlTarget?.kind === "terminal"
    && (session.provider === "claude_code" || session.provider === "pi");
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

function responseIdentity(
  message: Extract<ClientMessage, { type: "respond_chat" }>,
): string {
  return JSON.stringify({
    decision: message.decision,
    reason: message.reason ?? "",
    answers: Object.entries(message.answers ?? {})
      .sort(([left], [right]) => left.localeCompare(right)),
  });
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
