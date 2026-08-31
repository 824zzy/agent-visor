import { randomUUID } from "node:crypto";
import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  CHAT_IMAGE_ATTACHMENTS_PER_MESSAGE,
  CHAT_IMAGE_MAX_BYTES,
  CHAT_IMAGE_MAX_BASE64_CHARS,
  CHAT_IMAGE_MAX_TOTAL_BYTES,
  chatImageBase64Bytes,
  chatImageBytesMatchMime,
  type ChatImage,
} from "@agent-visor/protocol";

/** The complete identity of one provider delivery and its temporary files. */
export type ChatDeliveryImageScope = {
  sessionId: string;
  generation: number;
  requestId: string;
  deliveryId: string;
};

export type ChatImageLeaseState = "active" | "awaiting_canonical" | "releasing" | "cleanup_pending";

export type ChatImageLease = {
  scope: ChatDeliveryImageScope;
  paths: string[];
  bytes: number;
  state: ChatImageLeaseState;
  expiresAt: number;
};

export type ChatImageLeaseStoreOptions = {
  root: string;
  /** Maximum delivery records retained before safe expiry reclamation. */
  maxRecords?: number;
  /** Maximum decoded bytes retained across all delivery records. */
  maxBytes?: number;
  /** Fallback retention for a provider that never emits canonical evidence. */
  ttlMs?: number;
  now?: () => number;
  writeFile?: (file: string, data: Uint8Array) => Promise<void>;
  removeFile?: (file: string) => Promise<void>;
};

export type MaterializedChatImages = {
  scope: ChatDeliveryImageScope;
  paths: string[];
  bytes: number;
};

// ponytail: these limits coordinate protocol payload caps, provider image
// limits, and this daemon's retained temporary-file budget. Increase only as
// a coordinated client/server retention change; capacity rejection is visible
// and happens before any materialization write. Cleanup retries are unref'd so
// a provider/file-system failure cannot keep the daemon alive, but the lease
// remains accounted until every owned path is removed.
export const MAX_CHAT_IMAGE_LEASE_RECORDS = 256;
export const MAX_CHAT_IMAGE_LEASE_BYTES = 256 * 1024 * 1024;
export const CHAT_IMAGE_LEASE_TTL_MS = 5 * 60 * 1_000;
export const CHAT_IMAGE_LEASE_CLEANUP_INITIAL_RETRY_MS = 1_000;
export const CHAT_IMAGE_LEASE_CLEANUP_MAX_RETRY_MS = 30_000;

type LeaseRecord = ChatImageLease & {
  key: string;
  timer?: ReturnType<typeof setTimeout>;
  cleanupTimer?: ReturnType<typeof setTimeout>;
  cleanupAttempts: number;
  cleanupNextRetryAt?: number;
  cleanupPromise?: Promise<boolean>;
  releasing: boolean;
  materializationDone: Promise<void>;
  resolveMaterialization: () => void;
};

/**
 * Owns temporary image paths by exact request/delivery identity.
 *
 * This is deliberately a small lifecycle module: callers reserve and write a
 * complete delivery atomically through `materialize`, mark provider work as
 * awaiting canonical evidence, and release the same scope on every terminal
 * path. No directory-wide sweep is needed for normal success or failure.
 */
export class ChatImageLeaseStore {
  private readonly records = new Map<string, LeaseRecord>();
  private readonly now: () => number;
  private readonly maxRecords: number;
  private readonly maxBytes: number;
  private readonly ttlMs: number;
  private readonly write: (file: string, data: Uint8Array) => Promise<void>;
  private readonly remove: (file: string) => Promise<void>;
  private totalBytes = 0;

