import type {
  ChatPage,
  ChatCommands,
  SessionSection,
} from "@agent-visor/protocol";
import { serverMessageSchema } from "@agent-visor/protocol";
import type { DaemonConnection } from "./daemon-connection";
import { mergeChatPage } from "./chat-presentation";
import {
  ChatPaginationWindow,
  boundChatItems,
} from "./chat-pagination-window";
import {
  CHAT_DELIVERY_TTL_MS,
  CHAT_DELIVERY_UNCERTAIN_ERROR,
  createPendingChatDeliveryStore,
  type DeliveryClock,
  type PendingChatDelivery,
  type PendingChatDeliveryStore,
  type SubmittedChatDraft,
} from "./chat-delivery";
import {
  type ChatComposerSnapshot,
  type ChatDeliveryRecoveryRecord,
  type ChatDeliveryRecoveryStore,
  type ChatDeliveryRetryDecision,
  createChatDeliveryRecoveryStore,
} from "./chat-delivery-recovery";
import { nextPermissionMode } from "./chat-status";

export type ChatSessionState = {
  sessionId: string;
  status: "loading" | "loaded" | "failed";
  page?: ChatPage;
  /** The latest request-owned delivery, used to match page cancel identity. */
  activeDeliveryId?: string;
  /** App-level cancellation capability after matching the page identity. */
  canCancelForActiveDelivery?: boolean;
  error?: string;
  cancel?: ChatCancellationState;
  recovery?: ChatDeliveryRecoveryRecord[];
  recoveryCommand?: ChatRecoveryCommand;
  /** True when rendering stopped at the explicit client history safety cap. */
  clientHistoryLimitReached?: boolean;
  /** Exact renderer-owned permission cycle, if one is awaiting its result. */
  permissionModeCycle?: ChatPermissionModeCycleState;
  /** Optimistic Claude mode, cleared only by matching canonical metadata. */
  optimisticPermissionMode?: string;
};

export type ChatPermissionModeCycleState = {
  status: "cycling";
  requestId: string;
  generation: number;
  expectedMode: string;
  nextMode: string;
};

export type ChatRecoveryCommand =
  | {
    type: "restore";
    id: string;
    recoveryId: string;
    draft: SubmittedChatDraft;
    expectedComposer: ChatComposerSnapshot;
    expectedRevision: number;
  }
  | {
    type: "clear";
    id: string;
    recoveryId: string;
    draft: SubmittedChatDraft;
    expectedComposer: SubmittedChatDraft;
  };

export type ChatRecoveryRetryDelivery = ChatDeliveryRetryDecision & {
  delivery: PendingChatDelivery;
  send: boolean;
};

export type ChatCancellationState = {
  status: "canceling" | "confirmed" | "failed";
  requestId: string;
  generation: number;
  deliveryId?: string;
};

export type ChatSessionController = {
  activate(sessionId: string, section?: SessionSection): number;
  deactivate(generation: number): void;
  setSection(generation: number, section: SessionSection): void;
  noteComposerDraft(generation: number, draft: SubmittedChatDraft): void;
  requestLatest(generation: number, requestId: string): void;
  beginDelivery(generation: number, draft: SubmittedChatDraft): PendingChatDelivery | undefined;
  failDelivery(
    generation: number,
    requestId: string,
    deliveryId: string,
    error: string,
  ): PendingChatDelivery | undefined;
  expireDeliveries(generation: number): PendingChatDelivery[];
  nextDeliveryExpiry(generation: number): number | undefined;
  retryRecovery(generation: number, recoveryId: string): ChatRecoveryRetryDelivery | undefined;
  dismissRecovery(generation: number, recoveryId: string): boolean;
  noteDelivery(generation: number, deliveryId: string): void;
  requestCancel(generation: number, connection: DaemonConnection): boolean;
  requestCyclePermissionMode(generation: number, connection: DaemonConnection): boolean;
  requestEarlier(generation: number, requestId?: string, before?: number): boolean;
  cancelEarlier(generation: number, requestId: string): boolean;
  requestSlashCommands(generation: number, requestId: string): void;
  receive(generation: number, data: string, connection: DaemonConnection): void;
  disconnect(generation: number): void;
  currentState(): ChatSessionState;
};

type ChatSessionControllerHandlers = {
  onState(state: ChatSessionState): void;
  onSlashCommands(commands: ChatCommands | undefined, sessionId: string, error?: string): void;
  onOpenLatest(connection: DaemonConnection, sessionId: string, requestId: string): void;
};

export type ChatSessionControllerOptions = {
  createRequestId?: () => string;
  createDeliveryId?: () => string;
  deliveryClock?: DeliveryClock;
  deliveryStore?: PendingChatDeliveryStore;
  recoveryStore?: ChatDeliveryRecoveryStore;
};

