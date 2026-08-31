import type { ChatImage, ChatItem } from "@agent-visor/protocol";
import {
  CHAT_DELIVERY_MAX_RECORDS_PER_SCOPE,
  CHAT_DELIVERY_MAX_SCOPES,
  CHAT_DELIVERY_MAX_SEEN_CANONICAL_IDS,
  CHAT_DELIVERY_MAX_SNAPSHOT_BYTES,
} from "./chat-delivery-policy";

export {
  CHAT_DELIVERY_MAX_RECORDS_PER_SCOPE,
  CHAT_DELIVERY_MAX_SCOPES,
  CHAT_DELIVERY_MAX_SEEN_CANONICAL_IDS,
  CHAT_DELIVERY_MAX_SNAPSHOT_BYTES,
} from "./chat-delivery-policy";

/**
 * The maximum time that a submitted message can remain unconfirmed.
 *
 * // ponytail: if the provider confirmation SLA changes, update this value,
 * // the expired-message copy, and the fake-clock tests together.
 */
export const CHAT_DELIVERY_TTL_MS = 30_000;

/**
 * Swift's PendingEchoStore reconciles against the ten most recent user turns.
 * The window is intentionally bounded until the protocol provides a cursor.
 *
 * // ponytail: if transcript paging changes this window, add a cursor/sequence
 * // contract before increasing the amount of transcript held here.
 */
export const CHAT_DELIVERY_FALLBACK_CANONICAL_LIMIT = 10;

/**
 * Bound canonical IDs retained for page-reload de-duplication.
 *
 * // ponytail: if a session can expose more canonical IDs than this bound,
 * // add transcript sequence/cursor persistence before raising this value.
 */
export const CHAT_DELIVERY_EXPIRED_ERROR =
  "The provider did not confirm this message before the delivery window expired.";
export const CHAT_DELIVERY_UNCERTAIN_ERROR =
  "The provider acknowledged this message but did not publish it in the transcript before the delivery window expired.";

export type ChatUserItem = Extract<ChatItem, { kind: "user" }>;

export type SubmittedChatDraft = {
  text: string;
  images: ChatImage[];
};

export type PendingChatDeliveryStatus =
  | "pending"
  | "acknowledged"
  | "confirmed"
  | "failed"
  | "canceled"
  | "uncertain";

export type DeliveryClock = {
  now(): number;
};

/** A user turn as it appears in a provider transcript/page. */
export type CanonicalChatUserTurn = {
  item: ChatUserItem;
  requestId?: string;
  deliveryId?: string;
  providerMessageId?: string;
};

export type PendingChatDelivery = {
  requestId: string;
  deliveryId: string;
  sessionId: string;
  generation: number;
  draft: SubmittedChatDraft;
  optimisticRowId: string;
  optimisticRow: ChatUserItem;
  status: PendingChatDeliveryStatus;
  createdAt: number;
  updatedAt: number;
  error?: string;
  providerMessageId?: string;
};

export type BeginChatDeliveryInput = {
  sessionId: string;
  generation: number;
  draft: SubmittedChatDraft;
  requestId?: string;
  deliveryId?: string;
  optimisticRowId?: string;
  /** Content fallback is safe only after an authoritative latest-page baseline. */
  allowContentFallback?: boolean;
  /** Atomically replace this terminal source when retrying at the scope cap. */
  replace?: { requestId: string; deliveryId: string };
};

export type ChatDeliveryAcknowledgement = {
  sessionId: string;
  generation: number;
  requestId: string;
  deliveryId?: string;
  providerMessageId?: string;
  ok: boolean;
  error?: string;
};

export type ChatDeliveryIdentity = {
  sessionId: string;
  generation: number;
  requestId: string;
  deliveryId?: string;
};

export type ChatDeliveryExpiryScope = {
  sessionId: string;
  generation: number;
  now?: number;
};

export type CanonicalChatReconciliation = {
  sessionId: string;
  generation: number;
  turns: CanonicalChatUserTurn[];
};

export type PendingChatDeliveryStoreOptions = {
  clock?: DeliveryClock;
  createId?: () => string;
  ttlMs?: number;
  maxDeliveriesPerScope?: number;
  maxSnapshotBytesPerScope?: number;
  maxScopes?: number;
};

