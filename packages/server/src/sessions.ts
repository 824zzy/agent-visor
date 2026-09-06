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
  type ChatSettings,
  type ChatSettingsPatch,
  type ChatSettingsUpdate,
  type NativeHelperFocusTarget,
  type NativeHelperPiRestorationUpdate,
  type NativeHelperTerminalTarget,
  type SessionClass,
  type SessionConversationState,
  type SessionRouteOwnership,
  type SessionRouteState,
  type SessionTurnState,
  type SessionUnavailableReason,
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
import { chatCapabilities, chatSettingsForSession, normalizeChatText, readChatPage } from "./chat.js";
import { loadSlashCommandCatalog } from "./slash-commands.js";
import {
  chatCapabilitiesForState,
  conversationState,
  resolveSessionState,
  sessionTurnState,
  unavailableMessage,
} from "./session-state.js";
import type { CodexRouteEvent } from "./codex-turn.js";

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
  /** Provider-owned interaction class used by ambient attention surfaces. */
  sessionClass?: SessionClass;
  authority?: number;
  chatPath?: string;
  controlTarget?: SessionControlTarget;
  messageTransport?: "terminal" | "codex_app_server";
  modelCatalog?: Record<string, { displayName: string; contextWindow?: number }>;
  /** Codex app-server options verified for this session's working directory. */
  chatSettingsCatalog?: Pick<ChatSettings, "models" | "permissionProfiles">;
  codexLifecycle?: import("./providers/codex-lifecycle.js").CodexLifecycle;
  /** Provider-confirmed lifetime, independent of list placement. */
  conversationState?: SessionConversationState;
  /** Current provider turn state, independent of attention ordering. */
  turnState?: SessionTurnState;
  /** Provider-confirmed action route ownership, independent of transcript state. */
  routeState?: SessionRouteState;
  /** Tentative availability is distinct from a daemon-owned writer. */
  routeOwnership?: SessionRouteOwnership;
  /** Why the exact provider route is unavailable, when provider confirmed it. */
  routeUnavailableReason?: Extract<SessionUnavailableReason, "owner_only" | "provider_unavailable">;
  /** A released Codex child is still exiting and cannot be reacquired yet. */
  releasePending?: boolean;
  /** A terminal provider event proved the prior turn boundary. */
  confirmedTerminal?: boolean;
  /** Provider turn identity used by cancellation/currentness checks. */
  turnId?: string;
  /** Monotonic source-file stamp used to refresh external-owned transcripts. */
  transcriptRevision?: string;
  /** Independent server-side state/capability revision. */
  stateRevision?: number;
  /** Exact provider resolution failed; retain the transcript but remove write authority. */
  resolutionUnavailable?: boolean;
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

export type SessionRouteProbeResult = {
  routeState: Extract<SessionRouteState, "available" | "unavailable">;
  unavailableReason?: Extract<SessionUnavailableReason, "owner_only" | "provider_unavailable">;
  /** The previous native route is still closing; acquisition/focus must wait. */
  releasePending?: boolean;
  /** Writer ownership fact when the provider can classify it. */
  routeOwnership?: SessionRouteOwnership;
  /** Optional provider-confirmed current turn evidence from the acquired route. */
  turnState?: SessionTurnState;
  turnId?: string;
  /** A terminal event was confirmed even though the route child has closed. */
  confirmedTerminal?: boolean;
};

export type SessionRouteRecoveryResult = {
  recovered: boolean;
  probe: SessionRouteProbeResult;
  reason?: "release_pending" | "identity_unavailable" | "identity_mismatch";
};

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
    settings?: ChatSettingsPatch,
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
  /**
   * Release all locally retained idle Codex references before owner focus.
   * Returns true only after the provider child has exited; an active or
   * unknown turn remains owned and returns false.
   */
  relinquishIdleCodexRoute?(sessionId: string): Promise<boolean>;
  /** Read current route ownership without acquiring a new reference. */
  codexRouteStatus?(sessionId: string): SessionRouteProbeResult;
  /** Reconcile a sticky uncertain Codex route from exact ready lifecycle evidence. */
  recoverCodexRoute?(
    sessionId: string,
    evidence: { turnState: Extract<SessionTurnState, "ready">; turnId: string },
  ): SessionRouteRecoveryResult;
  /** Notify the repository of redacted native lifecycle identities. */
  subscribeCodexRouteEvents?(listener: (event: CodexRouteEvent) => void): () => void;
  /** Release provider resources during daemon shutdown. */
  close?(): Promise<void>;
}

export interface SessionSnapshotSource {
  current(): SessionSnapshot;
  subscribe(listener: (snapshot: SessionSnapshot) => void): () => void;
  /** Push a settings-only update when a lazy Codex catalog finishes loading. */
  subscribeChatSettings?(listener: ChatSettingsListener): () => void;
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
  /** A websocket opened a read lease; this never acquires a native writer. */
  chatOpened?(sessionId: string, leaseId: string): Promise<string | undefined>;
  /** A websocket stopped observing the chat view. */
  chatClosed?(sessionId: string, leaseId: string): void;
  /** Refresh exact read facts after an owner-focus transition. */
  chatRetry?(sessionId: string): Promise<string | undefined>;
}

export interface ProviderAdapter {
  readonly id: ProviderID;
  discover(): Promise<DiscoveredProviderSession[]>;
  /** Resolve one opened conversation without relying on recent-list membership. */
  resolve?(sessionId: string): Promise<DiscoveredProviderSession | undefined>;
  /** Load provider controls lazily for an opened chat, never during discovery. */
  chatSettings?(session: DiscoveredProviderSession): Promise<
    DiscoveredProviderSession["chatSettingsCatalog"]
  >;
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
// Give the normal app-server handshake a short chance to populate the
// composer without making transcript loading wait on a stalled provider.
const codexSettingsFirstOpenWaitMs = 750;
const codexSettingsCatalogTtlMs = 60_000;
// Open chats are retained independently from the bounded ambient catalog so
// pagination and refreshes cannot invalidate an exact route. Evict only
// released records; active websocket references are always retained.
const maxOpenedSessionRecords = 128;

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

export type ChatSettingsListener = (update: ChatSettingsUpdate) => void;

type ChatSendInFlight = {
  epoch: number;
  reservation: ChatStateOperationReservation;
  promise: Promise<string | undefined>;
};

type TerminalNextTurnReservation = {
  /** The renderer/provider identity that owns this admission. */
  deliveryKey: string;
  stateEpoch: number;
  generation: number;
  /** Provider evidence must be observed after this admission. */
  admittedAt: string;
  /** Raw discovery must advance through a successful refresh of this provider. */
  admissionProviderDiscoveryGeneration: number;
  provider: ProviderID;
  /** The exact ready record that was admitted before projection. */
  previous: DiscoveredProviderSession;
  /** Set only after the native control reports a successful delivery. */
  accepted: boolean;
  acceptedAt?: string;
  /** A post-admission working boundary gates later ready settlement. */
  workingObservedAt?: string;
  workingProviderDiscoveryGeneration?: number;
  /** A ready boundary can arrive before the async send promise settles. */
  readyObservedAt?: string;
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
const automationChatReadOnlyReason = "Automation sessions are read only.";

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
  private readonly stateRevisionBySession = new Map<string, number>();
  private readonly stateFingerprintBySession = new Map<string, string>();
  private readonly piRuntimeDiscoveryGeneration = new Map<string, number>();
  private readonly piRemovedRestorationSessionIds = new Set<string>();
  private piDiscoveryGeneration = 0;
  /** Successful provider observations used for terminal turn ordering. */
  private readonly providerDiscoveryGeneration = new Map<ProviderID, number>();
  private piRestorationFingerprint: string | undefined;
  private piRuntimeState: PiRuntimeState | undefined;
  private piRuntimeStateFingerprint: string | undefined;
  private readonly piRestorationListeners = new Set<(
    update: NativeHelperPiRestorationUpdate,
  ) => void>();
  private readonly chatBySession = new Map<string, DiscoveredProviderSession>();
  // A chat opened outside the bounded ambient catalog remains addressable by
  // its exact provider ID. Keep its latest exact facts separately so a refresh
  // cannot mistake absence from the recent list for removal of the open chat.
  private readonly openedSessionBySession = new Map<string, DiscoveredProviderSession>();
  private readonly chatOpenReferencesBySession = new Map<string, number>();
  /** Opaque per-open leases prevent an old async open from retaining a later reopen. */
  private readonly chatLeasesBySession = new Map<string, Set<string>>();
  /** Only settled leases may make an explicit retry eligible. */
  private readonly chatReadyLeasesBySession = new Map<string, Set<string>>();
  /** True after the first open attempt has settled for the current chat lease. */
  private readonly chatRouteReadyBySession = new Set<string>();
  /** Idle Codex routes released for an explicit Open-in-owner action. */
  private readonly codexOwnerFocusReleased = new Set<string>();
  // Settings catalogs are loaded only when a Codex chat is opened. Keep the
  // verified catalog through the normal discovery refresh so a renderer can
  // send its next-turn selection without spawning another app-server.
  private readonly chatSettingsCatalogBySession = new Map<
    string,
    {
      cwd: string;
      catalog: NonNullable<DiscoveredProviderSession["chatSettingsCatalog"]>;
      expiresAt: number;
    }
  >();
  private readonly chatSettingsCurrentBySession = new Map<
    string,
    {
      cwd: string;
      current: ChatSettings["current"];
    }
  >();
  private readonly listeners = new Set<(snapshot: SessionSnapshot) => void>();
  private readonly chatSettingsListeners = new Set<ChatSettingsListener>();
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
  /** Native lifecycle changes invalidate a page revision immediately. */
  private readonly codexEventRevisionBySession = new Map<string, number>();
  /**
   * Native item identity survives route close long enough for the rollout row
   * to be flushed and reconciled. Values contain IDs only, never content.
   */
  private readonly codexNativeIdentityBySession = new Map<string, Map<string, {
    itemId: string;
    turnId: string;
    deliveryId: string;
    requestId?: string;
    expiresAt: number;
  }>>();
  private readonly codexEventPublishTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private codexRouteEventUnsubscribe: (() => void) | undefined;
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
  /**
   * Synchronous terminal admission. Evidence reads and native helper writes
   * are asynchronous, so the first send must reserve the next turn before a
   * second request can observe the same ready snapshot and queue another
   * paste. The reservation is projected as busy and survives until failure
   * or provider-confirmed settlement.
   */
  private readonly terminalNextTurnBySession = new Map<string, TerminalNextTurnReservation>();
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
    this.codexRouteEventUnsubscribe?.();
    this.controls = controls;
    this.codexRouteEventUnsubscribe = controls.subscribeCodexRouteEvents?.((event) => {
      this.handleCodexRouteEvent(event);
    });
  }

