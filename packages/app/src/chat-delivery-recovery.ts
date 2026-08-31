import type { ChatImage } from "@agent-visor/protocol";
import {
  submittedChatDraftByteSize,
  type DeliveryClock,
  type SubmittedChatDraft,
} from "./chat-delivery";
import {
  CHAT_DELIVERY_MAX_RECORDS_PER_SCOPE,
  CHAT_DELIVERY_MAX_SCOPES,
  CHAT_DELIVERY_MAX_RECOVERY_ERROR_BYTES,
  CHAT_DELIVERY_MAX_RETRY_IDENTITIES,
  CHAT_DELIVERY_MAX_SNAPSHOT_BYTES,
} from "./chat-delivery-policy";

export type ChatComposerSnapshot = {
  draft: SubmittedChatDraft;
  /** Renderer-local revision used to distinguish the expected post-submit clear from a later user clear. */
  revision: number;
};

export type ChatDeliveryRecoveryCause =
  | "send-failed"
  | "delivery-expired"
  | "delivery-uncertain"
  | "canceled";
export type ChatDeliveryRecoveryStatus =
  | "failed"
  | "canceled"
  | "retrying"
  | "awaiting-canonical"
  | "uncertain";

export type ChatDeliveryRecoveryRecord = {
  id: string;
  sessionId: string;
  generation: number;
  requestId: string;
  deliveryId: string;
  draft: SubmittedChatDraft;
  cause: ChatDeliveryRecoveryCause;
  status: ChatDeliveryRecoveryStatus;
  error: string;
  createdAt: number;
  updatedAt: number;
  /** Present while this source has an accepted replacement retry. */
  retryRequestId?: string;
  retryDeliveryId?: string;
};

export type ChatDeliveryRecoveryInput = {
  sessionId: string;
  generation: number;
  requestId: string;
  deliveryId: string;
  draft: SubmittedChatDraft;
  error: string;
  cause: "send-failed" | "delivery-expired" | "delivery-uncertain";
  currentComposer: ChatComposerSnapshot;
  /** Revisions at which an empty composer is the expected post-submit state. */
  allowedEmptyRevisions?: readonly number[];
};

export type ChatDeliveryCancellationInput = Omit<ChatDeliveryRecoveryInput, "cause"> & {
  cause: "canceled";
  confirmed: boolean;
};

type ChatDeliveryRecordInput = Omit<ChatDeliveryRecoveryInput, "cause"> & {
  cause: ChatDeliveryRecoveryCause;
};

export type ChatDeliveryRestoreDecision =
  | {
    status: "restored";
    recoveryId: string;
    draft: SubmittedChatDraft;
    expectedComposer: ChatComposerSnapshot;
    expectedRevision: number;
  }
  | {
    status: "preserved";
    recoveryId: string;
    reason: "newer-composer-content" | "already-restored";
    expectedComposer: ChatComposerSnapshot;
    expectedRevision: number;
  };

export type ChatDeliveryRecoveryResult = {
  record: ChatDeliveryRecoveryRecord;
  restore: ChatDeliveryRestoreDecision;
};

export type ChatDeliveryRetryInput = {
  sessionId: string;
  generation: number;
  recoveryId: string;
  currentComposer: ChatComposerSnapshot;
  /** Required before retrying a delivery whose provider may already have written it. */
  riskConfirmed?: boolean;
};

export type ChatDeliveryRetryDecision = {
  recoveryId: string;
  source: ChatDeliveryRecoveryRecord;
  requestId: string;
  deliveryId: string;
  draft: SubmittedChatDraft;
  /** True only on the first accepted retry. Callers must not send again when false. */
  isNew: boolean;
  /** Clear the composer only when it still contains this exact recovered snapshot. */
  clearComposer: boolean;
  expectedComposer: SubmittedChatDraft;
};

export type ChatDeliveryRetryCompletion = {
  sessionId: string;
  generation: number;
  recoveryId: string;
  requestId: string;
  deliveryId: string;
  ok: boolean;
};

export type ChatDeliveryRecoveryStoreOptions = {
  clock?: DeliveryClock;
  createRequestId?: () => string;
  createDeliveryId?: () => string;
  maxRecordsPerScope?: number;
  maxSnapshotBytesPerScope?: number;
  maxScopes?: number;
};