export type PendingChatDeliveryStore = {
  /** Make this session/generation the only scope that accepts live callbacks. */
  activate(sessionId: string, generation: number): void;
  begin(input: BeginChatDeliveryInput): PendingChatDelivery | undefined;
  acknowledge(input: ChatDeliveryAcknowledgement): PendingChatDelivery | undefined;
  reconcile(input: CanonicalChatReconciliation): PendingChatDelivery[];
  cancel(input: ChatDeliveryIdentity): PendingChatDelivery | undefined;
  /** Remove a failed/canceled record and its synthetic row without touching other deliveries. */
  dismiss(input: ChatDeliveryIdentity): PendingChatDelivery | undefined;
  /**
   * Expire pending records in one exact session/generation scope. Callers own
   * scheduling so tests can use a fake clock. An explicit scope prevents a
   * timer for one session from producing recovery work in another session.
   */
  expire(scope: ChatDeliveryExpiryScope): PendingChatDelivery[];
  get(sessionId: string, generation: number): PendingChatDelivery[];
  optimisticRows(sessionId: string, generation: number): ChatUserItem[];
  /** Baseline a page without matching it to a later optimistic delivery. */
  observeCanonicalPage(
    sessionId: string,
    generation: number,
    turns: CanonicalChatUserTurn[],
  ): void;
};

type DeliveryRecord = PendingChatDelivery & {
  /** Set after a canonical provider row consumes this optimistic row. */
  canonicalItemId?: string;
  /** The source remains recoverable while a retry is in flight. */
  supersededBy?: { requestId: string; deliveryId: string };
  allowContentFallback?: boolean;
};

type DeliveryScope = {
  sessionId: string;
  generation: number;
  records: DeliveryRecord[];
  byRequestId: Map<string, DeliveryRecord>;
  byDeliveryId: Map<string, DeliveryRecord>;
  superseded: Map<string, DeliveryRecord>;
  seenCanonicalIds: Set<string>;
  seenCanonicalOrder: string[];
  snapshotBytes: number;
};

const defaultClock: DeliveryClock = { now: () => Date.now() };

function scopeKey(sessionId: string, generation: number): string {
  return JSON.stringify([sessionId, generation]);
}