  private handleCodexRouteEvent(event: CodexRouteEvent): void {
    const known = this.chatBySession.has(event.threadId)
      || this.openedSessionBySession.has(event.threadId)
      || this.controlBySession.has(event.threadId);
    if (!known) return;
    this.applyCodexRouteEventState(event);
    const revision = (this.codexEventRevisionBySession.get(event.threadId) ?? 0) + 1;
    this.codexEventRevisionBySession.set(event.threadId, revision > 2_147_483_647 ? 1 : revision);
    // Delivery identity is verified only on native user rows. Tool and
    // assistant items can outnumber a prompt by orders of magnitude; keeping
    // them in this FIFO would evict the exact user identity before the
    // rollout reader reconciles the page.
    if ((event.type === "item_started" || event.type === "item_completed")
      && event.itemType === "userMessage" && event.deliveryId) {
      let identities = this.codexNativeIdentityBySession.get(event.threadId);
      if (!identities) {
        identities = new Map();
        this.codexNativeIdentityBySession.set(event.threadId, identities);
      }
      identities.set(event.itemId, {
        itemId: event.itemId,
        turnId: event.turnId,
        deliveryId: event.deliveryId,
        ...(event.requestId ? { requestId: event.requestId } : {}),
        expiresAt: Date.now() + 5 * 60_000,
      });
      while (identities.size > 64) identities.delete(identities.keys().next().value!);
    }
    // Native events are redacted lifecycle signals. Coalesce a burst of
    // per-token deltas into one revision; the rollout remains the content
    // source and a later file stamp handles rows flushed after item/started.
    if (!this.codexEventPublishTimers.has(event.threadId)) {
      const timer = setTimeout(() => {
        this.codexEventPublishTimers.delete(event.threadId);
        this.publish([...this.lastByProvider.values()].flat());
      }, 50);
      timer.unref?.();
      this.codexEventPublishTimers.set(event.threadId, timer);
    }
  }

  private applyCodexRouteEventState(event: CodexRouteEvent): void {
    if (event.type !== "turn_started" && event.type !== "turn_completed") return;
    const current = this.chatBySession.get(event.threadId)
      ?? this.openedSessionBySession.get(event.threadId)
      ?? this.controlBySession.get(event.threadId);
    if (!current || current.provider !== "codex") return;
    if (current.turnId && current.turnId !== event.turnId) return;
    const updated: DiscoveredProviderSession = event.type === "turn_started"
      ? {
        ...current,
        section: "working",
        subtitle: "Agent is working",
        turnState: "working",
        routeState: "available",
        routeOwnership: "owned",
        turnId: event.turnId,
      }
      : {
        ...current,
        section: "ready",
        subtitle: "Ready to continue",
        turnState: "ready",
        routeState: "available",
        routeOwnership: "unverified",
        ...(current.turnId === event.turnId ? { turnId: undefined } : {}),
      };
    this.rememberOpenedSession(updated);
    this.chatBySession.set(event.threadId, structuredClone(updated));
    this.controlBySession.set(event.threadId, structuredClone(updated));
  }

  private annotateCodexNativeIdentities(
    sessionId: string,
    page: ChatPage,
  ): ChatPage {
    const identities = this.codexNativeIdentityBySession.get(sessionId);
    if (!identities?.size) return page;
    const now = Date.now();
    for (const [itemId, identity] of identities) {
      if (identity.expiresAt <= now) identities.delete(itemId);
    }
    if (!identities.size) return page;
    return {
      ...page,
      items: page.items.map((item) => {
        if (item.kind !== "user") return item;
        // The native provider item ID must match the canonical row ID or its
        // preserved provider ID. Never infer a match from text or ordering.
        const identity = identities.get(item.id)
          ?? (item.providerMessageId ? identities.get(item.providerMessageId) : undefined);
        if (!identity || (item.deliveryId && item.deliveryId !== identity.deliveryId)) return item;
        return {
          ...item,
          deliveryId: item.deliveryId ?? identity.deliveryId,
          ...(item.requestId || !identity.requestId
            ? {}
            : { requestId: identity.requestId }),
          providerMessageId: item.providerMessageId ?? identity.itemId,
        };
      }),
    };
  }

  async chatOpened(sessionId: string, leaseId: string): Promise<string | undefined> {
    let leases = this.chatLeasesBySession.get(sessionId);
    if (!leases) {
      leases = new Set();
      this.chatLeasesBySession.set(sessionId, leases);
    }
    // A duplicate open callback for the same websocket lease is harmless and
    // must not create a second provider reference. The server normally calls
    // this once per lease; keeping the check here also protects direct source
    // users and shutdown races.
    if (leases.has(leaseId)) return undefined;
    leases.add(leaseId);
    this.chatOpenReferencesBySession.set(
      sessionId,
      (this.chatOpenReferencesBySession.get(sessionId) ?? 0) + 1,
    );
    let session: DiscoveredProviderSession | undefined;
    try {
      session = await this.resolveExactSession(sessionId);
      if (!session) return "This session is no longer available.";
      // Chat/read pages are observers. They retain only the websocket lease;
      // the native writer is acquired atomically by the first Send instead.
      // This leaves a competing Codex desktop owner untouched and keeps a
      // tentative Ready projection from being mistaken for ownership.
      return undefined;
    } catch (error) {
      return error instanceof Error ? error.message : "The provider route is unavailable.";
    } finally {
      if (this.chatLeasesBySession.get(sessionId)?.has(leaseId)) {
        let readyLeases = this.chatReadyLeasesBySession.get(sessionId);
        if (!readyLeases) {
          readyLeases = new Set();
          this.chatReadyLeasesBySession.set(sessionId, readyLeases);
        }
        readyLeases.add(leaseId);
        this.chatRouteReadyBySession.add(sessionId);
      }
      this.trimOpenedSessionCache();
    }
  }

  chatClosed(sessionId: string, leaseId: string): void {
    const leases = this.chatLeasesBySession.get(sessionId);
    // Legacy direct callers may omit the token. Remove one oldest lease in
    // that case, while websocket callers always provide the exact identity.
    if (!leases?.has(leaseId)) return;
    leases.delete(leaseId);
    if (!leases.size) this.chatLeasesBySession.delete(sessionId);
    const readyLeases = this.chatReadyLeasesBySession.get(sessionId);
    readyLeases?.delete(leaseId);
    if (readyLeases?.size === 0) this.chatReadyLeasesBySession.delete(sessionId);
    const references = this.chatOpenReferencesBySession.get(sessionId) ?? 0;
    const lastReference = references <= 1;
    if (lastReference) {
      this.chatOpenReferencesBySession.delete(sessionId);
    } else {
      this.chatOpenReferencesBySession.set(sessionId, references - 1);
    }
    if ((this.chatOpenReferencesBySession.get(sessionId) ?? 0) <= 0) {
      this.codexOwnerFocusReleased.delete(sessionId);
      this.chatRouteReadyBySession.delete(sessionId);
      this.chatReadyLeasesBySession.delete(sessionId);
    } else if (!this.chatReadyLeasesBySession.get(sessionId)?.size) {
      this.chatRouteReadyBySession.delete(sessionId);
    }
    this.trimOpenedSessionCache();
  }