  constructor(private readonly options: ChatImageLeaseStoreOptions) {
    this.now = options.now ?? Date.now;
    this.maxRecords = options.maxRecords ?? MAX_CHAT_IMAGE_LEASE_RECORDS;
    this.maxBytes = options.maxBytes ?? MAX_CHAT_IMAGE_LEASE_BYTES;
    this.ttlMs = options.ttlMs ?? CHAT_IMAGE_LEASE_TTL_MS;
    this.write = options.writeFile ?? (async (file, data) => {
      await writeFile(file, data, { mode: 0o600, flag: "wx" });
    });
    this.remove = options.removeFile ?? (async (file) => {
      await rm(file, { force: true });
    });
    if (!path.isAbsolute(options.root)) throw new Error("Image lease root must be absolute.");
    if (!Number.isSafeInteger(this.maxRecords) || this.maxRecords < 1) {
      throw new Error("Image lease record cap must be a positive integer.");
    }
    if (!Number.isSafeInteger(this.maxBytes) || this.maxBytes < 1) {
      throw new Error("Image lease byte cap must be a positive integer.");
    }
    if (!Number.isSafeInteger(this.ttlMs) || this.ttlMs < 1) {
      throw new Error("Image lease TTL must be a positive integer.");
    }
  }

  /**
   * Validate and materialize all images only after the complete lease is
   * admitted. A failed write removes only paths owned by this scope.
   */
  async materialize(
    scope: ChatDeliveryImageScope,
    images: readonly ChatImage[],
  ): Promise<MaterializedChatImages> {
    validateScope(scope);
    const decoded = decodeImages(images);
    const key = chatDeliveryImageScopeKey(scope);
    if (this.records.has(key)) throw new Error("This delivery already owns an image lease.");
    await this.reclaimExpired(this.now());
    if (this.records.size >= this.maxRecords) {
      throw new Error("Temporary image capacity is full; try again after the current delivery settles.");
    }
    if (this.totalBytes > this.maxBytes - decoded.bytes) {
      throw new Error("Temporary image byte capacity is full; try again after the current delivery settles.");
    }
    if (!decoded.images.length) return { scope: structuredClone(scope), paths: [], bytes: 0 };

    // The admission record exists before the first write. This prevents a
    // second concurrent operation from exceeding the aggregate budget while
    // this operation is between its first and last file write.
    const expiresAt = this.now() + this.ttlMs;
    let resolveMaterialization!: () => void;
    const materializationDone = new Promise<void>((resolve) => { resolveMaterialization = resolve; });
    const record: LeaseRecord = {
      key,
      scope: structuredClone(scope),
      paths: [],
      bytes: decoded.bytes,
      state: "active",
      expiresAt,
      cleanupAttempts: 0,
      releasing: false,
      materializationDone,
      resolveMaterialization,
    };
    this.records.set(key, record);
    this.totalBytes += record.bytes;
    try {
      await mkdir(this.options.root, { recursive: true, mode: 0o700 });
      ensureLeaseOwned(record);
      for (const image of decoded.images) {
        ensureLeaseOwned(record);
        const extension = image.mimeType.slice("image/".length).replace("jpeg", "jpg");
        const file = path.join(this.options.root, `${randomUUID()}.${extension}`);
        // Track the path before awaiting the write. A concurrent release must
        // be able to clean a file whose writer resolves after that release.
        record.paths.push(file);
        await this.write(file, image.data);
        ensureLeaseOwned(record);
      }
      ensureLeaseOwned(record);
    } catch (error) {
      // The write has either settled or was rejected at this point. The
      // internal path deliberately skips the materialization wait; external
      // release/forget calls still wait for this operation before cleanup.
      await this.releaseKey(key, false);
      throw error;
    } finally {
      record.resolveMaterialization();
    }
    this.scheduleExpiry(record);
    return { scope: structuredClone(scope), paths: [...record.paths], bytes: record.bytes };
  }

  /** Keep files available while provider canonical evidence is pending. */
  markAwaitingCanonical(scope: ChatDeliveryImageScope): boolean {
    const record = this.records.get(chatDeliveryImageScopeKey(scope));
    if (!record || record.releasing) return false;
    record.state = "awaiting_canonical";
    return true;
  }

