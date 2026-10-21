import {
  chmodSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";

const SCHEMA_VERSION = 1 as const;
const DEFAULT_PAGE_SIZE = 100;
const MAX_PAGE_SIZE = 1_000;
const MAX_ID_LENGTH = 512;
const MAX_TEXT_LENGTH = 4_096;
const MAX_TITLE_LENGTH = 512;
const MAX_PROFILE_LENGTH = 128;
const HOSTS = new Set(["Ghostty", "iTerm2", "Terminal"] as const);

export type RetainedHistoryHost = "Ghostty" | "iTerm2" | "Terminal";

export type RetainedHistoryObservation = {
  id: string;
  provider: "claude_code";
  title: string;
  subtitle: string;
  sourceProfile?: string;
  project: string;
  owner: string;
  host: RetainedHistoryHost;
  cwd: string;
  transcriptPath?: string;
  updatedAt: string;
  observedAt: string;
};

export type RetainedHistoryRecord = RetainedHistoryObservation & {
  schemaVersion: typeof SCHEMA_VERSION;
  closedAt?: string;
};

export type RetainedHistoryPage = {
  records: RetainedHistoryRecord[];
  total: number;
  nextCursor?: string;
};

type PersistedHistory = {
  schemaVersion: typeof SCHEMA_VERSION;
  records: RetainedHistoryRecord[];
};

type RetainedHistoryStoreOptions = {
  path: string;
  now?: () => Date;
};

/**
 * Durable identity-only history for conversations observed by Agent Visor.
 *
 * This store deliberately knows nothing about provider controls or launch
 * commands. A record can be searchable while carrying no authority to start
 * a provider. Launch validation belongs to the provider-specific resume
 * adapters introduced by later tickets.
 */
export class RetainedHistoryStore {
  private readonly recordsById = new Map<string, RetainedHistoryRecord>();
  private readonly now: () => Date;

  constructor(private readonly options: RetainedHistoryStoreOptions) {
    this.now = options.now ?? (() => new Date());
    this.load();
  }

  observe(observation: RetainedHistoryObservation): void {
    this.observeMany([observation]);
  }

  observeMany(observations: readonly RetainedHistoryObservation[]): void {
    let changed = false;
    for (const observation of observations) {
      const normalized = normalizeObservation(observation);
      if (!normalized) continue;
      const previous = this.recordsById.get(normalized.id);
      const next: RetainedHistoryRecord = {
        ...(previous ?? {}),
        ...normalized,
        schemaVersion: SCHEMA_VERSION,
        // A fresh verified observation means the conversation is open again.
        closedAt: undefined,
      };
      if (!previous || !sameRecord(previous, next)) {
        this.recordsById.set(normalized.id, next);
        changed = true;
      }
    }
    if (changed) this.persist();
  }

  /** Mark only previously observed conversations absent from a successful discovery as closed. */
  closeMissing(activeConversationIds: ReadonlySet<string>): void {
    const closedAt = this.now().toISOString();
    let changed = false;
    for (const [id, record] of this.recordsById) {
      if (record.closedAt || activeConversationIds.has(id)) continue;
      this.recordsById.set(id, { ...record, closedAt });
      changed = true;
    }
    if (changed) this.persist();
  }

  /**
   * Return retained rows for History. Open rows are included only while the
   * repository has no successful provider inventory to establish liveness.
   */
  page(
    query?: string,
    cursor?: string,
    limit = DEFAULT_PAGE_SIZE,
    includeOpen = false,
  ): RetainedHistoryPage {
    const normalizedQuery = query?.trim().toLocaleLowerCase() ?? "";
    const matching = [...this.recordsById.values()]
      .filter((record) => includeOpen || record.closedAt !== undefined)
      .filter((record) => matches(record, normalizedQuery))
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt) || left.id.localeCompare(right.id));
    const offset = decodeCursor(cursor);
    const pageSize = boundedPageSize(limit);
    const records = matching.slice(offset, offset + pageSize).map((record) => structuredClone(record));
    const nextOffset = offset + records.length;
    return {
      records,
      total: matching.length,
      ...(nextOffset < matching.length ? { nextCursor: String(nextOffset) } : {}),
    };
  }

  /** Return an identity record for read-only History Chat reconstruction. */
  get(id: string): RetainedHistoryRecord | undefined {
    const record = this.recordsById.get(id);
    return record ? structuredClone(record) : undefined;
  }

  private load(): void {
    try {
      const metadata = statSync(this.options.path);
      if (!metadata.isFile()) return;
      const value: unknown = JSON.parse(readFileSync(this.options.path, "utf8"));
      if (!isRecord(value) || value.schemaVersion !== SCHEMA_VERSION || !Array.isArray(value.records)) return;
      for (const candidate of value.records) {
        const record = normalizeRecord(candidate);
        if (record) this.recordsById.set(record.id, record);
      }
    } catch {
      // A malformed or incompatible store is unavailable history, never launch authority.
    }
  }

  private persist(): void {
    const directory = path.dirname(this.options.path);
    const temporary = `${this.options.path}.${process.pid}.tmp`;
    try {
      mkdirSync(directory, { recursive: true, mode: 0o700 });
      const payload: PersistedHistory = {
        schemaVersion: SCHEMA_VERSION,
        records: [...this.recordsById.values()]
          .sort((left, right) => left.id.localeCompare(right.id)),
      };
      writeFileSync(temporary, JSON.stringify(payload), { encoding: "utf8", mode: 0o600 });
      chmodSync(temporary, 0o600);
      renameSync(temporary, this.options.path);
    } catch {
      try { writeFileSync(temporary, "", { encoding: "utf8" }); } catch { /* best effort cleanup */ }
    }
  }
}