export type ChatDeliveryRecoveryStore = {
  /** Make this session/generation the only scope that accepts live operations. */
  activate(sessionId: string, generation: number): void;
  recordFailure(input: ChatDeliveryRecoveryInput): ChatDeliveryRecoveryResult | undefined;
  recordCancellation(input: ChatDeliveryCancellationInput): ChatDeliveryRecoveryResult | undefined;
  retry(input: ChatDeliveryRetryInput): ChatDeliveryRetryDecision | undefined;
  completeRetry(input: ChatDeliveryRetryCompletion): boolean;
  /** Consume a recovery when an exact original/replacement canonical row arrives. */
  reconcileCanonical(input: {
    sessionId: string;
    generation: number;
    requestId: string;
    deliveryId: string;
  }): boolean;
  /** Return a failed/canceled record to actionable state when replacement send cannot begin. */
  rollbackRetry(input: Omit<ChatDeliveryRetryCompletion, "ok">): boolean;
  /** Mark an acknowledged retry uncertain when its canonical deadline expires. */
  markRetryUncertain(input: {
    sessionId: string;
    generation: number;
    requestId: string;
    deliveryId: string;
    error: string;
  }): boolean;
  dismiss(input: { sessionId: string; generation: number; recoveryId: string }): ChatDeliveryRecoveryRecord | undefined;
  list(sessionId: string, generation: number): ChatDeliveryRecoveryRecord[];
};

type RecoveryRecord = ChatDeliveryRecoveryRecord & {
  restored: boolean;
  /** The one renderer revision produced by the submit clear. */
  expectedEmptyRevision?: number;
  retry?: {
    requestId: string;
    deliveryId: string;
  };
};

type RecoveryScope = Map<string, RecoveryRecord> & {
  snapshotBytes?: number;
  reservedRequestIds?: Set<string>;
  reservedDeliveryIds?: Set<string>;
  reservedIdentityOrder?: string[];
};

const emptyDraft = (): SubmittedChatDraft => ({ text: "", images: [] });
const defaultClock: DeliveryClock = { now: () => Date.now() };

function scopeKey(sessionId: string, generation: number): string {
  return JSON.stringify([sessionId, generation]);
}

function cloneImage(image: ChatImage): ChatImage {
  return { ...image };
}

function cloneDraft(draft: SubmittedChatDraft): SubmittedChatDraft {
  return {
    text: draft.text,
    images: draft.images.map(cloneImage),
  };
}

function cloneComposer(snapshot: ChatComposerSnapshot): ChatComposerSnapshot {
  return {
    draft: cloneDraft(snapshot.draft),
    revision: snapshot.revision,
  };
}

function cloneRecord(record: RecoveryRecord): ChatDeliveryRecoveryRecord {
  const cloned: ChatDeliveryRecoveryRecord = {
    id: record.id,
    sessionId: record.sessionId,
    generation: record.generation,
    requestId: record.requestId,
    deliveryId: record.deliveryId,
    draft: cloneDraft(record.draft),
    cause: record.cause,
    status: record.status,
    error: record.error,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
  };
  if (record.retry) {
    cloned.retryRequestId = record.retry.requestId;
    cloned.retryDeliveryId = record.retry.deliveryId;
  }
  return cloned;
}

function utf8ByteLength(value: string): number {
  if (typeof TextEncoder === "function") return new TextEncoder().encode(value).byteLength;
  return unescape(encodeURIComponent(value)).length;
}

function boundedError(value: string): string {
  if (utf8ByteLength(value) <= CHAT_DELIVERY_MAX_RECOVERY_ERROR_BYTES) return value;
  let result = value;
  while (result.length > 0 && utf8ByteLength(result) > CHAT_DELIVERY_MAX_RECOVERY_ERROR_BYTES) {
    result = result.slice(0, -1);
  }
  return result;
}

function recoveryRecordByteSize(record: Pick<ChatDeliveryRecoveryRecord, "id" | "sessionId" | "requestId" | "deliveryId" | "error" | "draft">): number {
  return submittedChatDraftByteSize(record.draft)
    + utf8ByteLength(record.id)
    + utf8ByteLength(record.sessionId)
    + utf8ByteLength(record.requestId)
    + utf8ByteLength(record.deliveryId)
    + utf8ByteLength(record.error);
}