  has(scope: ChatDeliveryImageScope): boolean {
    return this.records.has(chatDeliveryImageScopeKey(scope));
  }

  get(scope: ChatDeliveryImageScope): ChatImageLease | undefined {
    const record = this.records.get(chatDeliveryImageScopeKey(scope));
    return record ? cloneLease(record) : undefined;
  }

  list(): ChatImageLease[] {
    return [...this.records.values()].map(cloneLease);
  }

  /** Release exactly one request/delivery's files. */
  async release(scope: ChatDeliveryImageScope): Promise<boolean> {
    return this.releaseKey(chatDeliveryImageScopeKey(scope));
  }

  /** Release every generation of one exact session/delivery pair. */
  async releaseDelivery(sessionId: string, deliveryId: string): Promise<void> {
    await this.releaseWhere((record) => record.scope.sessionId === sessionId
      && record.scope.deliveryId === deliveryId);
  }

  /** Release all files owned by a session, including all generations. */
  async forgetSession(sessionId: string): Promise<void> {
    await this.releaseWhere((record) => record.scope.sessionId === sessionId);
  }

  /** Release only generations older than the authoritative replacement. */
  async replaceGeneration(sessionId: string, generation: number): Promise<void> {
    await this.releaseWhere((record) => record.scope.sessionId === sessionId
      && record.scope.generation < generation);
  }

  /** Explicit fake-clock/test hook and bounded fallback cleanup. */
  async expire(now = this.now()): Promise<void> {
    await this.reclaimExpired(now);
  }

  async close(): Promise<void> {
    await this.releaseWhere(() => true);
  }

  get recordCount(): number {
    return this.records.size;
  }

  get retainedBytes(): number {
    return this.totalBytes;
  }

  private scheduleExpiry(record: LeaseRecord): void {
    const delay = Math.max(1, record.expiresAt - this.now());
    record.timer = setTimeout(() => {
      void this.releaseKey(record.key);
    }, delay);
    // The daemon owns cleanup, but a lease timer must never keep a test or a
    // clean shutdown alive. The explicit `expire` hook remains deterministic.
    record.timer.unref?.();
  }

  private scheduleCleanupRetry(record: LeaseRecord): void {
    if (record.cleanupTimer) clearTimeout(record.cleanupTimer);
    const delay = Math.min(
      CHAT_IMAGE_LEASE_CLEANUP_MAX_RETRY_MS,
      CHAT_IMAGE_LEASE_CLEANUP_INITIAL_RETRY_MS
        * (2 ** Math.min(record.cleanupAttempts - 1, 5)),
    );
    record.cleanupNextRetryAt = this.now() + delay;
    record.cleanupTimer = setTimeout(() => {
      record.cleanupTimer = undefined;
      void this.cleanupRecord(record);
    }, delay);
    record.cleanupTimer.unref?.();
  }

  private async reclaimExpired(now: number): Promise<void> {
    const expired = [...this.records.values()]
      .filter((record) => record.expiresAt <= now)
      .map((record) => record.key);
    for (const key of expired) await this.releaseKey(key);
    const pending = [...this.records.values()]
      .filter((record) => record.state === "cleanup_pending"
        && record.cleanupNextRetryAt !== undefined
        && record.cleanupNextRetryAt <= now);
    for (const record of pending) await this.cleanupRecord(record);
  }

  private async releaseWhere(predicate: (record: LeaseRecord) => boolean): Promise<void> {
    const keys = [...this.records.values()]
      .filter(predicate)
      .map((record) => record.key);
    for (const key of keys) await this.releaseKey(key);
  }

  private async releaseKey(key: string, waitForMaterialization = true): Promise<boolean> {
    const record = this.records.get(key);
    if (!record) return false;
    if (!record.releasing) {
      record.releasing = true;
      record.state = "releasing";
      if (record.timer) clearTimeout(record.timer);
    }
    if (waitForMaterialization) await record.materializationDone;
    if (this.records.get(key) !== record) return true;
    return this.cleanupRecord(record);
  }