function normalizeObservation(value: RetainedHistoryObservation): RetainedHistoryObservation | undefined {
  if (!isRecord(value) || value.provider !== "claude_code") return undefined;
  const id = bounded(value.id, MAX_ID_LENGTH);
  const title = bounded(value.title, MAX_TITLE_LENGTH);
  const subtitle = bounded(value.subtitle, MAX_TEXT_LENGTH) ?? "";
  const project = bounded(value.project, MAX_TEXT_LENGTH);
  const owner = bounded(value.owner, 128);
  const cwd = absolutePath(value.cwd, MAX_TEXT_LENGTH);
  const host = HOSTS.has(value.host) ? value.host : undefined;
  const updatedAt = iso(value.updatedAt);
  const observedAt = iso(value.observedAt);
  if (!id || !title || !project || !owner || !cwd || !host || !updatedAt || !observedAt) return undefined;
  const sourceProfile = bounded(value.sourceProfile, MAX_PROFILE_LENGTH);
  const transcriptPath = value.transcriptPath === undefined
    ? undefined : absolutePath(value.transcriptPath, MAX_TEXT_LENGTH);
  if (value.transcriptPath !== undefined && !transcriptPath) return undefined;
  return {
    id,
    provider: "claude_code",
    title,
    subtitle,
    ...(sourceProfile ? { sourceProfile } : {}),
    project,
    owner,
    host,
    cwd,
    ...(transcriptPath ? { transcriptPath } : {}),
    updatedAt,
    observedAt,
  };
}

function normalizeRecord(value: unknown): RetainedHistoryRecord | undefined {
  if (!isRecord(value) || value.schemaVersion !== SCHEMA_VERSION) return undefined;
  const observation = normalizeObservation(value as RetainedHistoryObservation);
  if (!observation) return undefined;
  if (value.closedAt === undefined) return { ...observation, schemaVersion: SCHEMA_VERSION };
  const closedAt = iso(value.closedAt);
  if (!closedAt) return undefined;
  return { ...observation, schemaVersion: SCHEMA_VERSION, closedAt };
}

function sameRecord(left: RetainedHistoryRecord, right: RetainedHistoryRecord): boolean {
  const { observedAt: _leftObservedAt, ...leftFacts } = left;
  const { observedAt: _rightObservedAt, ...rightFacts } = right;
  return JSON.stringify(leftFacts) === JSON.stringify(rightFacts);
}

function matches(record: RetainedHistoryRecord, query: string): boolean {
  if (!query) return true;
  return [record.id, record.title, record.subtitle, record.sourceProfile, record.project,
    record.owner, record.host, record.cwd].filter(Boolean).join(" ").toLocaleLowerCase().includes(query);
}

function boundedPageSize(value: number): number {
  return Number.isInteger(value) && value > 0 ? Math.min(value, MAX_PAGE_SIZE) : DEFAULT_PAGE_SIZE;
}

function decodeCursor(cursor: string | undefined): number {
  if (!cursor || !/^\d+$/.test(cursor)) return 0;
  const offset = Number(cursor);
  return Number.isSafeInteger(offset) && offset >= 0 ? offset : 0;
}

function bounded(value: unknown, max: number): string | undefined {
  if (typeof value !== "string" || !value || value.length > max || value.includes("\0")) return undefined;
  return value.trim() || undefined;
}

function absolutePath(value: unknown, max: number): string | undefined {
  const candidate = bounded(value, max);
  return candidate?.startsWith("/") ? candidate : undefined;
}

function iso(value: unknown): string | undefined {
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) return undefined;
  return new Date(value).toISOString();
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