function validIdentity(value: string | undefined): value is string {
  return value !== undefined && value.length > 0;
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

/** Count the exact UTF-8 memory retained by a submitted draft. */
export function submittedChatDraftByteSize(draft: SubmittedChatDraft): number {
  const encoder = typeof TextEncoder === "function" ? new TextEncoder() : undefined;
  const size = (value: string): number => encoder
    ? encoder.encode(value).byteLength
    : unescape(encodeURIComponent(value)).length;
  return size(draft.text) + draft.images.reduce((total, image) => (
    total + size(image.name) + size(image.mimeType) + size(image.data ?? "") + 16
  ), 0);
}

function cloneUserItem(item: ChatUserItem): ChatUserItem {
  return {
    ...item,
    images: item.images.map(cloneImage),
  };
}

function cloneRecord(record: DeliveryRecord): PendingChatDelivery {
  const result: PendingChatDelivery = {
    requestId: record.requestId,
    deliveryId: record.deliveryId,
    sessionId: record.sessionId,
    generation: record.generation,
    draft: cloneDraft(record.draft),
    optimisticRowId: record.optimisticRowId,
    optimisticRow: cloneUserItem(record.optimisticRow),
    status: record.status,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
  };
  if (record.error !== undefined) result.error = record.error;
  if (record.providerMessageId !== undefined) result.providerMessageId = record.providerMessageId;
  return result;
}

function normalizeForReconcile(raw: string): string {
  // This mirrors PendingEchoLogic.swift: remove consecutive leading image
  // placeholders before the final trim. Image-only turns stay empty and do
  // not match plain-text optimistic rows.
  let remaining = raw.trimStart();
  while (true) {
    const match = /^\[Image(?:\s+#\d+)?\]/.exec(remaining);
    if (!match) break;
    remaining = remaining.slice(match[0].length).trimStart();
  }
  return remaining.trim();
}

function hasCanonicalIdentity(turn: CanonicalChatUserTurn): boolean {
  return validIdentity(turn.requestId)
    || validIdentity(turn.deliveryId)
    || validIdentity(turn.providerMessageId);
}

function matchesCanonicalIdentity(
  record: DeliveryRecord,
  turn: CanonicalChatUserTurn,
): boolean {
  // An identified provider row must match every identity field it provides.
  // This prevents a mismatched request ID from falling through to text.
  if (validIdentity(turn.requestId) && record.requestId !== turn.requestId) return false;
  if (validIdentity(turn.deliveryId) && record.deliveryId !== turn.deliveryId) return false;
  if (validIdentity(turn.providerMessageId)
    && record.providerMessageId !== turn.providerMessageId) return false;
  return hasCanonicalIdentity(turn);
}

function defaultCreateId(): string {
  const cryptoApi = globalThis.crypto;
  if (cryptoApi && typeof cryptoApi.randomUUID === "function") return cryptoApi.randomUUID();
  return `chat-delivery-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

export function createPendingChatDeliveryStore(
  options: PendingChatDeliveryStoreOptions = {},
): PendingChatDeliveryStore {
  const clock = options.clock ?? defaultClock;
  const createId = options.createId ?? defaultCreateId;
  const ttlMs = Number.isFinite(options.ttlMs) && (options.ttlMs ?? 0) > 0
    ? options.ttlMs!
    : CHAT_DELIVERY_TTL_MS;
  const maxRecords = Number.isInteger(options.maxDeliveriesPerScope)
    && (options.maxDeliveriesPerScope ?? 0) > 0
    ? options.maxDeliveriesPerScope!
    : CHAT_DELIVERY_MAX_RECORDS_PER_SCOPE;
  const maxSnapshotBytes = Number.isInteger(options.maxSnapshotBytesPerScope)
    && (options.maxSnapshotBytesPerScope ?? 0) > 0
    ? options.maxSnapshotBytesPerScope!
    : CHAT_DELIVERY_MAX_SNAPSHOT_BYTES;
  const maxScopes = Number.isInteger(options.maxScopes)
    && (options.maxScopes ?? 0) > 0
    ? options.maxScopes!
    : CHAT_DELIVERY_MAX_SCOPES;

  const scopes = new Map<string, DeliveryScope>();
  let activeScopeKey: string | undefined;

  const scopeFor = (sessionId: string, generation: number): DeliveryScope | undefined => {
    const key = scopeKey(sessionId, generation);
    const existing = scopes.get(key);
    if (existing) return existing;
    const created: DeliveryScope = {
      sessionId,
      generation,
      records: [],
      byRequestId: new Map(),
      byDeliveryId: new Map(),
      superseded: new Map(),
      seenCanonicalIds: new Set(),
      seenCanonicalOrder: [],
      snapshotBytes: 0,
    };
    scopes.set(key, created);
    if (!reclaimInactiveScopes()) {
      scopes.delete(key);
      return undefined;
    }
    return created;
  };

  const reclaimInactiveScopes = (): boolean => {
    if (scopes.size <= maxScopes) return true;
    // Actionable records contain user content. Only completely empty scopes
    // are safe to reclaim without a visible recovery decision.
    for (const [key, scope] of scopes) {
      if (key === activeScopeKey) continue;
      if (scope.records.length === 0 && scope.superseded.size === 0) {
        scopes.delete(key);
        if (scopes.size <= maxScopes) return true;
      }
    }
    // ponytail: capacity exhaustion is returned to the caller; add durable
    // session storage before increasing maxScopes or evicting user content.
    return false;
  };

  const isActive = (sessionId: string, generation: number): boolean => (
    activeScopeKey === scopeKey(sessionId, generation)
  );

  const migrateActionableSessionRecords = (
    sessionId: string,
    generation: number,
    target: DeliveryScope,
  ): void => {
    // A renderer generation is a transport freshness boundary, not a reason
    // to strand user-visible pending failure state. Move only records which
    // still need renderer action; completed canonical rows remain in their
    // old scope and cannot leak into the new transcript.
    for (const [key, source] of scopes) {
      if (key === scopeKey(sessionId, generation) || source.sessionId !== sessionId) continue;
      const movable = source.records.filter((record) => (
        record.status === "pending"
        || record.status === "acknowledged"
        || record.status === "failed"
        || record.status === "canceled"
        || record.status === "uncertain"
        || (record.status === "confirmed" && record.canonicalItemId === undefined)
      ));
      for (const record of movable) {
        if (target.byRequestId.has(record.requestId) || target.byDeliveryId.has(record.deliveryId)) continue;
        source.records = source.records.filter((candidate) => candidate !== record);
        source.byRequestId.delete(record.requestId);
        source.byDeliveryId.delete(record.deliveryId);
        source.snapshotBytes -= submittedChatDraftByteSize(record.draft);
        record.generation = generation;
        target.records.push(record);
        target.byRequestId.set(record.requestId, record);
        target.byDeliveryId.set(record.deliveryId, record);
        target.snapshotBytes += submittedChatDraftByteSize(record.draft);
      }
      // A retry keeps its original failed delivery in this lineage map until
      // the replacement is canonical. Preserve that source card across a
      // reconnect as well, otherwise a late original/retry row can strand the
      // only recovery snapshot.
      for (const [deliveryId, record] of source.superseded) {
        if (target.superseded.has(deliveryId)) continue;
        source.superseded.delete(deliveryId);
        source.snapshotBytes -= submittedChatDraftByteSize(record.draft);
        record.generation = generation;
        target.superseded.set(deliveryId, record);
        target.snapshotBytes += submittedChatDraftByteSize(record.draft);
      }
      if (source.records.length === 0 && source.superseded.size === 0) scopes.delete(key);
    }
  };

  const rememberCanonicalId = (scope: DeliveryScope, canonicalId: string): void => {
    if (scope.seenCanonicalIds.has(canonicalId)) return;
    scope.seenCanonicalIds.add(canonicalId);
    scope.seenCanonicalOrder.push(canonicalId);
    while (scope.seenCanonicalOrder.length > CHAT_DELIVERY_MAX_SEEN_CANONICAL_IDS) {
      const oldest = scope.seenCanonicalOrder.shift();
      if (oldest !== undefined) scope.seenCanonicalIds.delete(oldest);
    }
  };

  const reclaimTerminalRecord = (scope: DeliveryScope): boolean => {
    const index = scope.records.findIndex((record) => (
      record.status === "confirmed" && record.canonicalItemId !== undefined
    ));
    if (index < 0) return false;
    const [removed] = scope.records.splice(index, 1);
    if (!removed) return false;
    scope.byRequestId.delete(removed.requestId);
    scope.byDeliveryId.delete(removed.deliveryId);
    scope.snapshotBytes -= submittedChatDraftByteSize(removed.draft);
    return true;
  };

  const retainedRecordCount = (scope: DeliveryScope): number => (
    scope.records.length + scope.superseded.size
  );

  const findByIdentity = (
    scope: DeliveryScope,
    requestId: string,
    deliveryId: string | undefined,
  ): DeliveryRecord | undefined => {
    const direct = scope.byRequestId.get(requestId);
    if (!direct) return undefined;
    if (deliveryId !== undefined && scope.byDeliveryId.get(deliveryId) !== direct) return undefined;
    return direct;
  };

  const findAnyByIdentity = (
    scope: DeliveryScope,
    requestId: string,
    deliveryId: string | undefined,
  ): DeliveryRecord | undefined => {
    const current = findByIdentity(scope, requestId, deliveryId);
    if (current) return current;
    return [...scope.superseded.values()].find((candidate) => (
      candidate.requestId === requestId
      && (deliveryId === undefined || candidate.deliveryId === deliveryId)
    ));
  };

  const draftMatchesCanonical = (
    draft: SubmittedChatDraft,
    turn: CanonicalChatUserTurn,
  ): boolean => {
    if (normalizeForReconcile(draft.text) !== normalizeForReconcile(turn.item.text)) return false;
    // Older provider pages omit image metadata. Preserve the established
    // text-only fallback in that case; when a page does carry images, compare
    // the complete immutable attachment identity.
    if (turn.item.images.length === 0) return true;
    if (draft.images.length !== turn.item.images.length) return false;
    return draft.images.every((image, index) => {
      const other = turn.item.images[index];
      return other !== undefined
        && image.name === other.name
        && image.mimeType === other.mimeType
        && image.byteLength === other.byteLength
        && image.data === other.data;
    });
  };

  const canonicalTimestampIsAfterSubmit = (
    record: DeliveryRecord,
    turn: CanonicalChatUserTurn,
  ): boolean => {
    // Content fallback is opt-in. The controller sets this only after an
    // authoritative latest-page baseline; absent or incomplete evidence must
    // stay identity-only.
    if (record.allowContentFallback !== true) return false;
    const timestamp = turn.item.timestamp;
    if (timestamp === undefined) return false;
    const parsed = Date.parse(timestamp);
    return Number.isFinite(parsed) && parsed > record.createdAt;
  };

  const confirm = (
    record: DeliveryRecord,
    now: number,
    providerMessageId?: string,
  ): boolean => {
    if (record.status === "canceled" || record.status === "confirmed") return false;
    record.status = "confirmed";
    record.updatedAt = now;
    record.error = undefined;
    if (providerMessageId !== undefined) record.providerMessageId = providerMessageId;
    return true;
  };

  return {
    activate(sessionId, generation) {
      activeScopeKey = scopeKey(sessionId, generation);
      const target = scopeFor(sessionId, generation);
      if (target) migrateActionableSessionRecords(sessionId, generation, target);
    },

    begin(input) {
      if (!isActive(input.sessionId, input.generation)) return undefined;
      const scope = scopeFor(input.sessionId, input.generation);
      if (!scope) return undefined;
      const requestId = input.requestId ?? createId();
      const deliveryId = input.deliveryId ?? requestId;
      if (!validIdentity(requestId) || !validIdentity(deliveryId)) return undefined;

      const existing = findByIdentity(scope, requestId, input.deliveryId);
      if (existing) return cloneRecord(existing);
      // Pair identity is reserved symmetrically. Exact replay is idempotent,
      // while either-direction reuse is rejected before any mutation.
      if (scope.byRequestId.has(requestId) || scope.byDeliveryId.has(deliveryId)) return undefined;
      if ([...scope.superseded.values()].some((record) => (
        record.requestId === requestId || record.deliveryId === deliveryId
      ))) return undefined;

      const text = input.draft.text;
      if (text.trim().length === 0 && input.draft.images.length === 0) return undefined;
      const snapshotBytes = submittedChatDraftByteSize(input.draft);
      let replaced: { record: DeliveryRecord; index: number } | undefined;
      if (input.replace) {
        const index = scope.records.findIndex((candidate) => (
          candidate.requestId === input.replace?.requestId
          && candidate.deliveryId === input.replace?.deliveryId
          && (candidate.status === "failed" || candidate.status === "canceled")
        ));
        if (index < 0) return undefined;
        const source = scope.records[index];
        if (!source) return undefined;
        replaced = { record: source, index };
        scope.records.splice(index, 1);
        scope.byRequestId.delete(source.requestId);
        scope.byDeliveryId.delete(source.deliveryId);
        source.supersededBy = { requestId, deliveryId };
        scope.superseded.set(source.deliveryId, source);
      }
      if (retainedRecordCount(scope) >= maxRecords
        || scope.snapshotBytes + snapshotBytes > maxSnapshotBytes) {
        while (retainedRecordCount(scope) >= maxRecords
          || scope.snapshotBytes + snapshotBytes > maxSnapshotBytes) {
          if (!reclaimTerminalRecord(scope)) break;
        }
        if (retainedRecordCount(scope) >= maxRecords
          || scope.snapshotBytes + snapshotBytes > maxSnapshotBytes) {
          if (replaced) {
            scope.records.splice(replaced.index, 0, replaced.record);
            scope.byRequestId.set(replaced.record.requestId, replaced.record);
            scope.byDeliveryId.set(replaced.record.deliveryId, replaced.record);
            scope.superseded.delete(replaced.record.deliveryId);
          }
          return undefined;
        }
      }

      const now = clock.now();
      const snapshot = cloneDraft(input.draft);
      const optimisticRowId = input.optimisticRowId ?? `pending-${deliveryId}`;
      const record: DeliveryRecord = {
        requestId,
        deliveryId,
        sessionId: input.sessionId,
        generation: input.generation,
        draft: snapshot,
        optimisticRowId,
        optimisticRow: {
          id: optimisticRowId,
          kind: "user",
          text: snapshot.text,
          images: snapshot.images.map(cloneImage),
          requestId,
          deliveryId,
          timestamp: new Date(now).toISOString(),
        },
        status: "pending",
        createdAt: now,
        updatedAt: now,
        allowContentFallback: input.allowContentFallback ?? false,
      };
      scope.records.push(record);
      scope.byRequestId.set(requestId, record);
      scope.byDeliveryId.set(deliveryId, record);
      scope.snapshotBytes += snapshotBytes;
      return cloneRecord(record);
    },

    acknowledge(input) {
      if (!isActive(input.sessionId, input.generation)) return undefined;
      const scope = scopeFor(input.sessionId, input.generation);
      if (!scope) return undefined;
      const record = findByIdentity(scope, input.requestId, input.deliveryId);
      if (!record) return undefined;
      // A canonical transcript row can arrive before the daemon ack. Treat a
      // later successful ack as an idempotent confirmation so callers can
      // finish their request lifecycle without a special race branch. Failed
      // and canceled records stay terminal and reject late acknowledgements.
      if (record.status === "confirmed") {
        if (input.ok && input.providerMessageId !== undefined) {
          record.providerMessageId = input.providerMessageId;
        }
        return input.ok ? cloneRecord(record) : undefined;
      }
      if (record.status !== "pending") return undefined;
      const now = clock.now();
      if (input.ok) {
        // A daemon acknowledgement proves the request was accepted, not that
        // the provider transcript has committed the user turn. Keep this
        // explicit state until reconcile() observes canonical evidence.
        record.status = "acknowledged";
        record.updatedAt = now;
        record.error = undefined;
        if (input.providerMessageId !== undefined) record.providerMessageId = input.providerMessageId;
      } else {
        record.status = "failed";
        record.updatedAt = now;
        record.error = input.error ?? "The provider rejected this message.";
      }
      if (input.providerMessageId !== undefined) record.providerMessageId = input.providerMessageId;
      return cloneRecord(record);
    },

    reconcile(input) {
      if (!isActive(input.sessionId, input.generation)) return [];
      const scope = scopeFor(input.sessionId, input.generation);
      if (!scope) return [];
      const recentTurns = input.turns
        .filter((turn) => turn.item.kind === "user")
        .slice(-CHAT_DELIVERY_FALLBACK_CANONICAL_LIMIT);
      const changed: PendingChatDelivery[] = [];
      for (const turn of recentTurns) {
        const canonicalId = turn.item.id;
        const identified = hasCanonicalIdentity(turn);
        // A previously observed content-only row is a page replay. An
        // identified row may be revisited because a late provider identity can
        // repair an earlier page that omitted it.
        if (scope.seenCanonicalIds.has(canonicalId) && !identified) continue;

        if (identified) {
          const record = scope.records.find((candidate) => (
            candidate.status !== "canceled" && matchesCanonicalIdentity(candidate, turn)
          ));
          const superseded = [...scope.superseded.values()].find((candidate) => (
            candidate.status !== "canceled" && matchesCanonicalIdentity(candidate, turn)
          ));
          const matched = record ?? superseded;
          if (!matched) continue;
          const didChange = confirm(matched, clock.now(), turn.providerMessageId);
          matched.canonicalItemId = canonicalId;
          rememberCanonicalId(scope, canonicalId);
          const source = superseded ?? [...scope.superseded.values()].find((candidate) => (
            candidate.supersededBy?.deliveryId === matched.deliveryId
          ));
          if (source) {
            scope.superseded.delete(source.deliveryId);
            scope.snapshotBytes -= submittedChatDraftByteSize(source.draft);
          }
          if (didChange) changed.push(cloneRecord(matched));
          continue;
        }

        const normalized = normalizeForReconcile(turn.item.text);
        const candidates = normalized.length === 0 && turn.item.images.length === 0
          ? undefined
          : scope.records.filter((candidate) => (
            (candidate.status === "pending"
              || candidate.status === "acknowledged"
              || candidate.status === "failed"
              || candidate.status === "uncertain"
              || (candidate.status === "confirmed" && candidate.canonicalItemId === undefined))
            && canonicalTimestampIsAfterSubmit(candidate, turn)
            && draftMatchesCanonical(candidate.draft, turn)
          ));
        const matchingRecords = candidates ?? [];
        const matchingLineage = [...scope.superseded.values()].filter((candidate) => (
          canonicalTimestampIsAfterSubmit(candidate, turn)
          && (candidate.status === "pending"
            || candidate.status === "acknowledged"
            || candidate.status === "failed"
            || candidate.status === "uncertain"
            || (candidate.status === "confirmed" && candidate.canonicalItemId === undefined))
          &&
          draftMatchesCanonical(candidate.draft, turn)
        ));
        // Content-only fallback is fail-closed when more than one current
        // delivery (or any current + superseded lineage pair) matches. The
        // insertion order is not evidence about which provider row landed;
        // an explicit provider identity is required in that case.
        if (matchingRecords.length > 1
          || matchingLineage.length > 1
          || (matchingRecords.length > 0 && matchingLineage.length > 0)) {
          rememberCanonicalId(scope, canonicalId);
          continue;
        }
        const record = matchingRecords.length === 1
          ? matchingRecords[0]
          : matchingLineage.length === 1 ? matchingLineage[0] : undefined;
        rememberCanonicalId(scope, canonicalId);
        if (!record) continue;
        const didChange = confirm(record, clock.now());
        record.canonicalItemId = canonicalId;
        if (matchingLineage.length === 1) {
          scope.superseded.delete(record.deliveryId);
          scope.snapshotBytes -= submittedChatDraftByteSize(record.draft);
        }
        if (didChange) changed.push(cloneRecord(record));
      }
      return changed;
    },

    cancel(input) {
      if (!isActive(input.sessionId, input.generation)) return undefined;
      const scope = scopeFor(input.sessionId, input.generation);
      if (!scope) return undefined;
      const record = findByIdentity(scope, input.requestId, input.deliveryId);
      if (!record || (record.status !== "pending"
        && record.status !== "acknowledged"
        && !(record.status === "confirmed" && record.canonicalItemId === undefined))) return undefined;
      record.status = "canceled";
      record.updatedAt = clock.now();
      record.error = undefined;
      return cloneRecord(record);
    },

    dismiss(input) {
      if (!isActive(input.sessionId, input.generation)) return undefined;
      const scope = scopeFor(input.sessionId, input.generation);
      if (!scope) return undefined;
      const record = findAnyByIdentity(scope, input.requestId, input.deliveryId);
      if (!record || (record.status !== "failed" && record.status !== "canceled")) return undefined;
      if (scope.superseded.get(record.deliveryId) === record) {
        scope.superseded.delete(record.deliveryId);
        scope.snapshotBytes -= submittedChatDraftByteSize(record.draft);
        return cloneRecord(record);
      }
      scope.records = scope.records.filter((candidate) => candidate !== record);
      scope.byRequestId.delete(record.requestId);
      scope.byDeliveryId.delete(record.deliveryId);
      scope.snapshotBytes -= submittedChatDraftByteSize(record.draft);
      return cloneRecord(record);
    },

    expire(expiryScope) {
      const scope = scopes.get(scopeKey(expiryScope.sessionId, expiryScope.generation));
      if (!scope) return [];
      const now = expiryScope.now ?? clock.now();
      const expired: PendingChatDelivery[] = [];
      for (const record of scope.records) {
        if ((record.status !== "pending" && record.status !== "acknowledged")
          || now - record.createdAt < ttlMs) continue;
        const wasAcknowledged = record.status === "acknowledged";
        record.status = wasAcknowledged ? "uncertain" : "failed";
        record.updatedAt = now;
        record.error = wasAcknowledged ? CHAT_DELIVERY_UNCERTAIN_ERROR : CHAT_DELIVERY_EXPIRED_ERROR;
        expired.push(cloneRecord(record));
      }
      return expired;
    },

    get(sessionId, generation) {
      return (scopes.get(scopeKey(sessionId, generation))?.records ?? []).map(cloneRecord);
    },

    optimisticRows(sessionId, generation) {
      return (scopes.get(scopeKey(sessionId, generation))?.records ?? [])
        .filter((record) => (
          record.status === "pending"
          || record.status === "acknowledged"
          || record.status === "failed"
          || record.status === "uncertain"
          || (record.status === "confirmed" && record.canonicalItemId === undefined)
        ))
        .map((record) => cloneUserItem(record.optimisticRow));
    },

    observeCanonicalPage(sessionId, generation, turns) {
      if (!isActive(sessionId, generation)) return;
      const scope = scopeFor(sessionId, generation);
      if (!scope) return;
      for (const turn of turns.filter((candidate) => candidate.item.kind === "user")) {
        rememberCanonicalId(scope, turn.item.id);
      }
    },
  };
}