function imagesEqual(left: ChatImage[], right: ChatImage[]): boolean {
  if (left.length !== right.length) return false;
  return left.every((image, index) => {
    const other = right[index];
    return image.name === other?.name
      && image.mimeType === other.mimeType
      && image.data === other.data
      && image.byteLength === other.byteLength;
  });
}

export function chatSubmittedDraftsEqual(
  left: SubmittedChatDraft,
  right: SubmittedChatDraft,
): boolean {
  return left.text === right.text && imagesEqual(left.images, right.images);
}

function isEmptyDraft(draft: SubmittedChatDraft): boolean {
  return draft.text.length === 0 && draft.images.length === 0;
}

function recoveryID(input: Pick<ChatDeliveryRecoveryInput, "sessionId" | "generation" | "deliveryId">): string {
  return `${input.sessionId}:${input.generation}:${input.deliveryId}`;
}

export function createChatDeliveryRecoveryStore(
  options: ChatDeliveryRecoveryStoreOptions = {},
): ChatDeliveryRecoveryStore {
  const clock = options.clock ?? defaultClock;
  const createRequestId = options.createRequestId ?? defaultRequestId;
  const createDeliveryId = options.createDeliveryId ?? defaultDeliveryId;
  const maxRecordsPerScope = Number.isInteger(options.maxRecordsPerScope)
    && (options.maxRecordsPerScope ?? 0) > 0
    ? options.maxRecordsPerScope!
    : CHAT_DELIVERY_MAX_RECORDS_PER_SCOPE;
  const maxSnapshotBytesPerScope = Number.isInteger(options.maxSnapshotBytesPerScope)
    && (options.maxSnapshotBytesPerScope ?? 0) > 0
    ? options.maxSnapshotBytesPerScope!
    : CHAT_DELIVERY_MAX_SNAPSHOT_BYTES;
  const maxScopes = Number.isInteger(options.maxScopes)
    && (options.maxScopes ?? 0) > 0 ? options.maxScopes! : CHAT_DELIVERY_MAX_SCOPES;
  const scopes = new Map<string, RecoveryScope>();
  let activeScopeKey: string | undefined;

  function scopeFor(sessionId: string, generation: number): RecoveryScope | undefined {
    const key = scopeKey(sessionId, generation);
    let scope = scopes.get(key);
    if (!scope) {
      scope = new Map() as RecoveryScope;
      scope.snapshotBytes = 0;
      scope.reservedRequestIds = new Set();
      scope.reservedDeliveryIds = new Set();
      scope.reservedIdentityOrder = [];
      scopes.set(key, scope);
      if (!reclaimInactiveScopes()) {
        scopes.delete(key);
        return undefined;
      }
    }
    return scope;
  }

  function reclaimInactiveScopes(): boolean {
    // Inactive scopes are renderer-only state. Reclaim empty/terminal scopes
    // first; if every inactive scope is live, retain them until a bounded
    // terminal record becomes available rather than issuing stale composer
    // commands from an inactive session.
    // ponytail: if more than this many sessions must remain recoverable, add a
    // persistent identity-scoped store before raising maxScopes.
    if (scopes.size <= maxScopes) return true;
    for (const [key, scope] of scopes) {
      if (key === activeScopeKey) continue;
      if (scope.size === 0) {
        scopes.delete(key);
        if (scopes.size <= maxScopes) return true;
      }
    }
    // ponytail: report admission failure rather than silently dropping a
    // failed/canceled snapshot that still contains user content.
    return false;
  }

  function isActive(sessionId: string, generation: number): boolean {
    return activeScopeKey === scopeKey(sessionId, generation);
  }

  function migrateSessionRecords(sessionId: string, generation: number, target: RecoveryScope): void {
    // Recovery belongs to the session, while generation protects provider
    // callbacks. When a renderer returns to the same session, move actionable
    // records into its new generation so text/images remain visible. A
    // canonical terminal record is never migrated or exposed as a retry.
    for (const [key, source] of scopes) {
      if (key === scopeKey(sessionId, generation)) continue;
      const sourceSession = [...source.values()][0]?.sessionId;
      if (sourceSession !== sessionId) continue;
      for (const record of [...source.values()]) {
        if (target.size >= maxRecordsPerScope) break;
        const nextId = recoveryID({ sessionId, generation, deliveryId: record.deliveryId });
        if (target.has(nextId)
          || target.reservedRequestIds!.has(record.requestId)
          || target.reservedDeliveryIds!.has(record.deliveryId)) continue;
        const oldBytes = recoveryRecordByteSize(record);
        const migrated = {
          ...record,
          id: nextId,
          generation,
          draft: cloneDraft(record.draft),
          ...(record.retry ? { retry: { ...record.retry } } : {}),
        };
        const nextBytes = recoveryRecordByteSize(migrated);
        if ((target.snapshotBytes ?? 0) + nextBytes > maxSnapshotBytesPerScope) break;
        source.delete(record.id);
        source.snapshotBytes = (source.snapshotBytes ?? 0) - oldBytes;
        target.set(nextId, migrated);
        target.snapshotBytes = (target.snapshotBytes ?? 0) + nextBytes;
        reserveIdentity(target, migrated.requestId, migrated.deliveryId);
        if (migrated.retry) reserveIdentity(target, migrated.retry.requestId, migrated.retry.deliveryId);
      }
      if (source.size === 0) scopes.delete(key);
    }
  }

  function reserveIdentity(scope: RecoveryScope, requestId: string, deliveryId: string): boolean {
    const requests = scope.reservedRequestIds!;
    const deliveries = scope.reservedDeliveryIds!;
    if (requests.has(requestId) || deliveries.has(deliveryId)) return false;
    requests.add(requestId);
    deliveries.add(deliveryId);
    scope.reservedIdentityOrder!.push(`${requestId}\u0000${deliveryId}`);
    // Keep reservations bounded so a reconnect cannot retain unbounded IDs,
    // while active records still keep their own identities in the map.
    while (scope.reservedIdentityOrder!.length > CHAT_DELIVERY_MAX_RETRY_IDENTITIES) {
      const oldest = scope.reservedIdentityOrder!.shift();
      if (oldest === undefined) break;
      const separator = oldest.indexOf("\u0000");
      if (separator >= 0) {
        requests.delete(oldest.slice(0, separator));
        deliveries.delete(oldest.slice(separator + 1));
      }
    }
    return true;
  }

  function releaseIdentity(scope: RecoveryScope, requestId: string, deliveryId: string): void {
    scope.reservedRequestIds!.delete(requestId);
    scope.reservedDeliveryIds!.delete(deliveryId);
    scope.reservedIdentityOrder = scope.reservedIdentityOrder!.filter((pair) => {
      const separator = pair.indexOf("\u0000");
      return separator < 0
        || pair.slice(0, separator) !== requestId
        || pair.slice(separator + 1) !== deliveryId;
    });
  }

  function allocateRetryIdentity(
    scope: RecoveryScope,
    create: () => string,
    original: string,
    suffix: string,
  ): string | undefined {
    for (let attempt = 0; attempt < CHAT_DELIVERY_MAX_RETRY_IDENTITIES; attempt += 1) {
      const generated = create();
      const candidate = generated === original || scope.reservedRequestIds!.has(generated)
        || scope.reservedDeliveryIds!.has(generated)
        ? `${generated}-${suffix}-${attempt + 1}`
        : generated;
      if (!scope.reservedRequestIds!.has(candidate) && !scope.reservedDeliveryIds!.has(candidate)) {
        return candidate;
      }
    }
    return undefined;
  }

  function restoreDecision(
    record: RecoveryRecord,
    currentComposer: ChatComposerSnapshot,
    allowedEmptyRevisions: readonly number[] | undefined,
  ): ChatDeliveryRestoreDecision {
    const expectedComposer = cloneComposer(currentComposer);
    if (record.restored) {
      return {
        status: "preserved",
        recoveryId: record.id,
        reason: "already-restored",
        expectedComposer,
        expectedRevision: expectedComposer.revision,
      };
    }
    const expectedEmpty = isEmptyDraft(currentComposer.draft)
      && record.expectedEmptyRevision !== undefined
      && currentComposer.revision === record.expectedEmptyRevision
      && (allowedEmptyRevisions === undefined || allowedEmptyRevisions.includes(currentComposer.revision));
    if (expectedEmpty) {
      record.restored = true;
      return {
        status: "restored",
        recoveryId: record.id,
        draft: cloneDraft(record.draft),
        expectedComposer,
        expectedRevision: expectedComposer.revision,
      };
    }
    return {
      status: "preserved",
      recoveryId: record.id,
      reason: "newer-composer-content",
      expectedComposer,
      expectedRevision: expectedComposer.revision,
    };
  }

  function record(
    input: ChatDeliveryRecordInput,
  ): ChatDeliveryRecoveryResult | undefined {
    if (!isActive(input.sessionId, input.generation)) return undefined;
    const scope = scopeFor(input.sessionId, input.generation);
    if (!scope) return undefined;
    const id = recoveryID(input);
    const existing = scope.get(id);
    if (existing) {
      if (existing.requestId !== input.requestId || existing.deliveryId !== input.deliveryId) return undefined;
      return {
        record: cloneRecord(existing),
        restore: restoreDecision(existing, input.currentComposer, input.allowedEmptyRevisions),
      };
    }
    // A dismissed identity may remain in the bounded reservation window; do
    // not allow either side of a request/delivery pair to be rebound.
    const conflicts = [...scope.values()].some((candidate) => (
      candidate.requestId === input.requestId || candidate.deliveryId === input.deliveryId
    ));
    if (conflicts || scope.reservedRequestIds!.has(input.requestId)
      || scope.reservedDeliveryIds!.has(input.deliveryId)) return undefined;
    const now = clock.now();
    const error = boundedError(input.error);
    const snapshotBytes = recoveryRecordByteSize({
      id,
      sessionId: input.sessionId,
      requestId: input.requestId,
      deliveryId: input.deliveryId,
      draft: input.draft,
      error,
    });
    // Actionable records and their full image snapshots are never silently
    // evicted. Admission fails atomically when the bounded budget is full.
    if (scope.size >= maxRecordsPerScope
      || (scope.snapshotBytes ?? 0) + snapshotBytes > maxSnapshotBytesPerScope) return undefined;
    const next: RecoveryRecord = {
      id,
      sessionId: input.sessionId,
      generation: input.generation,
      requestId: input.requestId,
      deliveryId: input.deliveryId,
      draft: cloneDraft(input.draft),
      cause: input.cause,
      status: input.cause === "canceled"
        ? "canceled"
        : input.cause === "delivery-uncertain" ? "uncertain" : "failed",
      error,
      createdAt: now,
      updatedAt: now,
      restored: false,
      ...(input.currentComposer.draft.text.length === 0 && input.currentComposer.draft.images.length === 0
        ? { expectedEmptyRevision: input.allowedEmptyRevisions?.[0] ?? input.currentComposer.revision }
        : {}),
    };
    if (!reserveIdentity(scope, next.requestId, next.deliveryId)) return undefined;
    scope.set(id, next);
    scope.snapshotBytes = (scope.snapshotBytes ?? 0) + snapshotBytes;
    return {
      record: cloneRecord(next),
      restore: restoreDecision(next, input.currentComposer, input.allowedEmptyRevisions),
    };
  }

  return {
    activate(sessionId, generation) {
      activeScopeKey = scopeKey(sessionId, generation);
      const target = scopeFor(sessionId, generation);
      if (target) migrateSessionRecords(sessionId, generation, target);
    },

    recordFailure(input) {
      return record(input);
    },

    recordCancellation(input) {
      if (!input.confirmed) return undefined;
      return record(input);
    },

    retry(input) {
      if (!isActive(input.sessionId, input.generation)) return undefined;
      const scope = scopes.get(scopeKey(input.sessionId, input.generation));
      const record = scope?.get(input.recoveryId);
      if (!record
        || (!(["failed", "canceled", "retrying"].includes(record.status))
          && !(record.status === "uncertain" && input.riskConfirmed))) return undefined;
      const now = clock.now();
      const isNew = record.retry === undefined;
      if (!record.retry) {
        if (!scope) return undefined;
        let retry: { requestId: string; deliveryId: string } | undefined;
        for (let attempt = 0; attempt < CHAT_DELIVERY_MAX_RETRY_IDENTITIES; attempt += 1) {
          const requestId = allocateRetryIdentity(scope, createRequestId, record.requestId, "retry-request");
          const deliveryId = allocateRetryIdentity(scope, createDeliveryId, record.deliveryId, "retry-delivery");
          if (requestId && deliveryId && requestId !== deliveryId
            && reserveIdentity(scope, requestId, deliveryId)) {
            retry = { requestId, deliveryId };
            break;
          }
        }
        if (!retry) return undefined;
        record.retry = retry;
        record.status = "retrying";
        record.updatedAt = now;
      }
      return {
        recoveryId: record.id,
        source: cloneRecord(record),
        requestId: record.retry.requestId,
        deliveryId: record.retry.deliveryId,
        draft: cloneDraft(record.draft),
        isNew,
        clearComposer: chatSubmittedDraftsEqual(input.currentComposer.draft, record.draft),
        expectedComposer: cloneDraft(input.currentComposer.draft),
      };
    },

    completeRetry(input) {
      if (!isActive(input.sessionId, input.generation)) return false;
      const scope = scopes.get(scopeKey(input.sessionId, input.generation));
      if (!scope) return false;
      const record = scope.get(input.recoveryId);
      if (!record || record.status !== "retrying" || !record.retry
        || record.retry.requestId !== input.requestId
        || record.retry.deliveryId !== input.deliveryId) return false;
      if (input.ok) {
        // A successful daemon action acknowledges provider acceptance only.
        // Keep the source lineage until the transcript supplies canonical proof.
        record.status = "awaiting-canonical";
        record.updatedAt = clock.now();
        return true;
      }
      if (!input.ok) {
        // The replacement delivery becomes a new failed record immediately
        // after this transition. Release only this exact retry pair so the
        // replacement recovery can reserve it again; unrelated recent IDs
        // remain protected by the bounded reservation history.
        releaseIdentity(scope, record.retry.requestId, record.retry.deliveryId);
      }
      scope.delete(input.recoveryId);
      scope.snapshotBytes = (scope.snapshotBytes ?? 0) - recoveryRecordByteSize(record);
      return true;
    },

    reconcileCanonical(input) {
      if (!isActive(input.sessionId, input.generation)) return false;
      const scope = scopes.get(scopeKey(input.sessionId, input.generation));
      if (!scope) return false;
      const record = [...scope.values()].find((candidate) => (
        (candidate.requestId === input.requestId && candidate.deliveryId === input.deliveryId)
        || (candidate.retry?.requestId === input.requestId
          && candidate.retry.deliveryId === input.deliveryId)
      ));
      if (!record) return false;
      scope.delete(record.id);
      scope.snapshotBytes = (scope.snapshotBytes ?? 0) - recoveryRecordByteSize(record);
      return true;
    },

    rollbackRetry(input) {
      if (!isActive(input.sessionId, input.generation)) return false;
      const scope = scopes.get(scopeKey(input.sessionId, input.generation));
      if (!scope) return false;
      const record = scope.get(input.recoveryId);
      if (!record || record.status !== "retrying" || !record.retry
        || record.retry.requestId !== input.requestId
        || record.retry.deliveryId !== input.deliveryId) return false;
      record.status = record.cause === "canceled" ? "canceled" : "failed";
      record.retry = undefined;
      record.updatedAt = clock.now();
      return true;
    },

    markRetryUncertain(input) {
      if (!isActive(input.sessionId, input.generation)) return false;
      const scope = scopes.get(scopeKey(input.sessionId, input.generation));
      if (!scope) return false;
      const record = [...scope.values()].find((candidate) => (
        candidate.retry?.requestId === input.requestId
        && candidate.retry.deliveryId === input.deliveryId
      ));
      if (!record || (record.status !== "retrying" && record.status !== "awaiting-canonical")) return false;
      record.status = "uncertain";
      record.error = boundedError(input.error);
      record.updatedAt = clock.now();
      return true;
    },

    dismiss(input) {
      if (!isActive(input.sessionId, input.generation)) return undefined;
      const scope = scopes.get(scopeKey(input.sessionId, input.generation));
      if (!scope) return undefined;
      const record = scope.get(input.recoveryId);
      if (!record || record.status === "retrying") return undefined;
      scope.delete(input.recoveryId);
      scope.snapshotBytes = (scope.snapshotBytes ?? 0) - recoveryRecordByteSize(record);
      return cloneRecord(record);
    },

    list(sessionId, generation) {
      if (!isActive(sessionId, generation)) return [];
      const scope = scopes.get(scopeKey(sessionId, generation));
      return scope ? [...scope.values()].map(cloneRecord) : [];
    },
  };
}

function defaultRequestId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `retry-request-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function defaultDeliveryId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `retry-delivery-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}