  async chatRetry(sessionId: string): Promise<string | undefined> {
    if ((this.chatOpenReferencesBySession.get(sessionId) ?? 0) <= 0) {
      this.codexOwnerFocusReleased.delete(sessionId);
      return undefined;
    }
    if (!this.chatReadyLeasesBySession.get(sessionId)?.size) return undefined;
    const previous = this.chatBySession.get(sessionId)
      ?? this.openedSessionBySession.get(sessionId);
    const codexRoute = previous?.provider === "codex"
      && previous.messageTransport === "codex_app_server"
      ? true
      : false;
    // Every Codex retry starts with a live read-only route check. A terminal
    // transcript can look ready while its native child is still closing; do
    // not let the exact read below clear that evidence before the user sees
    // the closing state.
    const liveCodexRouteProbe = codexRoute
      ? this.controls?.codexRouteStatus?.(sessionId)
      : undefined;
    if (liveCodexRouteProbe?.releasePending && previous) {
      this.publishCodexRetryRoute(sessionId, previous, liveCodexRouteProbe);
      return "The Codex route is still closing. Retry after it settles.";
    }
    const uncertainCodexRoute = previous !== undefined
      && codexRoute
      && previous.routeState === "unavailable"
      && previous.routeUnavailableReason === "provider_unavailable"
      && previous.confirmedTerminal !== true
      && previous.turnState === "working";
    try {
      // A normal retry may clear an explicit owner/provider rejection. A
      // lost app-server child is different: it may have accepted a turn whose
      // result is unknown, so first obtain fresh read-only lifecycle evidence
      // and reconcile it against the retained native identity.
      const session = await this.resolveExactSession(sessionId, true);
      if (!session) return "The session is no longer available.";
      if (uncertainCodexRoute) {
        const routeProbe = this.controls?.codexRouteStatus?.(sessionId)
          ?? liveCodexRouteProbe;
        if (routeProbe?.releasePending) {
          this.publishCodexRetryRoute(sessionId, previous!, routeProbe);
          return "The Codex route is still closing. Retry after it settles.";
        }
        const expectedTurnId = routeProbe?.turnId ?? previous?.turnId;
        if (!expectedTurnId) {
          this.publishCodexRetryRoute(sessionId, previous!, routeProbe);
          return "Codex could not confirm the lost turn's exact identity. Continue in Codex, then retry.";
        }
        if (session.turnState !== "ready") {
          this.publishCodexRetryRoute(sessionId, previous!, routeProbe);
          return "Codex has not confirmed the lost turn is ready. Continue in Codex, then retry.";
        }
        if (!session.turnId) {
          this.publishCodexRetryRoute(sessionId, previous!, routeProbe);
          return "Codex could not confirm the lost turn's exact identity. Continue in Codex, then retry.";
        }
        if (session.turnId !== expectedTurnId) {
          this.publishCodexRetryRoute(sessionId, previous!, routeProbe);
          return "Codex reported a different turn identity for the lost turn. Continue in Codex, then retry.";
        }
        const recovery = this.controls?.recoverCodexRoute?.(sessionId, {
          turnState: "ready",
          turnId: session.turnId,
        });
        if (!recovery) {
          this.publishCodexRetryRoute(sessionId, previous!, routeProbe);
          return "Codex could not confirm the lost turn's exact identity. Continue in Codex, then retry.";
        }
        if (!recovery.recovered) {
          this.publishCodexRetryRoute(sessionId, previous!, recovery.probe);
          return codexRouteRecoveryMessage(recovery.reason);
        }
        const recovered = this.withCodexRouteProbe(session, recovery.probe);
        this.rememberOpenedSession(recovered);
        this.chatBySession.set(sessionId, structuredClone(recovered));
        this.controlBySession.set(sessionId, structuredClone(recovered));
      }
      // Retry re-resolves facts for the page. It deliberately does not open a
      // writer; a Send remains the only route acquisition boundary.
      this.publish([...this.lastByProvider.values()].flat());
      return undefined;
    } catch (error) {
      return error instanceof Error ? error.message : "The provider route is unavailable.";
    }
  }

  private publishCodexRetryRoute(
    sessionId: string,
    previous: DiscoveredProviderSession,
    probe?: SessionRouteProbeResult,
  ): void {
    const current = this.chatBySession.get(sessionId)
      ?? this.openedSessionBySession.get(sessionId)
      ?? previous;
    const sticky = this.withCodexRouteProbe({
      ...current,
      section: previous.section,
      subtitle: previous.subtitle,
      turnState: previous.turnState,
      ...(previous.confirmedTerminal ? { confirmedTerminal: true } : {}),
    }, probe ?? {
      routeState: "unavailable",
      unavailableReason: "provider_unavailable",
      ...(previous.releasePending ? { releasePending: true } : {}),
      ...(previous.turnId ? { turnId: previous.turnId } : {}),
    });
    this.rememberOpenedSession(sticky);
    this.chatBySession.set(sessionId, structuredClone(sticky));
    this.controlBySession.set(sessionId, structuredClone(sticky));
    this.publish([...this.lastByProvider.values()].flat());
  }

  current(): SessionSnapshot {
    return structuredClone(this.snapshotValue);
  }