export function createChatSessionController(
  handlers: ChatSessionControllerHandlers,
  options: ChatSessionControllerOptions = {},
): ChatSessionController {
  let generation = 0;
  let state: ChatSessionState = { sessionId: "", status: "loading" };
  let latestUpdatedAt: string | undefined;
  let nextPageMode: "latest" | "earlier" = "latest";
  type OpenChatRequest = {
    sessionId: string;
    generation: number;
    mode: "latest" | "earlier";
    epoch: number;
    createdAt: number;
    before?: number;
    expandsWindow?: boolean;
  };
  const openChatRequests = new Map<string, OpenChatRequest>();
  const latestRequestEpochByScope = new Map<string, number>();
  let activeSessionId = "";
  let activeSection: SessionSection | undefined;
  let lastDeliveryId: string | undefined;
  let cancelRequest: ChatCancellationState | undefined;
  let permissionModeCycle: ChatPermissionModeCycleState | undefined;
  let optimisticPermissionMode: string | undefined;
  let slashRequestId: string | undefined;
  const createRequestId = options.createRequestId ?? defaultRequestId;
  const createDeliveryId = options.createDeliveryId ?? defaultDeliveryId;
  const deliveryClock = options.deliveryClock ?? { now: () => Date.now() };
  const deliveryStore = options.deliveryStore ?? createPendingChatDeliveryStore({ clock: deliveryClock });
  const recoveryStore = options.recoveryStore ?? createChatDeliveryRecoveryStore({
    clock: deliveryClock,
    createRequestId,
    createDeliveryId,
  });
  let composerDraft: SubmittedChatDraft = { text: "", images: [] };
  let composerRevision = 0;
  let recoveryCommandSerial = 0;
  const allowedEmptyRevisionsByDelivery = new Map<string, number[]>();
  // The first authoritative latest page is the transcript baseline. Keep the
  // marker scoped to this session generation so an optimistic send racing
  // initial loading cannot be confirmed by an old identical row.
  const observedLatestPageScopes = new Set<string>();
  let latestBaselineAllowsContentFallback = false;
  let paginationWindow = new ChatPaginationWindow();
  let droppedHistoryAtSafetyCap = false;
  // Keep the identity of synthetic rows after their delivery record is
  // removed.  Otherwise a later recovery dismissal/cancel would leave the
  // already-published optimistic row stranded in state.page.  Canonical IDs
  // are tracked separately so a provider row is never removed merely because
  // it happens to reuse a synthetic row ID.
  const syntheticDeliveryRowIds = new Set<string>();
  const canonicalItemIds = new Set<string>();
  const pendingSends = new Map<string, {
    sessionId: string;
    generation: number;
    deliveryId: string;
    recoveryId?: string;
  }>();

  const publish = (next: ChatSessionState): void => {
    state = next;
    handlers.onState(next);
  };

  const isCurrent = (candidate: number): boolean => candidate === generation;

  function rehydratePendingSendsForScope(sessionId: string, candidate: number): void {
    const deliveries = deliveryStore.get(sessionId, candidate);
    const recovery = recoveryStore.list(sessionId, candidate);
    const liveDeliveryIds = new Set(deliveries.map((delivery) => delivery.deliveryId));

    // A retry remains in the recovery ledger while it is awaiting canonical
    // proof. If the replacement delivery survived scope migration, restore its
    // request identity so an ACK from the new renderer can settle it exactly.
    for (const delivery of deliveries) {
      if (delivery.status !== "pending") continue;
      const source = recovery.find((record) => (
        record.retryRequestId === delivery.requestId
        && record.retryDeliveryId === delivery.deliveryId
      ));
      pendingSends.set(delivery.requestId, {
        sessionId,
        generation: candidate,
        deliveryId: delivery.deliveryId,
        ...(source ? { recoveryId: source.id } : {}),
      });
    }

    // A renderer can disappear between recovery.retry() and the replacement
    // delivery admission. Do not leave its card in a permanent retrying state.
    for (const record of recovery) {
      if (record.status !== "retrying" || !record.retryRequestId || !record.retryDeliveryId) continue;
      if (liveDeliveryIds.has(record.retryDeliveryId)) continue;
      recoveryStore.markRetryUncertain({
        sessionId,
        generation: candidate,
        requestId: record.retryRequestId,
        deliveryId: record.retryDeliveryId,
        error: "The retry was interrupted before the provider accepted it.",
      });
    }
  }

  return {
    activate(sessionId, section) {
      generation += 1;
      activeSessionId = sessionId;
      activeSection = section;
      lastDeliveryId = undefined;
      cancelRequest = undefined;
      permissionModeCycle = undefined;
      optimisticPermissionMode = undefined;
      pendingSends.clear();
      latestUpdatedAt = undefined;
      nextPageMode = "latest";
      openChatRequests.clear();
      latestRequestEpochByScope.clear();
      latestBaselineAllowsContentFallback = false;
      paginationWindow = new ChatPaginationWindow();
      droppedHistoryAtSafetyCap = false;
      slashRequestId = undefined;
      composerDraft = { text: "", images: [] };
      composerRevision = 0;
      recoveryCommandSerial = 0;
      allowedEmptyRevisionsByDelivery.clear();
      syntheticDeliveryRowIds.clear();
      canonicalItemIds.clear();
      observedLatestPageScopes.clear();
      deliveryStore.activate(sessionId, generation);
      recoveryStore.activate(sessionId, generation);
      rehydratePendingSendsForScope(sessionId, generation);
      handlers.onSlashCommands(undefined, sessionId);
      publish({ sessionId, status: "loading" });
      return generation;
    },
    deactivate(candidate) {
      if (!isCurrent(candidate)) return;
      generation += 1;
      activeSection = undefined;
      lastDeliveryId = undefined;
      cancelRequest = undefined;
      permissionModeCycle = undefined;
      optimisticPermissionMode = undefined;
      pendingSends.clear();
      allowedEmptyRevisionsByDelivery.clear();
      openChatRequests.clear();
      latestRequestEpochByScope.clear();
      latestBaselineAllowsContentFallback = false;
      paginationWindow = new ChatPaginationWindow();
      droppedHistoryAtSafetyCap = false;
    },
    setSection(candidate, section) {
      if (isCurrent(candidate)) activeSection = section;
    },
    noteComposerDraft(candidate, draft) {
      if (!isCurrent(candidate)) return;
      composerRevision += 1;
      composerDraft = cloneSubmittedDraft(draft);
    },
    requestLatest(candidate, requestId) {
      if (!isCurrent(candidate) || requestId.length === 0) return;
      registerLatestRequest(candidate, requestId);
      nextPageMode = "latest";
    },
    beginDelivery(candidate, draft) {
      if (!isCurrent(candidate)
        || !state.page?.capabilities.canSendText
        || activeSessionId.length === 0) return undefined;
      const requestId = createRequestId();
      const deliveryId = createDeliveryId();
      const delivery = deliveryStore.begin({
        sessionId: activeSessionId,
        generation: candidate,
        requestId,
        deliveryId,
        draft,
        allowContentFallback: latestBaselineAllowsContentFallback,
      });
      if (!delivery) return undefined;
      rememberBoundedId(syntheticDeliveryRowIds, delivery.optimisticRowId);
      // Only the submit clear is eligible for automatic recovery. A later
      // user Clear/Escape increments the revision and must not be treated as
      // an unchanged post-submit composer.
      rememberAllowedEmptyRevision(delivery.deliveryId);
      pendingSends.set(requestId, {
        sessionId: activeSessionId,
        generation: candidate,
        deliveryId,
      });
      lastDeliveryId = deliveryId;
      const page = withDeliveryRows(
        withoutDeliveryRows(state.page!, activeSessionId, candidate),
        activeSessionId,
        candidate,
      );
      if (state.cancel) {
        // A new submission starts a new cancellation lifecycle. Clear the
        // previous outcome so Stop is derived from this delivery's identity,
        // while leaving any failed/canceled recovery record untouched.
        cancelRequest = undefined;
        publishWithRecovery(candidate, {
          ...state,
          page,
          activeDeliveryId: deliveryId,
          cancel: undefined,
          error: undefined,
        });
      } else {
        publishWithRecovery(candidate, { ...state, page, activeDeliveryId: deliveryId });
      }
      return delivery;
    },
    failDelivery(candidate, requestId, deliveryId, error) {
      if (!isCurrent(candidate)) return undefined;
      const pending = pendingSends.get(requestId);
      const original = deliveryStore.get(activeSessionId, candidate)
        .find((delivery) => delivery.requestId === requestId && delivery.deliveryId === deliveryId);
      const failed = deliveryStore.acknowledge({
        sessionId: activeSessionId,
        generation: candidate,
        requestId,
        deliveryId,
        ok: false,
        error,
      });
      if (!failed) return undefined;
      pendingSends.delete(requestId);
      if (lastDeliveryId === deliveryId) lastDeliveryId = undefined;
      const allowedEmptyRevisions = allowedEmptyRevisionsByDelivery.get(deliveryId);
      allowedEmptyRevisionsByDelivery.delete(deliveryId);
      if (pending?.recoveryId) {
        recoveryStore.completeRetry({
          sessionId: activeSessionId,
          generation: candidate,
          recoveryId: pending.recoveryId,
          requestId,
          deliveryId,
          ok: false,
        });
      }
      const recovery = recoveryStore.recordFailure({
        sessionId: activeSessionId,
        generation: candidate,
        requestId,
        deliveryId,
        draft: original?.draft ?? failed.draft,
        error,
        cause: "send-failed",
        currentComposer: currentComposerSnapshot(),
        allowedEmptyRevisions,
      });
      publishPageWithDeliveries(candidate);
      publishWithRecovery(candidate, {
        ...state,
        error,
      }, recovery ? restoreCommand(recovery.restore) : undefined);
      return failed;
    },
    expireDeliveries(candidate) {
      if (!isCurrent(candidate)) return [];
      const expired = deliveryStore.expire({
        sessionId: activeSessionId,
        generation: candidate,
        now: deliveryClock.now(),
      });
      if (expired.length) {
        let command: ChatRecoveryCommand | undefined;
        for (const delivery of expired) {
          const pending = pendingSends.get(delivery.requestId);
          pendingSends.delete(delivery.requestId);
          const allowedEmptyRevisions = allowedEmptyRevisionsByDelivery.get(delivery.deliveryId);
          allowedEmptyRevisionsByDelivery.delete(delivery.deliveryId);
          let recovery: ReturnType<ChatDeliveryRecoveryStore["recordFailure"]> | undefined;
          if (delivery.status === "uncertain") {
            // An acknowledged retry remains in its original lineage until
            // canonical proof. Deadline expiry changes that lineage to an
            // explicit uncertain state instead of deleting the recovery card.
            const retryRecord = recoveryStore.list(activeSessionId, candidate)
              .find((record) => (
                record.retryRequestId === delivery.requestId
                && record.retryDeliveryId === delivery.deliveryId
              ));
            if (retryRecord) {
              recoveryStore.markRetryUncertain({
                sessionId: activeSessionId,
                generation: candidate,
                requestId: delivery.requestId,
                deliveryId: delivery.deliveryId,
                error: delivery.error ?? CHAT_DELIVERY_UNCERTAIN_ERROR,
              });
            } else {
              recovery = recoveryStore.recordFailure({
                sessionId: activeSessionId,
                generation: candidate,
                requestId: delivery.requestId,
                deliveryId: delivery.deliveryId,
                draft: delivery.draft,
                error: delivery.error ?? CHAT_DELIVERY_UNCERTAIN_ERROR,
                cause: "delivery-uncertain",
                currentComposer: currentComposerSnapshot(),
                allowedEmptyRevisions,
              });
            }
          } else {
            if (pending?.recoveryId) {
              recoveryStore.completeRetry({
                sessionId: activeSessionId,
                generation: candidate,
                recoveryId: pending.recoveryId,
                requestId: delivery.requestId,
                deliveryId: delivery.deliveryId,
                ok: false,
              });
            }
            recovery = recoveryStore.recordFailure({
              sessionId: activeSessionId,
              generation: candidate,
              requestId: delivery.requestId,
              deliveryId: delivery.deliveryId,
              draft: delivery.draft,
              error: delivery.error ?? "The message delivery window expired.",
              cause: "delivery-expired",
              currentComposer: currentComposerSnapshot(),
              allowedEmptyRevisions,
            });
          }
          if (lastDeliveryId === delivery.deliveryId) lastDeliveryId = undefined;
          if (!command && recovery) command = restoreCommand(recovery.restore);
        }
        publishPageWithDeliveries(candidate);
        publishWithRecovery(candidate, {
          ...state,
          error: expired[0]?.error ?? "The message delivery window expired.",
        }, command);
      }
      return expired;
    },
    nextDeliveryExpiry(candidate) {
      if (!isCurrent(candidate)) return undefined;
      const pending = deliveryStore.get(activeSessionId, candidate)
        .filter((delivery) => delivery.status === "pending" || delivery.status === "acknowledged");
      if (!pending.length) return undefined;
      return Math.min(...pending.map((delivery) => delivery.createdAt + CHAT_DELIVERY_TTL_MS));
    },
    retryRecovery(candidate, recoveryId) {
      if (!isCurrent(candidate)
        || !state.page?.capabilities.canSendText) return undefined;
      const decision = recoveryStore.retry({
        sessionId: activeSessionId,
        generation: candidate,
        recoveryId,
        currentComposer: currentComposerSnapshot(),
      });
      if (!decision) return undefined;
      const existing = deliveryStore.get(activeSessionId, candidate)
        .find((delivery) => (
          delivery.requestId === decision.requestId && delivery.deliveryId === decision.deliveryId
        ));
      if (!decision.isNew && existing) {
        return { ...decision, delivery: existing, send: false };
      }
      const delivery = deliveryStore.begin({
        sessionId: activeSessionId,
        generation: candidate,
        requestId: decision.requestId,
        deliveryId: decision.deliveryId,
        draft: decision.draft,
        allowContentFallback: latestBaselineAllowsContentFallback,
        replace: {
          requestId: decision.source.requestId,
          deliveryId: decision.source.deliveryId,
        },
      });
      if (!delivery) {
        recoveryStore.rollbackRetry({
          sessionId: activeSessionId,
          generation: candidate,
          recoveryId,
          requestId: decision.requestId,
          deliveryId: decision.deliveryId,
        });
        publishWithRecovery(candidate, state);
        return undefined;
      }
      // Keep the original delivery in the store's identity lineage until an
      // explicit original/replacement canonical row settles it. Removing it
      // here would let a late content-only original be guessed as the retry.
      // A retry clears the composer through a recovery command after this
      // method returns. Reserve the post-command revision so a failed retry
      // can restore its immutable snapshot without mistaking that guarded
      // programmatic clear for a user edit.
      rememberAllowedEmptyRevision(
        delivery.deliveryId,
        decision.clearComposer ? composerRevision + 1 : composerRevision,
      );
      pendingSends.set(delivery.requestId, {
        sessionId: activeSessionId,
        generation: candidate,
        deliveryId: delivery.deliveryId,
        recoveryId,
      });
      lastDeliveryId = delivery.deliveryId;
      publishWithRecovery(candidate, state, decision.clearComposer ? clearCommand(decision) : undefined);
      return { ...decision, delivery, send: true };
    },
    dismissRecovery(candidate, recoveryId) {
      if (!isCurrent(candidate)) return false;
      const record = recoveryStore.dismiss({
        sessionId: activeSessionId,
        generation: candidate,
        recoveryId,
      });
      if (!record) return false;
      if (lastDeliveryId === record.deliveryId) lastDeliveryId = undefined;
      deliveryStore.dismiss({
        sessionId: activeSessionId,
        generation: candidate,
        requestId: record.requestId,
        deliveryId: record.deliveryId,
      });
      // Rebuild the displayed page after removing the recovery/delivery
      // record so the synthetic optimistic row disappears immediately.
      publishPageWithDeliveries(candidate);
      publishWithRecovery(candidate, {
        ...state,
        ...(state.error === record.error ? { error: undefined } : {}),
      });
      return true;
    },
    noteDelivery(candidate, deliveryId) {
      if (!isCurrent(candidate)) return;
      lastDeliveryId = deliveryId;
      if (state.cancel) {
        publishWithRecovery(candidate, {
          ...state,
          activeDeliveryId: deliveryId,
          cancel: undefined,
          error: undefined,
        });
      } else {
        publishWithRecovery(candidate, { ...state, activeDeliveryId: deliveryId });
      }
    },
    requestCancel(candidate, connection) {
      const page = state.page;
      if (!isCurrent(candidate)
        || activeSection !== "working"
        || !state.canCancelForActiveDelivery
        || !page
        || !lastDeliveryId
        || page.capabilities.cancelDeliveryId !== lastDeliveryId
        || cancelRequest) return false;
      const requestId = createRequestId();
      const request: Extract<import("@agent-visor/protocol").ClientMessage, { type: "cancel_chat" }> = {
        type: "cancel_chat",
        id: requestId,
        sessionId: activeSessionId,
        generation: candidate,
        ...(lastDeliveryId ? { deliveryId: lastDeliveryId } : {}),
      };
      let sent = false;
      try {
        sent = connection.send(JSON.stringify(request));
      } catch {
        sent = false;
      }
      const identity: ChatCancellationState = {
        status: sent ? "canceling" : "failed",
        requestId,
        generation: candidate,
        ...(lastDeliveryId ? { deliveryId: lastDeliveryId } : {}),
      };
      if (sent) cancelRequest = identity;
      publish({
        ...state,
        cancel: identity,
        ...(sent
          ? { error: undefined }
          : { error: "The cancellation request could not be sent." }),
      });
      return sent;
    },
    requestCyclePermissionMode(candidate, connection) {
      const page = state.page;
      const expectedMode = page?.metadata?.permissionMode;
      const nextMode = expectedMode ? nextPermissionMode(expectedMode) : undefined;
      if (!isCurrent(candidate)
        || activeSection !== "working"
        || !page
        || page.capabilities.canCyclePermissionMode !== true
        || !expectedMode
        || !nextMode
        || permissionModeCycle
        || optimisticPermissionMode) return false;
      const requestId = createRequestId();
      const request: Extract<import("@agent-visor/protocol").ClientMessage, { type: "cycle_permission_mode" }> = {
        type: "cycle_permission_mode",
        id: requestId,
        sessionId: activeSessionId,
        generation: candidate,
        expectedMode,
      };
      let sent = false;
      try {
        sent = connection.send(JSON.stringify(request));
      } catch {
        sent = false;
      }
      if (!sent) {
        publishWithRecovery(candidate, {
          ...state,
          error: "The permission mode request could not be sent.",
        });
        return false;
      }
      permissionModeCycle = {
        status: "cycling",
        requestId,
        generation: candidate,
        expectedMode,
        nextMode,
      };
      optimisticPermissionMode = nextMode;
      publishWithRecovery(candidate, { ...state, error: undefined });
      return true;
    },
    requestEarlier(candidate, requestId, before) {
      if (!isCurrent(candidate) || state.clientHistoryLimitReached) return false;
      const cursor = before ?? state.page?.nextBefore;
      if (requestId) {
        if (!registerEarlierRequest(candidate, requestId, cursor)) return false;
        const request = openChatRequests.get(requestId);
        if (request) request.expandsWindow = true;
      }
      nextPageMode = "earlier";
      return true;
    },
    cancelEarlier(candidate, requestId) {
      if (!isCurrent(candidate)) return false;
      const request = openChatRequests.get(requestId);
      if (!request
        || request.sessionId !== activeSessionId
        || request.generation !== candidate
        || request.mode !== "earlier") return false;
      openChatRequests.delete(requestId);
      if (nextPageMode === "earlier") nextPageMode = "latest";
      return true;
    },
    requestSlashCommands(candidate, requestId) {
      if (isCurrent(candidate)) slashRequestId = requestId;
    },
    receive(candidate, data, connection) {
      if (!isCurrent(candidate)) return;
      pruneOpenChatRequests();
      const message = parseServerMessage(data);
      if (!message) return;
      if (message.type === "daemon_error") {
        if (message.sessionId !== activeSessionId) return;
        const pageRequest = message.requestId
          ? openChatRequests.get(message.requestId)
          : undefined;
        const isActiveLatestPageError = message.requestType === "open_chat"
          && (!message.responseType || message.responseType === "chat_page")
          && (
            (message.requestId === undefined && !hasLatestRequestIdentity(candidate))
            || (pageRequest?.sessionId === activeSessionId
              && pageRequest.generation === candidate
              && pageRequest.mode === "latest"
              && pageRequest.epoch === latestRequestEpochByScope.get(requestScopeKey(activeSessionId, candidate)))
          );
        if (isActiveLatestPageError) {
          if (message.requestId) openChatRequests.delete(message.requestId);
          publish({
            sessionId: activeSessionId,
            status: "failed",
            error: message.message,
          });
        } else if (message.requestType === "get_chat_commands"
          && (!message.responseType || message.responseType === "chat_commands")
          && message.requestId === slashRequestId) {
          slashRequestId = undefined;
          handlers.onSlashCommands(undefined, activeSessionId, message.message);
        }
        return;
      }
      if (message.type === "chat_page" && message.sessionId === activeSessionId) {
        const request = message.requestId ? openChatRequests.get(message.requestId) : undefined;
        if (message.requestId && (!request
          || request.sessionId !== activeSessionId
          || request.generation !== candidate)) return;
        // A page is meaningful only for the request mode that produced it.
        // Do this check before freshness, reconciliation, or page merging so
        // an earlier response cannot replace a latest page (or vice versa).
        if (request && message.mode !== undefined && message.mode !== request.mode) return;
        // A refreshed page must carry the exact active delivery identity. A
        // missing identity is fail-closed after this point.
        if (lastDeliveryId === undefined
          && message.capabilities.cancelDeliveryId !== undefined
          && state.cancel?.status !== "confirmed") {
          // A working provider may already have a turn before this Chat
          // instance opens. Adopt only the server-provided active identity;
          // never synthesize one from text or page position.
          lastDeliveryId = message.capabilities.cancelDeliveryId;
        }
        const mode = message.mode ?? request?.mode ?? nextPageMode;
        if (mode === "earlier") {
          // Earlier pages must be tied to the reservation made for this
          // cursor. This rejects unscoped/replayed pages and pages that arrive
          // after a newer cursor has already advanced the transcript.
          if (!request || request.mode !== "earlier") return;
          if (request.before !== undefined
            && state.page?.nextBefore !== undefined
            && request.before !== state.page.nextBefore) {
            openChatRequests.delete(message.requestId!);
            return;
          }
        }
        if (mode === "latest") {
          const scopeKey = requestScopeKey(activeSessionId, candidate);
          if (request?.epoch !== undefined
            && request.epoch !== latestRequestEpochByScope.get(scopeKey)) return;
          if (!message.requestId && hasLatestRequestIdentity(candidate)) return;
        }
        const latestScopeKey = JSON.stringify([activeSessionId, candidate]);
        const firstLatestPage = mode === "latest" && !observedLatestPageScopes.has(latestScopeKey);
        const canonicalUserItems = message.items.filter((item) => item.kind === "user");
        if (firstLatestPage) {
          observedLatestPageScopes.add(latestScopeKey);
          // ponytail: keep baseline markers bounded to recent renderer
          // generations; a persistent transcript cursor is required before
          // retaining more than 32 inactive scopes.
          while (observedLatestPageScopes.size > 32) {
            observedLatestPageScopes.delete(observedLatestPageScopes.values().next().value!);
          }
          // Text fallback is safe only with a complete, non-empty baseline
          // whose canonical rows carry trustworthy timestamps. Empty or
          // truncated history must remain identity-only.
          latestBaselineAllowsContentFallback = !message.hasMoreBefore
            && canonicalUserItems.length > 0
            && canonicalUserItems.every((item) => (
              item.timestamp !== undefined && Number.isFinite(Date.parse(item.timestamp))
            ));
        }
        // Exact provider identity is safe even on the first page after a
        // scope reattach: it can settle a delivery while the renderer was
        // away. Content-only fallback remains gated by the authoritative
        // baseline and post-submit timestamp policy in the delivery store.
        const reconciled = mode === "latest" ? deliveryStore.reconcile({
          sessionId: activeSessionId,
          generation: candidate,
          turns: canonicalUserItems.map((item) => ({
              item,
              ...(item.requestId ? { requestId: item.requestId } : {}),
              ...(item.deliveryId ? { deliveryId: item.deliveryId } : {}),
              ...(item.providerMessageId ? { providerMessageId: item.providerMessageId } : {}),
            })),
        }) : [];
        if (reconciled.length) reconcileRecoveryRecords(candidate, reconciled);
        // Reconcile first, then seed the remaining canonical IDs. This order
        // matters when a provider commits while the renderer is detached and
        // the first page after reattach contains both the old baseline and a
        // new content-only row. Seeding first would make that new row look
        // like a replay and strand the optimistic delivery until TTL.
        if (firstLatestPage) {
          deliveryStore.observeCanonicalPage(activeSessionId, candidate, canonicalUserItems
            .map((item) => ({
              item,
              ...(item.requestId ? { requestId: item.requestId } : {}),
              ...(item.deliveryId ? { deliveryId: item.deliveryId } : {}),
              ...(item.providerMessageId ? { providerMessageId: item.providerMessageId } : {}),
            })));
        }
        for (const item of message.items) rememberBoundedId(canonicalItemIds, item.id);
        const currentWithoutOptimistic = state.page
          ? withoutDeliveryRows(state.page, activeSessionId, candidate)
          : undefined;
        const mergedUnbounded = mergeChatPage(currentWithoutOptimistic, message, mode);
        if (request?.expandsWindow || mode === "latest") {
          // Grow from the unique merged result, not raw page length. Replayed
          // rows therefore do not consume the renderer's finite history cap.
          paginationWindow = paginationWindow.expandedTo(mergedUnbounded.items.length);
        }
        const merged = boundPage(mergedUnbounded);
        if (mode === "latest"
          && optimisticPermissionMode
          && message.metadata?.permissionMode === optimisticPermissionMode) {
          optimisticPermissionMode = undefined;
          permissionModeCycle = undefined;
        }
        publishWithRecovery(candidate, {
          sessionId: activeSessionId,
          status: "loaded",
          page: withDeliveryRows(merged, activeSessionId, candidate),
          // A successful cancel refreshes the transcript immediately. Keep
          // the identity-bound outcome visible until a new action or session
          // generation replaces it; otherwise the refresh races the UI state
          // and makes a confirmed result or failure disappear.
          ...(state.cancel ? { cancel: state.cancel } : {}),
          ...(state.cancel?.status === "failed" && state.error
            ? { error: state.error }
            : {}),
        });
        if (message.requestId) openChatRequests.delete(message.requestId);
        nextPageMode = "latest";
        return;
      }
      if (message.type === "chat_commands" && message.sessionId === activeSessionId) {
        slashRequestId = undefined;
        handlers.onSlashCommands(message, activeSessionId);
        return;
      }
      if (message.type === "session_snapshot") {
        const session = message.sessions.find(({ id }) => id === activeSessionId);
        const updatedAt = session?.updatedAt;
        if (session) activeSection = session.section;
        if (latestUpdatedAt && updatedAt && latestUpdatedAt !== updatedAt && nextPageMode !== "earlier") {
          openLatest(connection);
        }
        latestUpdatedAt = updatedAt;
        return;
      }
      if (message.type === "chat_action_result") {
        if (message.action === "cycle_permission_mode") {
          const pending = permissionModeCycle;
          if (!pending
            || message.id !== pending.requestId
            || message.sessionId !== activeSessionId
            || message.generation !== pending.generation) return;
          permissionModeCycle = undefined;
          if (!message.ok) optimisticPermissionMode = undefined;
          publishWithRecovery(candidate, {
            ...state,
            ...(message.ok
              ? { error: undefined }
              : { error: message.error ?? "The permission mode could not be changed." }),
          });
          if (message.ok) openLatest(connection);
          return;
        }
        if (message.action === "cancel") {
          const pending = cancelRequest;
          if (!pending
            || message.id !== pending.requestId
            || message.sessionId !== activeSessionId
            || message.generation !== pending.generation
            || message.deliveryId !== pending.deliveryId) return;
          cancelRequest = undefined;
          const result: ChatCancellationState = {
            ...pending,
            status: message.ok ? "confirmed" : "failed",
          };
          let command: ChatRecoveryCommand | undefined;
          if (message.ok && pending.deliveryId) {
            const delivery = deliveryStore.get(activeSessionId, pending.generation)
              .find((candidate) => candidate.deliveryId === pending.deliveryId);
            if (delivery) {
              const canceled = deliveryStore.cancel({
                sessionId: activeSessionId,
                generation: pending.generation,
                requestId: delivery.requestId,
                deliveryId: delivery.deliveryId,
              });
            if (canceled) {
                pendingSends.delete(delivery.requestId);
                const allowedEmptyRevisions = allowedEmptyRevisionsByDelivery.get(delivery.deliveryId);
                allowedEmptyRevisionsByDelivery.delete(delivery.deliveryId);
                const recovery = recoveryStore.recordCancellation({
                  sessionId: activeSessionId,
                  generation: pending.generation,
                  requestId: delivery.requestId,
                  deliveryId: delivery.deliveryId,
                  draft: delivery.draft,
                  error: "The message was canceled before the provider confirmed it.",
                  cause: "canceled",
                  confirmed: true,
                  currentComposer: currentComposerSnapshot(),
                  allowedEmptyRevisions,
                });
                if (recovery) command = restoreCommand(recovery.restore);
              }
            }
          }
          if (message.ok) {
            lastDeliveryId = undefined;
            publishPageWithDeliveries(candidate);
          }
          publishWithRecovery(candidate, {
            ...state,
            ...(message.ok ? { activeDeliveryId: undefined } : {}),
            cancel: result,
            ...(message.ok
              ? { error: undefined }
              : { error: message.error ?? "The turn could not be cancelled." }),
          }, command);
          if (message.ok) openLatest(connection);
          return;
        }
        const send = pendingSends.get(message.id);
        if (message.action === "send" || send) {
          if (!send
            || message.action !== "send"
            || message.sessionId !== activeSessionId
            || message.generation !== send.generation
            || message.deliveryId !== send.deliveryId) return;
            pendingSends.delete(message.id);
          const deliveryBeforeAck = deliveryStore.get(activeSessionId, candidate)
            .find((delivery) => (
              delivery.requestId === message.id && delivery.deliveryId === send.deliveryId
            ));
          const acknowledgement = deliveryStore.acknowledge({
            sessionId: activeSessionId,
            generation: send.generation,
            requestId: message.id,
            deliveryId: send.deliveryId,
            ok: message.ok,
            ...(message.error ? { error: message.error } : {}),
          });
          if (!acknowledgement) return;
          if (!message.ok && lastDeliveryId === send.deliveryId) lastDeliveryId = undefined;
          const allowedEmptyRevisions = allowedEmptyRevisionsByDelivery.get(send.deliveryId);
          allowedEmptyRevisionsByDelivery.delete(send.deliveryId);
          let command: ChatRecoveryCommand | undefined;
          if (send.recoveryId) {
            recoveryStore.completeRetry({
              sessionId: activeSessionId,
              generation: candidate,
              recoveryId: send.recoveryId,
              requestId: message.id,
              deliveryId: send.deliveryId,
              ok: message.ok,
            });
            if (!message.ok) {
              const recovery = recoveryStore.recordFailure({
                sessionId: activeSessionId,
                generation: candidate,
                requestId: message.id,
                deliveryId: send.deliveryId,
                draft: deliveryBeforeAck?.draft ?? acknowledgement.draft,
                error: message.error ?? "The message could not be delivered.",
                cause: "send-failed",
                currentComposer: currentComposerSnapshot(),
                allowedEmptyRevisions,
              });
              if (recovery) command = restoreCommand(recovery.restore);
            }
          } else if (!message.ok) {
            const recovery = recoveryStore.recordFailure({
              sessionId: activeSessionId,
              generation: candidate,
              requestId: message.id,
              deliveryId: send.deliveryId,
              draft: deliveryBeforeAck?.draft ?? acknowledgement.draft,
              error: message.error ?? "The message could not be delivered.",
              cause: "send-failed",
              currentComposer: currentComposerSnapshot(),
              allowedEmptyRevisions,
            });
            if (recovery) command = restoreCommand(recovery.restore);
          }
          publishPageWithDeliveries(candidate);
          publishWithRecovery(candidate, {
            ...state,
            ...(message.ok
              ? { error: undefined }
              : { error: message.error ?? "The message could not be delivered." }),
          }, command);
          if (message.ok) openLatest(connection);
          return;
        }
        publish({
          ...state,
          error: message.ok ? undefined : message.error,
        });
        if (message.ok) openLatest(connection);
      }
    },
    disconnect(candidate) {
      if (!isCurrent(candidate)) return;
      slashRequestId = undefined;
      cancelRequest = undefined;
      permissionModeCycle = undefined;
      optimisticPermissionMode = undefined;
      // A disconnected transport cannot safely associate a late page with a
      // newly connected renderer. Drop all request identities and freshness
      // epochs; the next connection must register a fresh request.
      openChatRequests.clear();
      latestRequestEpochByScope.clear();
      handlers.onSlashCommands(undefined, activeSessionId);
      publish({ sessionId: activeSessionId, status: "loading" });
    },
    currentState() {
      return state;
    },
  };

  function openLatest(connection: DaemonConnection): void {
    // Page refresh IDs have their own namespace. Action IDs must retain their
    // request ordering because cancellation/send identity is request-scoped.
    const requestId = createRequestId();
    registerLatestRequest(generation, requestId);
    nextPageMode = "latest";
    handlers.onOpenLatest(connection, activeSessionId, requestId);
  }

  function requestScopeKey(sessionId: string, candidate: number): string {
    return JSON.stringify([sessionId, candidate]);
  }

  function pruneOpenChatRequests(): void {
    const cutoff = deliveryClock.now() - CHAT_REQUEST_TTL_MS;
    for (const [requestId, request] of openChatRequests) {
      if (request.createdAt <= cutoff) openChatRequests.delete(requestId);
    }
    // ponytail: this is a short-lived request ledger, not a transcript store;
    // keep it bounded and add a durable request cursor before raising either
    // the count or the no-response retention window.
    while (openChatRequests.size > MAX_OPEN_CHAT_REQUESTS) {
      const oldest = openChatRequests.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      openChatRequests.delete(oldest);
    }
  }

  function registerLatestRequest(candidate: number, requestId: string): void {
    pruneOpenChatRequests();
    const scopeKey = requestScopeKey(activeSessionId, candidate);
    const epoch = (latestRequestEpochByScope.get(scopeKey) ?? 0) + 1;
    latestRequestEpochByScope.set(scopeKey, epoch);
    // Coalesce superseded latest requests. Their responses are stale even if
    // the daemon finishes them after the newer request.
    for (const [id, request] of openChatRequests) {
      if (request.sessionId === activeSessionId
        && request.generation === candidate
        && request.mode === "latest") openChatRequests.delete(id);
    }
    openChatRequests.set(requestId, {
      sessionId: activeSessionId,
      generation: candidate,
      mode: "latest",
      epoch,
      createdAt: deliveryClock.now(),
    });
    pruneOpenChatRequests();
  }

  function registerEarlierRequest(
    candidate: number,
    requestId: string,
    before?: number,
  ): boolean {
    pruneOpenChatRequests();
    if (openChatRequests.has(requestId)) return false;
    // One earlier request may be in flight for a given transcript cursor. A
    // newer cursor cannot be registered until the current page advances; this
    // also makes a late response from an older cursor unambiguously stale.
    const currentCursor = state.page?.nextBefore;
    if (before !== undefined && currentCursor !== undefined && before !== currentCursor) return false;
    if (Array.from(openChatRequests.values()).some((request) => (
      request.sessionId === activeSessionId
      && request.generation === candidate
      && request.mode === "earlier"
      && request.before === before
    ))) return false;
    openChatRequests.set(requestId, {
      sessionId: activeSessionId,
      generation: candidate,
      mode: "earlier",
      epoch: latestRequestEpochByScope.get(requestScopeKey(activeSessionId, candidate)) ?? 0,
      createdAt: deliveryClock.now(),
      ...(before !== undefined ? { before } : {}),
    });
    pruneOpenChatRequests();
    return openChatRequests.has(requestId);
  }

  function hasLatestRequestIdentity(candidate: number): boolean {
    const scopeKey = requestScopeKey(activeSessionId, candidate);
    // Once a scope has issued an identified latest request, an unscoped page
    // can no longer be safely associated with it—even after the request has
    // expired. Accepting it would let a late response erase newer content.
    return latestRequestEpochByScope.has(scopeKey);
  }

  function publishPageWithDeliveries(candidate: number): void {
    if (!isCurrent(candidate) || !state.page || state.sessionId !== activeSessionId) return;
    publishWithRecovery(candidate, {
      ...state,
      page: withDeliveryRows(
        withoutDeliveryRows(state.page, activeSessionId, candidate),
        activeSessionId,
        candidate,
      ),
    });
  }

  function reconcileRecoveryRecords(candidate: number, deliveries: PendingChatDelivery[]): void {
    if (!isCurrent(candidate)) return;
    for (const delivery of deliveries) {
      const pending = pendingSends.get(delivery.requestId);
      if (pending?.recoveryId) {
        // A canonical row is authoritative success for a retry even when the
        // daemon acknowledgement is late. Consume only that retry identity.
        recoveryStore.reconcileCanonical({
          sessionId: activeSessionId,
          generation: candidate,
          requestId: delivery.requestId,
          deliveryId: delivery.deliveryId,
        });
        pendingSends.delete(delivery.requestId);
        allowedEmptyRevisionsByDelivery.delete(delivery.deliveryId);
        continue;
      }
      allowedEmptyRevisionsByDelivery.delete(delivery.deliveryId);
      const recovery = recoveryStore.list(activeSessionId, candidate)
        .find((record) => (
          (record.requestId === delivery.requestId && record.deliveryId === delivery.deliveryId)
          || (record.retryRequestId === delivery.requestId && record.retryDeliveryId === delivery.deliveryId)
        ));
      if (recovery) {
        recoveryStore.reconcileCanonical({
          sessionId: activeSessionId,
          generation: candidate,
          requestId: delivery.requestId,
          deliveryId: delivery.deliveryId,
        });
      }
    }
  }

  function publishWithRecovery(
    candidate: number,
    next: ChatSessionState,
    command?: ChatRecoveryCommand,
  ): void {
    if (!isCurrent(candidate)) return;
    const {
      recovery: _previousRecovery,
      recoveryCommand: previousCommand,
      canCancelForActiveDelivery: _previousCancelCapability,
      activeDeliveryId: _previousActiveDeliveryId,
      clientHistoryLimitReached: _previousHistoryLimitReached,
      permissionModeCycle: _previousPermissionModeCycle,
      optimisticPermissionMode: _previousOptimisticPermissionMode,
      ...base
    } = next;
    const recovery = recoveryStore.list(activeSessionId, candidate);
    const canCancelForActiveDelivery = base.page
      ? canCancelForActiveDeliveryForPage(base.page)
      : false;
    const clientHistoryLimitReached = base.page
      ? isClientHistoryLimitReached(base.page)
      : false;
    publish({
      ...base,
      ...(lastDeliveryId ? { activeDeliveryId: lastDeliveryId } : {}),
      ...(canCancelForActiveDelivery ? { canCancelForActiveDelivery: true } : {}),
      ...(recovery.length ? { recovery } : {}),
      ...(command ?? previousCommand ? { recoveryCommand: command ?? previousCommand } : {}),
      ...(clientHistoryLimitReached ? { clientHistoryLimitReached: true } : {}),
      ...(permissionModeCycle ? { permissionModeCycle } : {}),
      ...(optimisticPermissionMode ? { optimisticPermissionMode } : {}),
    });
  }

  function boundPage(page: ChatPage): ChatPage {
    const bounded = boundChatItems(page.items, paginationWindow);
    if (paginationWindow.visibleLimit >= ChatPaginationWindow.safetyCap && bounded.hiddenCount > 0) {
      // Remember actual truncation separately from a full conversation that
      // happens to contain exactly the renderer safety-cap number of rows.
      droppedHistoryAtSafetyCap = true;
    }
    return { ...page, items: bounded.items };
  }

  function isClientHistoryLimitReached(page: ChatPage): boolean {
    return paginationWindow.visibleLimit >= ChatPaginationWindow.safetyCap
      && (page.hasMoreBefore || droppedHistoryAtSafetyCap);
  }

  function canCancelForActiveDeliveryForPage(page: ChatPage): boolean {
    const activeDeliveryId = lastDeliveryId;
    const advertisedDeliveryId = page.capabilities.cancelDeliveryId;
    const delivery = activeDeliveryId
      ? deliveryStore.get(activeSessionId, generation)
        .find((candidate) => candidate.deliveryId === activeDeliveryId)
      : undefined;
    // A page may describe a provider-owned turn that predates this renderer;
    // in that case there is no local delivery record, so the server's exact
    // capability identity is the proof. Locally tracked uncertain/terminal
    // deliveries must fail closed even if a stale page still says canCancel.
    // Transcript reconciliation replaces the synthetic row, but it does not
    // prove that the provider has stopped working.  A fresh page is allowed
    // to keep an exact, provider-owned cancellation identity live after that
    // reconciliation.  The page's identity check below remains mandatory;
    // this does not make stale pages or locally completed deliveries
    // cancellable by themselves.
    const deliveryIsActionable = delivery === undefined
      || delivery.status === "pending"
      || delivery.status === "acknowledged"
      || delivery.status === "confirmed";
    return deliveryIsActionable
      && page.capabilities.canCancel
      && advertisedDeliveryId !== undefined
      && advertisedDeliveryId === activeDeliveryId;
  }

  function currentComposerSnapshot(): ChatComposerSnapshot {
    return {
      draft: cloneSubmittedDraft(composerDraft),
      revision: composerRevision,
    };
  }

  function rememberAllowedEmptyRevision(deliveryId: string, revision = composerRevision): void {
    allowedEmptyRevisionsByDelivery.set(deliveryId, [revision]);
    // ponytail: bound revision guards to recent deliveries; a persistent
    // delivery cursor is required before retaining more than 512 entries.
    while (allowedEmptyRevisionsByDelivery.size > 512) {
      allowedEmptyRevisionsByDelivery.delete(allowedEmptyRevisionsByDelivery.keys().next().value!);
    }
  }

  function restoreCommand(
    decision: ReturnType<ChatDeliveryRecoveryStore["recordFailure"]> extends infer Result
      ? Result extends { restore: infer Restore } ? Restore : never
      : never,
  ): ChatRecoveryCommand | undefined {
    if (decision.status !== "restored") return undefined;
    return {
      type: "restore",
      id: `restore-${++recoveryCommandSerial}`,
      recoveryId: decision.recoveryId,
      draft: decision.draft,
      expectedComposer: decision.expectedComposer,
      expectedRevision: decision.expectedRevision,
    };
  }

  function clearCommand(decision: ChatDeliveryRetryDecision): ChatRecoveryCommand {
    return {
      type: "clear",
      id: `clear-${++recoveryCommandSerial}`,
      recoveryId: decision.recoveryId,
      draft: decision.draft,
      expectedComposer: decision.expectedComposer,
    };
  }

  function withoutDeliveryRows(page: ChatPage, sessionId: string, candidate: number): ChatPage {
    return {
      ...page,
      items: page.items.filter((item) => (
        !syntheticDeliveryRowIds.has(item.id) || canonicalItemIds.has(item.id)
      )),
    };
  }

  function withDeliveryRows(page: ChatPage, sessionId: string, candidate: number): ChatPage {
    const base = withoutDeliveryRows(page, sessionId, candidate);
    const existingIDs = new Set(base.items.map((item) => item.id));
    const deliveryRows = deliveryStore.optimisticRows(sessionId, candidate)
      .filter((item) => !existingIDs.has(item.id));
    return boundPage({
      ...base,
      items: [...base.items, ...deliveryRows],
    });
  }
}

function defaultRequestId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `chat-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function cloneSubmittedDraft(draft: SubmittedChatDraft): SubmittedChatDraft {
  return {
    text: draft.text,
    images: draft.images.map((image) => ({ ...image })),
  };
}

const MAX_TRACKED_DELIVERY_IDS = 512;
const CHAT_REQUEST_TTL_MS = 60_000;
const MAX_OPEN_CHAT_REQUESTS = 64;
// ponytail: these renderer-only identity sets are replay/cleanup guards. If
// more IDs are needed, add a transcript cursor before raising this cap.
function rememberBoundedId(set: Set<string>, id: string): void {
  if (set.has(id)) return;
  set.add(id);
  while (set.size > MAX_TRACKED_DELIVERY_IDS) {
    const oldest = set.values().next().value as string | undefined;
    if (oldest === undefined) break;
    set.delete(oldest);
  }
}

function defaultDeliveryId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `delivery-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function parseServerMessage(data: string) {
  try {
    const parsed = serverMessageSchema.safeParse(JSON.parse(data));
    return parsed.success ? parsed.data : undefined;
  } catch {
    return undefined;
  }
}