  private cleanupRecord(record: LeaseRecord): Promise<boolean> {
    if (record.cleanupPromise) return record.cleanupPromise;
    record.cleanupPromise = this.performCleanup(record).finally(() => {
      record.cleanupPromise = undefined;
    });
    return record.cleanupPromise;
  }

  private async performCleanup(record: LeaseRecord): Promise<boolean> {
    record.state = "cleanup_pending";
    const root = path.resolve(this.options.root);
    const remaining: string[] = [];
    for (const candidate of record.paths) {
      const resolved = path.resolve(candidate);
      if (resolved === root || !resolved.startsWith(`${root}${path.sep}`)
        || [...this.records.values()].some((other) => other !== record
          && other.paths.includes(candidate))) {
        remaining.push(candidate);
        continue;
      }
      try {
        await this.remove(resolved);
      } catch {
        // Keep failed paths and all decoded bytes accounted. A retry timer is
        // unref'd, and explicit `expire`/`close` calls can force another try.
        remaining.push(candidate);
      }
    }
    record.paths = remaining;
    if (remaining.length > 0) {
      record.cleanupAttempts += 1;
      this.scheduleCleanupRetry(record);
      return false;
    }
    this.records.delete(record.key);
    this.totalBytes -= record.bytes;
    if (record.cleanupTimer) clearTimeout(record.cleanupTimer);
    record.cleanupNextRetryAt = undefined;
    return true;
  }
}

export function chatDeliveryImageScopeKey(scope: ChatDeliveryImageScope): string {
  validateScope(scope);
  return JSON.stringify([scope.sessionId, scope.generation, scope.requestId, scope.deliveryId]);
}

function validateScope(scope: ChatDeliveryImageScope): void {
  if (!scope || typeof scope.sessionId !== "string" || !scope.sessionId
    || !Number.isSafeInteger(scope.generation) || scope.generation < 0
    || typeof scope.requestId !== "string" || !scope.requestId
    || typeof scope.deliveryId !== "string" || !scope.deliveryId) {
    throw new Error("A complete session, generation, request, and delivery identity is required.");
  }
}

function ensureLeaseOwned(record: LeaseRecord): void {
  if (record.releasing) throw new Error("Image materialization was released before completion.");
}

function decodeImages(images: readonly ChatImage[]): {
  images: Array<{ mimeType: ChatImage["mimeType"]; data: Uint8Array }>;
  bytes: number;
} {
  if (images.length > CHAT_IMAGE_ATTACHMENTS_PER_MESSAGE) {
    throw new Error(`A message can contain at most ${CHAT_IMAGE_ATTACHMENTS_PER_MESSAGE} images.`);
  }
  const decoded: Array<{ mimeType: ChatImage["mimeType"]; data: Uint8Array }> = [];
  let bytes = 0;
  for (const image of images) {
    if (!image.data || image.data.length > CHAT_IMAGE_MAX_BASE64_CHARS
      || image.data.length % 4 !== 0
      || typeof image.byteLength !== "number"
      || !Number.isSafeInteger(image.byteLength)
      || image.byteLength < 1) {
      throw new Error("An image has invalid content.");
    }
    const data = chatImageBase64Bytes(image.data);
    if (!data || data.byteLength > CHAT_IMAGE_MAX_BYTES
      || image.byteLength !== data.byteLength
      || !chatImageBytesMatchMime(image.mimeType, data)
      || bytes > CHAT_IMAGE_MAX_TOTAL_BYTES - data.byteLength) {
      throw new Error("The image payload exceeds the supported content limit.");
    }
    bytes += data.byteLength;
    decoded.push({ mimeType: image.mimeType, data });
  }
  return { images: decoded, bytes };
}

function cloneLease(record: LeaseRecord): ChatImageLease {
  return {
    scope: structuredClone(record.scope),
    paths: [...record.paths],
    bytes: record.bytes,
    state: record.state,
    expiresAt: record.expiresAt,
  };
}