  subscribe(listener: (snapshot: SessionSnapshot) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  subscribeChatSettings(listener: ChatSettingsListener): () => void {
    this.chatSettingsListeners.add(listener);
    return () => this.chatSettingsListeners.delete(listener);
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
    let record = discovered;
    if (!record || record.provider === "codex") {
      // Ambient discovery is intentionally bounded. Resolve the exact opened
      // conversation so age or catalog membership cannot imply archival.
      record = await this.resolveExactSession(sessionId) ?? (hook ? hookSession(hook) : discovered);
    }
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
    let chatRecord = this.withFreshChatSettingsCatalog(sessionId, record);
    const settingsProvider = this.providers.find((provider) => provider.id === record.provider);
    let initialPageMetadata: ChatPage["metadata"];
    let initialPageReturned = false;
    let settingsCatalogPromise: Promise<NonNullable<DiscoveredProviderSession["chatSettingsCatalog"]> | undefined> | undefined;
    if (record.provider === "codex" && !chatRecord.chatSettingsCatalog && settingsProvider?.chatSettings) {
      settingsCatalogPromise = settingsProvider.chatSettings(record).then(
        (catalog) => {
          if (!catalog) return undefined;
          const current = this.chatBySession.get(sessionId);
          if (current && sessionActionFingerprint(current) === sessionActionFingerprint(record)) {
            this.chatSettingsCatalogBySession.set(sessionId, {
              cwd: record.cwd,
              catalog,
              expiresAt: Date.now() + codexSettingsCatalogTtlMs,
            });
            chatRecord = { ...current, chatSettingsCatalog: catalog };
            // Keep the catalog out of the discovered session record. The
            // session cache has an explicit TTL; a copied catalog would
            // otherwise survive refreshes indefinitely.
            if (initialPageReturned && before === undefined
              && this.chatPageRequestEpochBySession.get(sessionId) === pageReservation.requestEpoch
              && this.chatGenerationBySession.get(sessionId) === pageGeneration) {
              this.publishChatSettingsUpdate(
                sessionId,
                pageGeneration,
                chatRecord,
                initialPageMetadata,
              );
            }
          }
          return catalog;
        },
        () => undefined,
      );
    }
    this.controls?.reconcile?.(this.projectedTerminalSession(chatRecord));
    try {
      const pageRead = this.chatPageReader(chatRecord, before, limit);
      if (settingsCatalogPromise) {
        await Promise.race([
          settingsCatalogPromise.then(() => undefined),
          new Promise<void>((resolve) => {
            const timeout = setTimeout(resolve, codexSettingsFirstOpenWaitMs);
            timeout.unref?.();
          }),
        ]);
      }
      const page = this.annotateCodexNativeIdentities(sessionId, await pageRead);
      const chatSettings = before === undefined
        ? chatSettingsForSession(chatRecord, page.metadata)
        : undefined;
      if (before === undefined) initialPageMetadata = page.metadata;
      const projectedRecord = this.projectedTerminalSession(chatRecord);
      const resolvedState = resolveSessionState(projectedRecord, {
        nativeHelperAvailable: this.controls?.isAvailable?.() !== false,
      });
      page.sessionState = resolvedState;
      page.stateRevision = this.stateRevisionForSession(chatRecord, resolvedState);
      // The reader's initial capabilities may have been computed before the
      // exact route probe completed. Reapply the same current-state policy
      // used by session summaries and actions before adding transcript-only
      // pending/cancel evidence below.
      page.capabilities = {
        ...page.capabilities,
        ...chatCapabilitiesForState(projectedRecord, {
          nativeHelperAvailable: this.controls?.isAvailable?.() !== false,
        }),
      };
      if (chatSettings) {
        page.chatSettings = chatSettings;
      }
      // Revalidate before any post-read native reconciliation or capability
      // mutation. A late R1 is data for the renderer only; it cannot rewind
      // delivery evidence established by a newer R2/baseline.
      if (!this.isChatPageReadCurrent(pageReservation)) return page;
      if (chatSettings) {
        this.chatSettingsCurrentBySession.set(sessionId, {
          cwd: chatRecord.cwd,
          current: chatSettings.current,
        });
      }
      if (before === undefined && this.chatUsageGlance) {
        try {
          const usage = await this.chatUsageGlance(chatRecord);
          const providerMatches = (chatRecord.provider === "codex" && usage?.provider === "codex")
            || (chatRecord.provider === "claude_code" && usage?.provider === "claude");
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
        this.controls?.reconcileChatPage?.(projectedRecord, page, true);
      }
      if (chatRecord.messageTransport === "terminal" && this.controls?.isAvailable?.() === false) {
        const readOnlyReason = "The native helper is unavailable. Terminal chat is read only until it recovers.";
        page.capabilities.canSendText = false;
        page.capabilities.canSendImages = false;
        page.capabilities.canCancel = false;
        delete page.capabilities.cancelDeliveryId;
        page.capabilities.readOnlyReason = readOnlyReason;
        page.capabilities.unavailableReason = "native_helper_unavailable";
      }
      const canCyclePermissionMode = page.capabilities.canCyclePermissionMode === true
        && this.controls?.canCyclePermissionMode?.(projectedRecord) === true;
      page.capabilities.canCyclePermissionMode = canCyclePermissionMode;
      // A transcript transport is not enough to cancel. Keep the page honest
      // when the daemon has no live helper or daemon-owned Codex turn. The
      // capability and identity are derived from one live control lookup so a
      // page cannot advertise a route for an unrelated delivery.
      const cancelDeliveryId = this.controls?.activeCancelDeliveryId?.(projectedRecord);
      const canCancel = cancelDeliveryId !== undefined
        && (this.controls?.canCancel?.(projectedRecord, cancelDeliveryId) ?? false);
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
      if (chatRecord.sessionClass === "automation") {
        // Automation may expose pending provider state for inspection, but it
        // must never turn that state into a writable Agent Visor action card.
        page.capabilities.canSendText = false;
        page.capabilities.canSendImages = false;
        page.capabilities.canCancel = false;
        page.capabilities.canApprove = false;
        page.capabilities.canAnswer = false;
        delete page.capabilities.cancelDeliveryId;
        delete page.capabilities.canCyclePermissionMode;
        delete page.capabilities.maxTextBytes;
        page.capabilities.readOnlyReason = automationChatReadOnlyReason;
      }
      // The catalog may have completed while optional usage/reconciliation
      // awaits were in flight. Attach it before returning the first page so
      // that narrow timing window does not rely on the later update event.
      if (before === undefined && !page.chatSettings && chatRecord.chatSettingsCatalog) {
        const finalChatSettings = chatSettingsForSession(chatRecord, page.metadata);
        if (finalChatSettings) {
          page.chatSettings = finalChatSettings;
          this.chatSettingsCurrentBySession.set(sessionId, {
            cwd: chatRecord.cwd,
            current: finalChatSettings.current,
          });
        }
      }
      return page;
    } finally {
      initialPageReturned = true;
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

  private withFreshChatSettingsCatalog(
    sessionId: string,
    session: DiscoveredProviderSession,
  ): DiscoveredProviderSession {
    if (session.provider !== "codex") return session;
    const cached = this.cachedChatSettingsCatalog(sessionId, session.cwd);
    if (cached) return { ...session, chatSettingsCatalog: cached };
    // A catalog copied onto a discovered record is safe only when it also has
    // a live session-cache entry. Strip it when the cache expires so sends
    // cannot silently validate against stale provider choices.
    if (!session.chatSettingsCatalog) return session;
    const { chatSettingsCatalog: _staleCatalog, ...withoutCatalog } = session;
    return withoutCatalog;
  }

  private cachedChatSettingsCatalog(
    sessionId: string,
    cwd: string,
  ): NonNullable<DiscoveredProviderSession["chatSettingsCatalog"]> | undefined {
    const cached = this.chatSettingsCatalogBySession.get(sessionId);
    if (!cached || cached.cwd !== cwd || cached.expiresAt <= Date.now()) {
      if (cached) this.chatSettingsCatalogBySession.delete(sessionId);
      return undefined;
    }
    return cached.catalog;
  }

  private publishChatSettingsUpdate(
    sessionId: string,
    generation: number,
    session: DiscoveredProviderSession,
    metadata: ChatPage["metadata"],
  ): void {
    const settings = chatSettingsForSession(session, metadata);
    if (!settings) return;
    this.chatSettingsCurrentBySession.set(sessionId, {
      cwd: session.cwd,
      current: settings.current,
    });
    const update: ChatSettingsUpdate = {
      type: "chat_settings_update",
      sessionId,
      generation,
      settings,
    };
    for (const listener of this.chatSettingsListeners) listener(structuredClone(update));
  }

  async focusSession(sessionId: string): Promise<string | undefined> {
    const session = this.controlBySession.get(sessionId);
    if (!session?.controlTarget || !this.controls) return "Exact session focus is unavailable.";
    if (isTerminalChatRoute(session) && this.terminalNextTurnBySession.has(sessionId)) {
      return unavailableMessage("turn_in_progress");
    }
    const reservation = this.reserveChatStateOperation(
      sessionId,
      this.chatStateEpoch(sessionId),
    );
    if (!reservation) {
      return "Too many chat actions are queued for this session.";
    }
    this.acknowledgeReady(sessionId);
    try {
      if (session.provider === "codex" && session.messageTransport === "codex_app_server"
        && this.controls.codexRouteStatus) {
        let released = false;
        if (this.controls.relinquishIdleCodexRoute) {
          released = await this.controls.relinquishIdleCodexRoute(session.id);
          if (!released) {
            const probe = this.controls.codexRouteStatus(session.id);
            if (probe.releasePending) {
              return "Wait for the Codex route to finish closing before opening it in Codex.";
            }
            if (probe.routeState === "available") {
              return probe.turnState === "working"
                ? "Wait for this Codex turn to finish before opening it in Codex."
                : "Wait for Codex to report this conversation is idle before opening it in Codex.";
            }
            if (session.routeState === "available"
              && probe.unavailableReason !== "owner_only") {
              return "Codex could not safely release its current route. Try again after it settles.";
            }
          }
        } else {
          const probe = this.controls.codexRouteStatus(session.id);
          if (probe.releasePending) {
            return "Wait for the Codex route to finish closing before opening it in Codex.";
          }
          if (probe.routeState === "available" && probe.turnState !== "ready") {
            return probe.turnState === "working"
              ? "Wait for this Codex turn to finish before opening it in Codex."
              : "Wait for Codex to report this conversation is idle before opening it in Codex.";
          }
          if (probe.routeState === "available") {
            // A provider route without the confirmed release operation cannot
            // be treated as released before opening the owner application.
            return "Wait for the Codex route to finish closing before opening it in Codex.";
          }
        }
        if (released) {
          // Releasing an idle route lets the owner application resume the
          // same thread. The websocket remains open, but its next explicit
          // Retry/latest request is the boundary that reacquires it.
          this.codexOwnerFocusReleased.add(session.id);
          const updated = this.withCodexRouteProbe(session, {
            routeState: "unavailable",
            unavailableReason: "provider_unavailable",
            turnState: "ready",
          });
          this.rememberOpenedSession(updated);
          this.chatBySession.set(session.id, structuredClone(updated));
          this.controlBySession.set(session.id, structuredClone(updated));
          this.publish([...this.lastByProvider.values()].flat());
        }
      }
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
      let session = this.chatBySession.get(message.sessionId);
      const stateEpoch = this.chatStateEpoch(message.sessionId);
      const generationError = this.acceptChatGeneration(message.sessionId, message.generation);
      if (generationError) return generationError;
      if (!session || session.provider === "codex") {
        session = await this.resolveExactSession(message.sessionId) ?? session;
      }
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
      let terminalAdmission: TerminalNextTurnReservation | undefined;
      if (session && isTerminalChatRoute(session)) {
        const existingTerminalAdmission = this.terminalNextTurnBySession.get(session.id);
        if (existingTerminalAdmission) {
          this.releaseChatStateOperation(message.sessionId, reservation);
          return unavailableMessage("turn_in_progress");
        }
        const state = resolveSessionState(session, {
          nativeHelperAvailable: this.controls?.isAvailable?.() !== false,
        });
        if (state.turn === "working" || state.turn === "needs_you") {
          this.releaseChatStateOperation(message.sessionId, reservation);
          return unavailableMessage("turn_in_progress");
        }
        if (state.route !== "available") {
          this.releaseChatStateOperation(message.sessionId, reservation);
          return unavailableMessage(state.unavailableReason);
        }
        terminalAdmission = this.reserveTerminalNextTurn(
          session,
          deliveryKey,
          stateEpoch,
          message.generation,
        );
        if (!terminalAdmission) {
          this.releaseChatStateOperation(message.sessionId, reservation);
          return unavailableMessage("turn_in_progress");
        }
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
      let operationAccepted = false;
      try {
        result = await operation;
        operationWasCurrent = this.isChatOperationCurrent(
          message.sessionId, stateEpoch, reservation,
        );
        operationAccepted = result === undefined && operationWasCurrent;
      } finally {
        this.releaseChatStateOperation(message.sessionId, reservation);
        if (terminalAdmission) {
          const currentAdmission = this.terminalNextTurnBySession.get(message.sessionId);
          if (currentAdmission === terminalAdmission) {
            if (operationAccepted) {
              terminalAdmission.accepted = true;
              terminalAdmission.acceptedAt = this.now().toISOString();
              // A provider can report the complete Working -> Ready episode
              // before the asynchronous helper promise resolves. Once this
              // send is accepted, that previously observed boundary settles
              // the reservation immediately.
              if (terminalAdmission.readyObservedAt) {
                this.settleTerminalNextTurn(message.sessionId, deliveryKey);
              }
            }
            else this.settleTerminalNextTurn(message.sessionId, deliveryKey);
          }
        }
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
      const session = this.chatBySession.get(message.sessionId);
      if (session?.sessionClass === "automation") return automationChatReadOnlyReason;
      const reservation = this.reserveChatStateOperation(message.sessionId, stateEpoch);
      if (!reservation) {
        return "Too many chat actions are queued for this session.";
      }
      try {
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
      if (this.chatBySession.get(message.sessionId)?.sessionClass === "automation") {
        return automationChatReadOnlyReason;
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
    if (this.chatBySession.get(message.sessionId)?.sessionClass === "automation") {
      return automationChatReadOnlyReason;
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
    let session = initialSession
      ? this.withFreshChatSettingsCatalog(message.sessionId, initialSession)
      : undefined;
    if (session
      && session.provider === "codex"
      && session.messageTransport === "codex_app_server"
      && (message.settings !== undefined || message.images.length > 0)
      && !session.chatSettingsCatalog) {
      const settingsProvider = this.providers.find((provider) => provider.id === "codex");
      const catalogPromise = settingsProvider?.chatSettings?.(session);
      const catalog = catalogPromise ? await catalogPromise.catch(() => undefined) : undefined;
      if (catalog) {
        if (!operationIsCurrent()) return "This chat session changed before Codex settings could be loaded.";
        this.chatSettingsCatalogBySession.set(message.sessionId, {
          cwd: session.cwd,
          catalog,
          expiresAt: Date.now() + codexSettingsCatalogTtlMs,
        });
        session = { ...session, chatSettingsCatalog: catalog };
      }
    }
    const capabilities = session ? chatCapabilities(session) : undefined;
    if (!session || !this.controls || !capabilities?.canSendText) {
      return "Chat sending is unavailable for this session.";
    }
    if (session.messageTransport === "terminal" && this.controls.isAvailable?.() === false) {
      return "The native helper is unavailable. Terminal chat is read only until it recovers.";
    }
    if (message.images.length > 0 && !capabilities.canSendImages) {
      return "Image sending is unavailable for this session.";
    }
    const settingsError = validateChatSettings(
      session,
      message.settings,
      this.chatSettingsCurrentBySession.get(message.sessionId),
    );
    if (settingsError) return settingsError;
    if (message.images.length > 0 && message.settings?.modelId) {
      const model = session.chatSettingsCatalog?.models.find(({ id }) => id === message.settings?.modelId);
      if (model && !model.supportsImages) return "The selected Codex model does not support images.";
    }
    if (message.images.length > 0 && !message.settings?.modelId) {
      const current = this.chatSettingsCurrentBySession.get(message.sessionId);
      const modelId = current?.cwd === session.cwd ? current.current.modelId : undefined;
      const model = modelId
        ? session.chatSettingsCatalog?.models.find(({ id }) => id === modelId)
        : undefined;
      if (model && !model.supportsImages) return "The selected Codex model does not support images.";
    }
    const initialFingerprint = sessionActionFingerprint(session);
    const submittedAt = this.now().toISOString();
    // A delivery baseline supersedes any page read that started earlier. The
    // baseline itself owns an exact page-read reservation, but
    // concurrent sends must remain independent: one send cannot make every
    // other admitted send stale merely because their evidence reads overlap.
    const pageReservation = isTerminalChatRoute(session)
      ? (() => {
        this.invalidateChatPageReads(message.sessionId);
        return this.reserveChatPageRead(
          message.sessionId,
          message.generation,
          session,
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
        session,
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
      const liveSessionRecord = this.chatBySession.get(message.sessionId);
      const freshSession = liveSessionRecord
        ? this.withFreshChatSettingsCatalog(message.sessionId, liveSessionRecord)
        : undefined;
      const generation = this.chatGenerationBySession.get(message.sessionId);
      const liveCapabilities = freshSession ? chatCapabilities(freshSession) : undefined;
      if (!freshSession
        || generation !== message.generation
        || sessionActionFingerprint(freshSession) !== initialFingerprint
        || !liveCapabilities?.canSendText
        || (message.images.length > 0 && !liveCapabilities.canSendImages)) {
        return "This chat session changed before the message could be delivered.";
      }
      if (freshSession.messageTransport === "terminal" && this.controls.isAvailable?.() === false) {
        return "The native helper is unavailable. Terminal chat is read only until it recovers.";
      }
      await this.controls.send(
        structuredClone(freshSession), message.text, message.images, message.deliveryId, evidence,
        isCurrent, message.settings,
      );
      // The native Codex route resolves after turn/start is accepted. The
      // route manager's current probe supplies the confirmed busy boundary
      // immediately, before transcript polling catches up.
      if (freshSession.provider === "codex"
        && freshSession.messageTransport === "codex_app_server"
        && this.controls.codexRouteStatus) {
        this.markCodexTurnWorking(message.sessionId);
      }
      return undefined;
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      if (session.provider === "codex" && session.messageTransport === "codex_app_server"
        && (/owned by another Codex session/i.test(errorMessage)
          || /Codex message delivery is unavailable/i.test(errorMessage))) {
        const current = this.chatBySession.get(message.sessionId);
        if (current?.provider === "codex") {
          const reason = /owned by another Codex session/i.test(errorMessage)
            ? "owner_only" as const
            : "provider_unavailable" as const;
          const updated = this.withCodexRouteProbe(current, {
            routeState: "unavailable",
            unavailableReason: reason,
          });
          this.rememberOpenedSession(updated);
          this.chatBySession.set(message.sessionId, structuredClone(updated));
          this.controlBySession.set(message.sessionId, structuredClone(updated));
        }
      }
      // A queued native action can fail after its repository operation has
      // become stale. Never let that old failure clear a replacement control
      // record with the same delivery ID.
      if (isCurrent()) this.controls.clear?.(message.sessionId, message.deliveryId);
      return errorMessage || "The message could not be delivered.";
    } finally {
      if (pageReservation) this.releaseChatPageRead(message.sessionId, pageReservation);
    }
  }

  private markCodexTurnWorking(sessionId: string): void {
    const current = this.chatBySession.get(sessionId);
    if (!current || current.provider !== "codex"
      || current.messageTransport !== "codex_app_server") return;
    const probe = this.controls?.codexRouteStatus?.(sessionId);
    if (!probe) return;
    // The route can finish between the provider acknowledgement and this
    // projection. Preserve that authoritative terminal state instead of
    // reviving a completed turn as Working. A lost child remains explicitly
    // unavailable with its retained turn identity; it is never reacquired
    // behind the user's back.
    const terminal = probe.confirmedTerminal === true
      || (probe.routeState === "available" && probe.turnState === "ready");
    const updated: DiscoveredProviderSession = this.withCodexRouteProbe({
      ...current,
      section: terminal ? "ready" : "working",
      subtitle: terminal ? "Ready to continue" : "Agent is working",
      turnState: terminal ? "ready" : "working",
    }, probe);
    this.rememberOpenedSession(updated);
    this.chatBySession.set(sessionId, structuredClone(updated));
    this.controlBySession.set(sessionId, structuredClone(updated));
    this.publish([...this.lastByProvider.values()].flat());
  }

  /**
   * Reserve a terminal's next turn synchronously at send admission. The
   * native operation itself still waits for transcript evidence, but this
   * ledger closes the ready-to-ready race between two websocket requests.
   */
  private reserveTerminalNextTurn(
    session: DiscoveredProviderSession,
    deliveryKey: string,
    stateEpoch: number,
    generation: number,
  ): TerminalNextTurnReservation | undefined {
    if (!isTerminalChatRoute(session)) return undefined;
    if (this.terminalNextTurnBySession.has(session.id)) return undefined;
    const state = resolveSessionState(session, {
      nativeHelperAvailable: this.controls?.isAvailable?.() !== false,
    });
    if (state.route !== "available" || state.turn !== "ready") return undefined;
    const reservation: TerminalNextTurnReservation = {
      deliveryKey,
      stateEpoch,
      generation,
      admittedAt: this.now().toISOString(),
      admissionProviderDiscoveryGeneration:
        this.providerDiscoveryGeneration.get(session.provider) ?? 0,
      provider: session.provider,
      previous: structuredClone(session),
      accepted: false,
    };
    this.terminalNextTurnBySession.set(session.id, reservation);
    // Keep the underlying exact record ready for the in-flight operation's
    // currentness checks. The presentation projection below is the only
    // state that changes synchronously, so the first admitted send retains
    // its original route and capabilities while the second sees WAIT.
    this.publish([...this.lastByProvider.values()].flat());
    return reservation;
  }

  private projectedTerminalSession(
    session: DiscoveredProviderSession,
  ): DiscoveredProviderSession {
    const reservation = this.terminalNextTurnBySession.get(session.id);
    if (!reservation) return session;
    return {
      ...session,
      section: "working",
      subtitle: "Agent is working",
      turnState: "working",
    };
  }

  private settleTerminalNextTurn(
    sessionId: string,
    deliveryKey?: string,
    publish = true,
  ): void {
    const reservation = this.terminalNextTurnBySession.get(sessionId);
    if (!reservation || (deliveryKey !== undefined && reservation.deliveryKey !== deliveryKey)) return;
    this.terminalNextTurnBySession.delete(sessionId);
    if (publish && this.chatBySession.has(sessionId)) {
      this.publish([...this.lastByProvider.values()].flat());
    }
  }

  private reconcileTerminalNextTurns(
    discovered: DiscoveredProviderSession[],
  ): void {
    const byID = new Map(discovered.map((session) => [session.id, session]));
    for (const [sessionId, reservation] of this.terminalNextTurnBySession) {
      const raw = byID.get(sessionId)
        ?? this.openedSessionBySession.get(sessionId)
        ?? this.chatBySession.get(sessionId);
      if (!raw) continue;
      // A stored hook is authoritative only when its provider timestamp is
      // after this admission. Older hook state must not make a raw discovery
      // look like a new lifecycle boundary; a post-admission Working hook
      // must also win over a stale raw Ready row.
      const hook = this.hookBySession.get(sessionId);
      const hookAt = hook ? Date.parse(hook.receivedAt) : Number.NaN;
      const admissionAt = Date.parse(reservation.admittedAt);
      const hasPostAdmissionHook = Number.isFinite(hookAt)
        && Number.isFinite(admissionAt)
        && hookAt >= admissionAt;
      const current = hasPostAdmissionHook
        ? applyHooks([raw], this.hookBySession)[0] ?? raw
        : raw;
      const providerGeneration = this.providerDiscoveryGeneration.get(reservation.provider) ?? 0;
      const freshRawDiscovery = !hasPostAdmissionHook
        && byID.has(sessionId)
        && raw.provider === reservation.provider
        && providerGeneration > reservation.admissionProviderDiscoveryGeneration;
      if (current.turnState === "working") {
        // A fresh provider Working fact is the boundary that proves the
        // admitted send became a turn. A raw Ready record before this point
        // may still describe the pre-send state and cannot release the slot.
        if (hasPostAdmissionHook || freshRawDiscovery) {
          reservation.workingObservedAt ??= hasPostAdmissionHook
            ? hook!.receivedAt
            : this.now().toISOString();
        }
        if (freshRawDiscovery) {
          reservation.workingProviderDiscoveryGeneration ??= providerGeneration;
        }
        continue;
      }
      // A provider-confirmed Ready boundary is the only normal settlement.
      // Transcript freshness alone is insufficient: a terminal write can
      // advance updatedAt while discovery still carries the previous idle
      // metadata. Raw discovery must cross a later refresh than its Working
      // boundary; hook-merged evidence is ordered by its provider timestamp.
      const rawReadyAfterWorking = !hasPostAdmissionHook
        && byID.has(sessionId)
        && raw.provider === reservation.provider
        && reservation.workingProviderDiscoveryGeneration !== undefined
        && providerGeneration > reservation.workingProviderDiscoveryGeneration;
      const hookReadyAfterWorking = hasPostAdmissionHook
        && current.turnState === "ready"
        && reservation.workingObservedAt !== undefined
        && hookAt >= Date.parse(reservation.workingObservedAt);
      if (current.turnState === "ready"
        && (rawReadyAfterWorking || hookReadyAfterWorking)) {
        reservation.readyObservedAt = hasPostAdmissionHook
          ? hook!.receivedAt
          : this.now().toISOString();
        if (reservation.accepted) this.terminalNextTurnBySession.delete(sessionId);
      }
    }
  }

  private reconcileTerminalNextTurnHook(event: HookSessionEvent): void {
    const reservation = this.terminalNextTurnBySession.get(event.sessionId);
    if (!reservation || event.provider === "codex") return;
    const admissionAt = Date.parse(reservation.admittedAt);
    const receivedAt = Date.parse(event.receivedAt);
    if (!Number.isFinite(admissionAt)
      || !Number.isFinite(receivedAt)
      || receivedAt < admissionAt) return;
    const phase = hookPhase(event);
    if (phase.turnState === "working") {
      reservation.workingObservedAt ??= event.receivedAt;
      return;
    }
    if (phase.turnState === "ready" && reservation.workingObservedAt
      && (!reservation.accepted || receivedAt >= Date.parse(reservation.acceptedAt ?? ""))) {
      reservation.readyObservedAt = event.receivedAt;
      if (reservation.accepted) this.terminalNextTurnBySession.delete(event.sessionId);
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
    if ((this.chatOpenReferencesBySession.get(sessionId) ?? 0) <= 0) {
      this.chatOpenReferencesBySession.delete(sessionId);
      this.chatLeasesBySession.delete(sessionId);
      this.chatReadyLeasesBySession.delete(sessionId);
      this.openedSessionBySession.delete(sessionId);
      this.chatRouteReadyBySession.delete(sessionId);
    }
    this.codexOwnerFocusReleased.delete(sessionId);
    this.codexEventRevisionBySession.delete(sessionId);
    this.codexNativeIdentityBySession.delete(sessionId);
    const eventPublishTimer = this.codexEventPublishTimers.get(sessionId);
    if (eventPublishTimer) clearTimeout(eventPublishTimer);
    this.codexEventPublishTimers.delete(sessionId);
    this.chatSettingsCatalogBySession.delete(sessionId);
    this.chatSettingsCurrentBySession.delete(sessionId);
    this.terminalNextTurnBySession.delete(sessionId);
    this.stateFingerprintBySession.delete(sessionId);
    this.stateRevisionBySession.delete(sessionId);
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

  private stateRevisionForSession(
    session: DiscoveredProviderSession,
    state = resolveSessionState(session, {
      nativeHelperAvailable: this.controls?.isAvailable?.() !== false,
    }),
  ): number {
    const cancelDeliveryId = this.controls?.activeCancelDeliveryId?.(session);
    const pending = this.pendingActions(session.id).map((action) => [
      action.type,
      action.toolUseId,
      action.approvalId,
      action.responding === true,
    ]);
    // State revision is independent from transcript timestamps. Include the
    // exact provider/control identity and pending-action identities so a new
    // turn or Stop target cannot be mistaken for an unchanged working state.
    const fingerprint = JSON.stringify({
      state,
      action: sessionActionFingerprint(session),
      capabilities: chatCapabilitiesForState(session, {
        nativeHelperAvailable: this.controls?.isAvailable?.() !== false,
      }),
      cancelDeliveryId,
      transcriptRevision: session.transcriptRevision,
      codexEventRevision: this.codexEventRevisionBySession.get(session.id) ?? 0,
      pending,
    });
    const previous = this.stateFingerprintBySession.get(session.id);
    let revision = this.stateRevisionBySession.get(session.id) ?? 0;
    if (previous === undefined || previous !== fingerprint) {
      revision += 1;
      this.stateFingerprintBySession.set(session.id, fingerprint);
      this.stateRevisionBySession.set(session.id, revision);
    }
    return revision;
  }

  private async resolveExactSession(
    sessionId: string,
    recoverTentativeRoute = false,
  ): Promise<DiscoveredProviderSession | undefined> {
    const hook = this.hookBySession.get(sessionId);
    const fallback = this.openedSessionBySession.get(sessionId)
      ?? this.chatBySession.get(sessionId)
      ?? (hook ? hookSession(hook) : undefined);
    const fallbackProvider = fallback
      ? this.providers.find((provider) => provider.id === fallback.provider)
      : undefined;
    let resolved: DiscoveredProviderSession | undefined;
    // Once a cached/opened record establishes provider identity, a failed
    // exact lookup means that provider no longer confirmed this conversation.
    // Do not let another adapter with a colliding ID take over its route.
    const resolverProviders = fallbackProvider?.resolve
      ? [fallbackProvider]
      : this.providers;
    for (const provider of resolverProviders) {
      if (!provider.resolve) continue;
      resolved = await provider.resolve(sessionId).catch(() => undefined);
      if (resolved) break;
    }
    if (!resolved) {
      if (!fallback) return undefined;
      // Providers without an exact resolver retain their existing native
      // evidence. A Codex resolver failure is different: keep the transcript
      // record readable, but mark every action route unavailable until the
      // provider confirms the conversation again.
      const record = fallbackProvider?.resolve
        ? markResolutionUnavailable(fallback)
        : fallback;
      const copy = structuredClone(record);
      this.rememberOpenedSession(copy);
      this.chatBySession.set(sessionId, copy);
      this.controlBySession.set(sessionId, structuredClone(copy));
      this.ensureChatGeneration(sessionId);
      return copy;
    }
    // A hook can enrich a resolved provider record, but it cannot replace its
    // archive/existence evidence. applyHooks keeps Codex lifecycle boundaries
    // authoritative when a hook is stale or belongs to an older turn.
    const merged = applyHooks([resolved], this.hookBySession);
    const record = merged.find((candidate) => candidate.id === sessionId) ?? resolved;
    let copy = structuredClone(record);
    const previousRoute = this.openedSessionBySession.get(sessionId)
      ?? this.chatBySession.get(sessionId);
    if (!recoverTentativeRoute
      && previousRoute?.provider === "codex"
      && previousRoute.messageTransport === "codex_app_server"
      && previousRoute.routeState === "unavailable"
      && previousRoute.routeUnavailableReason) {
      const terminalRouteProbe = previousRoute.confirmedTerminal === true
        && previousRoute.releasePending === true
        ? this.controls?.codexRouteStatus?.(sessionId)
        : undefined;
      const terminalReleaseConfirmed = previousRoute.releasePending !== true
        || (terminalRouteProbe !== undefined && terminalRouteProbe.releasePending !== true);
      const terminalAlreadyConfirmed = previousRoute.confirmedTerminal === true
        && terminalReleaseConfirmed
        && record.routeState === "available"
        && record.turnState === "ready";
      // An owner-only/provider failure is an explicit Send result. A later
      // read must not silently turn that result back into a writable claim;
      // only the user-facing availability retry clears it. A confirmed
      // terminal is the exception: once the closing child is gone and the
      // provider's exact read is ready, the next Send may attempt a fresh
      // route without pretending this process already owns it.
      if (!terminalAlreadyConfirmed) {
        copy = {
          ...copy,
          routeState: "unavailable",
          routeUnavailableReason: previousRoute.routeUnavailableReason,
          routeOwnership: previousRoute.routeOwnership
            ?? (previousRoute.routeUnavailableReason === "owner_only" ? "external" : "unverified"),
          ...(previousRoute.releasePending ? { releasePending: true } : {}),
          ...(previousRoute.confirmedTerminal ? { confirmedTerminal: true } : {}),
          ...(previousRoute.turnId ? { turnId: previousRoute.turnId } : {}),
        };
      }
    }
    this.rememberOpenedSession(copy);
    this.chatBySession.set(sessionId, copy);
    this.controlBySession.set(sessionId, structuredClone(copy));
    this.ensureChatGeneration(sessionId);
    return copy;
  }

  private withCodexRouteProbe(
    session: DiscoveredProviderSession,
    probe: SessionRouteProbeResult,
  ): DiscoveredProviderSession {
    const {
      routeUnavailableReason: _previousReason,
      releasePending: _previousReleasePending,
      confirmedTerminal: _previousConfirmedTerminal,
      turnId: _previousTurnId,
      routeOwnership: _previousOwnership,
      ...withoutRouteEvidence
    } = session;
    return {
      ...withoutRouteEvidence,
      routeState: probe.routeState,
      routeOwnership: probe.routeOwnership
        ?? (probe.routeState === "available"
          ? "unverified"
          : probe.unavailableReason === "owner_only" ? "external" : "unverified"),
      ...(probe.unavailableReason ? { routeUnavailableReason: probe.unavailableReason } : {}),
      ...(probe.releasePending ? { releasePending: true } : {}),
      ...(probe.confirmedTerminal ? { confirmedTerminal: true } : {}),
      ...(probe.turnState ? { turnState: probe.turnState } : {}),
      ...(probe.turnId ? { turnId: probe.turnId } : {}),
    };
  }

  private rememberOpenedSession(session: DiscoveredProviderSession): void {
    this.openedSessionBySession.set(session.id, structuredClone(session));
    this.trimOpenedSessionCache();
  }

  private trimOpenedSessionCache(): void {
    if (this.openedSessionBySession.size <= maxOpenedSessionRecords) return;
    for (const sessionId of this.openedSessionBySession.keys()) {
      if (this.openedSessionBySession.size <= maxOpenedSessionRecords) break;
      if ((this.chatOpenReferencesBySession.get(sessionId) ?? 0) > 0) continue;
      this.openedSessionBySession.delete(sessionId);
    }
  }

  async refresh(): Promise<SessionSnapshot> {
    const discovered = await Promise.all(this.providers.map(async (provider) => {
      try {
        const sessions = await provider.discover();
        const generation = (this.providerDiscoveryGeneration.get(provider.id) ?? 0) + 1;
        this.providerDiscoveryGeneration.set(provider.id, generation);
        this.lastByProvider.set(provider.id, structuredClone(sessions));
        if (provider.id === "pi") this.piDiscoveryGeneration += 1;
        return sessions;
      } catch {
        return this.lastByProvider.get(provider.id) ?? [];
      }
    }));
    // Exact opened chats are refreshed independently of the provider's
    // bounded ambient catalog. This preserves their generation and delivery
    // ledgers while still allowing a recovered provider to restore authority.
    await Promise.all([...this.openedSessionBySession.keys()]
      .map((sessionId) => this.resolveExactSession(sessionId)));
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
        } else if (isPhaseNeutralNotification(event)) {
          if (!previous) this.hookBySession.set(event.sessionId, notificationPresentation(event));
        } else {
          this.hookBySession.set(event.sessionId, structuredClone(event));
        }
      }
    }
    this.reconcileTerminalNextTurnHook(event);
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
    this.reconcileTerminalNextTurns(discovered);
    const authoritative = new Map<string, DiscoveredProviderSession>();
    for (const record of discovered) {
      const existing = authoritative.get(record.id);
      if (!existing || (record.authority ?? 1) > (existing.authority ?? 1)) {
        authoritative.set(record.id, record);
      }
    }
    const ambientMerged = applyHooks(discovered, this.hookBySession);
    const openedRecords = [...this.openedSessionBySession.entries()].map(([sessionId, session]) => {
      // Hook events can arrive between exact refreshes. Keep the opened
      // record's provider identity while applying the same current hook facts
      // that drive the ambient view.
      const hooked = applyHooks([session], this.hookBySession)[0] ?? session;
      let copy = structuredClone(hooked);
      this.openedSessionBySession.set(sessionId, copy);
      return copy;
    });
    const openedIDs = new Set(openedRecords.map((session) => session.id));
    const ambientIDs = new Set(discovered.map((session) => session.id));
    // Once a conversation is opened, its exact record is authoritative for
    // both Chat and its session summary. Ambient discovery may be stale or
    // bounded, and must not restore a writable route after exact lookup
    // failed.
    const merged = [
      ...ambientMerged.filter((session) => !openedIDs.has(session.id)),
      ...openedRecords,
    ];
    for (const record of merged) {
      if (this.pendingActions(record.id).some((action) => action.type === "approval" || action.type === "question")) {
        record.section = "needs_you";
        record.turnState = "needs_you";
        record.subtitle = "Approval required";
        const latestApproval = [...(this.externalActions.get(record.id)?.values() ?? [])]
          .find((action) => action.state === "pending");
        record.updatedAt = latestApproval?.receivedAt ?? new Date().toISOString();
      }
    }
    // Views and actions now consume the same hook-merged record. Provider
    // authority still supplies owner/target identity, but a list section or a
    // stale pre-hook projection cannot silently disagree with Chat.
    this.chatBySession.clear();
    for (const record of merged) {
      if (!record.chatPath) continue;
      const authority = authoritative.get(record.id);
      const owner = authority?.owner ?? record.owner;
      const cachedSettings = this.chatSettingsCatalogBySession.get(record.id);
      if (cachedSettings && (
        record.provider !== "codex"
        || cachedSettings.cwd !== record.cwd
        || cachedSettings.expiresAt <= Date.now()
      )) {
        this.chatSettingsCatalogBySession.delete(record.id);
      }
      const cachedCurrent = this.chatSettingsCurrentBySession.get(record.id);
      if (cachedCurrent && (record.provider !== "codex" || cachedCurrent.cwd !== record.cwd)) {
        this.chatSettingsCurrentBySession.delete(record.id);
      }
      this.chatBySession.set(record.id, structuredClone({
        ...record,
        owner,
        ...(authority?.controlTarget ? { controlTarget: authority.controlTarget } : {}),
        ...(owner === "Zed" ? { messageTransport: undefined } : {}),
      }));
    }
    const previousControlSessionIDs = new Set(this.controlBySession.keys());
    this.controlBySession.clear();
    for (const record of merged) {
      const existing = this.controlBySession.get(record.id);
      if (!existing || (record.authority ?? 1) > (existing.authority ?? 1)) {
        this.controlBySession.set(record.id, structuredClone(record));
      }
    }
    // Keep exact opened records available to Chat and controls, but do not
    // pull an older conversation back into the ambient session list merely
    // because it is still open in a renderer.
    const snapshotSource = merged.filter((session) =>
      ambientIDs.has(session.id)
      // Hook-only integrations (for example Claude/Auggie) are already
      // authoritative rows even when their provider catalog is empty. Keep
      // them visible, while still keeping an older opened record out of the
      // ambient list when the bounded catalog no longer contains it.
      || (this.hookBySession.has(session.id) && !openedIDs.has(session.id)));
    const projectedSnapshotSource = snapshotSource.map((session) =>
      this.projectedTerminalSession(session));
    const sessions = normalize(projectedSnapshotSource);
    const mergedByID = new Map(projectedSnapshotSource.map((session) => [session.id, session]));
    for (const summary of sessions) {
      const source = mergedByID.get(summary.id);
      if (!source) continue;
      const state = resolveSessionState(source, {
        nativeHelperAvailable: this.controls?.isAvailable?.() !== false,
      });
      summary.sessionState = state;
      summary.stateRevision = this.stateRevisionForSession(source, state);
    }
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
      session.attentionTier = session.sessionClass === "automation"
        ? "history"
        : session.section === "ready" && this.acknowledgedReadyIDs.has(session.id)
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
      existing.turnState = phase.turnState;
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
      turnState: phase.turnState,
      subtitle: phase.subtitle,
      updatedAt: hook.activityAt ?? hook.receivedAt,
      canOpenOwner: Boolean(hook.pid || hook.tty),
      canEnterChat: hookCanEnterChat(hook),
      sessionClass: hook.tty ? "terminal" : "interactive",
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

/**
 * Claude Code emits `Notification` hooks as signals about a session, not as
 * lifecycle transitions: an `idle_prompt` roughly every minute while it waits
 * for the user, plus auth and elicitation events. The hook script reports the
 * idle prompt as `waiting_for_input`, which would read as an approval request
 * if it were treated as a phase. A notification therefore never moves a
 * session between sections and never refreshes its recency; the previous
 * lifecycle hook stays authoritative. This mirrors the Swift SessionStore,
 * which skips phase transitions for notifications for the same reason.
 */
function isPhaseNeutralNotification(event: HookSessionEvent): boolean {
  return event.event === "Notification" && !event.expectsResponse;
}

/**
 * Presentation for a notification that arrives with no previous lifecycle
 * hook (daemon restart, hook installed mid-session). An idle prompt is then
 * the only evidence and it proves the agent is waiting for input, so it is
 * recorded as a settled Stop. Anything else is kept as-is.
 */
function notificationPresentation(event: HookSessionEvent): HookSessionEvent {
  if (event.status.trim().toLowerCase() === "waiting_for_input") {
    return { ...structuredClone(event), event: "Stop", status: "idle" };
  }
  return structuredClone(event);
}

function transcriptModifiedAt(event: HookSessionEvent): string | undefined {
  if (!event.sessionFile) return undefined;
  try {
    return statSync(event.sessionFile).mtime.toISOString();
  } catch {
    return undefined;
  }
}

function hookPhase(event: HookSessionEvent): {
  section: SessionSection;
  turnState: SessionTurnState;
  subtitle: string;
} {
  const status = event.status.trim().toLowerCase();
  if (event.event === "Stop") {
    return { section: "ready", turnState: "ready", subtitle: "Ready to continue" };
  }
  if (isPhaseNeutralNotification(event) && status === "waiting_for_input") {
    // An idle prompt: the agent waits for the user, not for an approval.
    return { section: "ready", subtitle: "Ready to continue" };
  }
  if (event.expectsResponse || event.event === "PermissionRequest"
    || status.includes("approval") || status === "waiting_for_input") {
    return { section: "needs_you", turnState: "needs_you", subtitle: "Approval required" };
  }
  if (event.event === "SessionEnd"
    || ["ended", "exited", "closed", "inactive", "stopped", "terminated"].includes(status)) {
    return { section: "history", turnState: "unknown", subtitle: "Session ended" };
  }
  if (!isPiHeartbeat(event) && (event.isIdle === true || status === "idle")) {
    return { section: "ready", turnState: "ready", subtitle: "Ready to continue" };
  }
  return { section: "working", turnState: "working", subtitle: "Agent is working" };
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
    turnState: hookPhase(hook).turnState,
    updatedAt: hook.activityAt ?? hook.receivedAt,
    canOpenOwner: hook.provider !== "codex" && Boolean(hook.pid || hook.tty),
    canEnterChat: hookCanEnterChat(hook),
    sessionClass: hook.tty ? "terminal" : "interactive",
    chatPath: hook.sessionFile,
  };
}

function markResolutionUnavailable(
  session: DiscoveredProviderSession,
): DiscoveredProviderSession {
  return {
    ...session,
    resolutionUnavailable: true,
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
    session.sessionClass,
    session.resolutionUnavailable === true,
    session.routeState,
    session.routeOwnership,
    session.routeUnavailableReason,
    session.releasePending === true,
    session.confirmedTerminal === true,
    conversationState(session),
    sessionTurnState(session),
    session.turnId ?? session.codexLifecycle?.turnId,
    session.cwd,
    session.chatPath,
    session.messageTransport,
    session.transcriptRevision,
    session.controlTarget,
  ]);
}

function validateChatSettings(
  session: DiscoveredProviderSession,
  settings: ChatSettingsPatch | undefined,
  currentSettings?: {
    cwd: string;
    current: ChatSettings["current"];
  },
): string | undefined {
  if (!settings) return undefined;
  if (session.provider !== "codex" || session.messageTransport !== "codex_app_server") {
    return "Model and permission controls are unavailable for this session.";
  }
  const catalog = session.chatSettingsCatalog;
  if (!catalog) return "Codex settings are unavailable. Reopen the conversation and try again.";
  const model = settings.modelId
    ? catalog.models.find(({ id }) => id === settings.modelId)
    : undefined;
  if (settings.modelId && !model) return "The selected Codex model is unavailable.";
  if (settings.reasoningEffort) {
    const effectiveModelId = settings.modelId
      ?? (currentSettings?.cwd === session.cwd ? currentSettings.current.modelId : undefined);
    const effectiveModel = model
      ?? (effectiveModelId
        ? catalog.models.find(({ id }) => id === effectiveModelId)
        : undefined);
    if (!effectiveModel) return "The current Codex model is unknown; select a model before choosing reasoning.";
    if (!effectiveModel.reasoningEfforts.some(({ value }) => value === settings.reasoningEffort)) {
      return "The selected reasoning level is unavailable for Codex.";
    }
  }
  if (settings.permissionProfile) {
    const profile = catalog.permissionProfiles.find(({ id }) => id === settings.permissionProfile);
    if (!profile?.allowed) return "The selected Codex permission profile is unavailable.";
  }
  return undefined;
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

function codexRouteRecoveryMessage(
  reason: SessionRouteRecoveryResult["reason"],
): string {
  switch (reason) {
    case "release_pending":
      return "The Codex route is still closing. Retry after it settles.";
    case "identity_mismatch":
      return "Codex reported a different turn identity for the lost turn. Continue in Codex, then retry.";
    case "identity_unavailable":
    default:
      return "Codex could not confirm the lost turn's exact identity. Continue in Codex, then retry.";
  }
}

function isTerminalChatRoute(session: DiscoveredProviderSession): boolean {
  return session.messageTransport === "terminal"
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
      ...(session.sessionClass ? { sessionClass: session.sessionClass } : {}),
      ...(session.conversationState || session.turnState
        ? { sessionState: resolveSessionState(session) } : {}),
      ...(session.stateRevision !== undefined ? { stateRevision: session.stateRevision } : {}),
    }))
    .sort((left, right) =>
      right.updatedAt.localeCompare(left.updatedAt) || left.id.localeCompare(right.id));
}
