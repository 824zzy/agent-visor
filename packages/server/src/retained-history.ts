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
const MAX_CONFIG_HOME_LENGTH = 4_096;
const MAX_CANONICAL_ID_LENGTH = 1_024;
const MAX_ALIASES = 16;
const HOSTS = new Set(["Ghostty", "cmux", "Herdr", "iTerm2", "Terminal"] as const);
const HISTORY_STORAGE_WARNING = "Retained history storage is unavailable.";

export type RetainedHistoryProvider = "claude_code" | "codex";
export type RetainedHistoryHost = "Ghostty" | "cmux" | "Herdr" | "iTerm2" | "Terminal";

export type RetainedHistoryObservation = {
  id: string;
  provider: RetainedHistoryProvider;
  /** Stable provider-qualified identity. Defaults to id for legacy callers. */
  canonicalId?: string;
  /** Explicitly verified provider aliases, never title/cwd-derived matches. */
  aliases?: string[];
  title?: string;
  subtitle?: string;
  sourceProfile?: string;
  project?: string;
  owner?: string;
  host?: RetainedHistoryHost;
  cwd: string;
  /** Exact provider configuration home, when the provider observer proved it. */
  configHome?: string;
  transcriptPath?: string;
  updatedAt: string;
  observedAt: string;
};

export type RetainedHistoryRecord = NormalizedHistoryObservation & {
  schemaVersion: typeof SCHEMA_VERSION;
  closedAt?: string;
};

export type RetainedHistoryPage = {
  records: RetainedHistoryRecord[];
  total: number;
  nextCursor?: string;
  historyWarning?: string;
};

type NormalizedHistoryObservation = RetainedHistoryObservation & {
  id: string;
  canonicalId: string;
  title: string;
  subtitle: string;
  project: string;
  owner: string;
  aliases?: string[];
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
  private readonly recordsByKey = new Map<string, RetainedHistoryRecord>();
  /** Provider-qualified identity index keeps exact reconstruction bounded. */
  private readonly keyByIdentity = new Map<string, string>();
  private readonly now: () => Date;
  private historyWarningMessage: string | undefined;

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
      const previousEntry = this.findEntry(normalized);
      const previous = previousEntry?.[1];
      const canonicalId = previous?.canonicalId ?? normalized.canonicalId;
      const next: RetainedHistoryRecord = {
        ...(previous ?? {}),
        ...normalized,
        id: previous?.id ?? normalized.id,
        canonicalId,
        ...mergeAliases(
          previous?.aliases,
          [...(normalized.aliases ?? []), ...(normalized.canonicalId !== canonicalId ? [normalized.canonicalId] : [])],
          canonicalId,
          previous?.id ?? normalized.id,
        ),
        schemaVersion: SCHEMA_VERSION,
        // A fresh verified observation means the conversation is open again.
        closedAt: undefined,
      };
      const key = historyKey(next.provider, canonicalId);
      if (previousEntry && previousEntry[0] !== key) {
        this.recordsByKey.delete(previousEntry[0]);
        this.removeIdentityIndex(previousEntry[1]);
      }
      if (!previous || !sameRecord(previous, next) || !previousEntry || previousEntry[0] !== key) {
        if (previousEntry && previousEntry[0] === key) this.removeIdentityIndex(previousEntry[1]);
        this.recordsByKey.set(key, next);
        this.indexRecord(key, next);
        changed = true;
      }
    }
    if (changed) this.persist();
  }

  /** Mark only previously observed conversations absent from a successful discovery as closed. */
  closeMissing(activeConversationIds: ReadonlySet<string>, provider?: RetainedHistoryProvider): void {
    const closedAt = this.now().toISOString();
    let changed = false;
    for (const [key, record] of this.recordsByKey) {
      if ((provider && record.provider !== provider)
        || record.closedAt || isActive(record, activeConversationIds)) continue;
      this.recordsByKey.set(key, { ...record, closedAt });
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
    includeOpenProviders?: ReadonlySet<RetainedHistoryProvider>,
  ): RetainedHistoryPage {
    const normalizedQuery = query?.trim().toLocaleLowerCase() ?? "";
    const matching = [...this.recordsByKey.values()]
      .filter((record) => includeOpen || record.closedAt !== undefined
        || includeOpenProviders?.has(record.provider) === true)
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
      ...(this.historyWarningMessage ? { historyWarning: this.historyWarningMessage } : {}),
    };
  }

  /** Return an identity record for read-only History Chat reconstruction. */
  get(id: string): RetainedHistoryRecord | undefined {
    const providers: RetainedHistoryProvider[] = id.startsWith("codex:")
      ? ["codex"] : ["claude_code", "codex"];
    for (const provider of providers) {
      const record = this.getForProvider(provider, id);
      if (record) return record;
    }
    return undefined;
  }

  /** Provider-qualified lookup used by adapters during exact reconstruction. */
  getForProvider(provider: RetainedHistoryProvider, id: string): RetainedHistoryRecord | undefined {
    const key = this.keyByIdentity.get(historyKey(provider, id));
    const record = key ? this.recordsByKey.get(key) : undefined;
    return record ? structuredClone(record) : undefined;
  }

  private findEntry(
    observation: NormalizedHistoryObservation,
  ): [string, RetainedHistoryRecord] | undefined {
    const directKey = this.keyByIdentity.get(historyKey(observation.provider, observation.canonicalId));
    const direct = directKey ? this.recordsByKey.get(directKey) : undefined;
    if (direct && directKey) return [directKey, direct];
    for (const identity of [observation.id, ...(observation.aliases ?? [])]) {
      const key = this.keyByIdentity.get(historyKey(observation.provider, identity));
      const record = key ? this.recordsByKey.get(key) : undefined;
      if (key && record) return [key, record];
    }
    return undefined;
  }

  private load(): void {
    try {
      const metadata = statSync(this.options.path);
      if (!metadata.isFile()) {
        this.historyWarningMessage = HISTORY_STORAGE_WARNING;
        return;
      }
      const value: unknown = JSON.parse(readFileSync(this.options.path, "utf8"));
      if (!isRecord(value) || value.schemaVersion !== SCHEMA_VERSION || !Array.isArray(value.records)) {
        this.historyWarningMessage = HISTORY_STORAGE_WARNING;
        return;
      }
      let invalidRecord = false;
      for (const candidate of value.records) {
        const record = normalizeRecord(candidate);
        if (record) {
          const key = historyKey(record.provider, record.canonicalId);
          this.recordsByKey.set(key, record);
          this.indexRecord(key, record);
        }
        else invalidRecord = true;
      }
      if (invalidRecord) this.historyWarningMessage = HISTORY_STORAGE_WARNING;
    } catch {
      // A malformed or incompatible store is unavailable history, never launch authority.
      try {
        if (statSync(this.options.path).isFile()) this.historyWarningMessage = HISTORY_STORAGE_WARNING;
      } catch { /* A missing path will be created on the first observation. */ }
    }
  }

  private indexRecord(key: string, record: RetainedHistoryRecord): void {
    for (const identity of [record.id, record.canonicalId, ...(record.aliases ?? [])]) {
      this.keyByIdentity.set(historyKey(record.provider, identity), key);
    }
  }

  private removeIdentityIndex(record: RetainedHistoryRecord): void {
    for (const identity of [record.id, record.canonicalId, ...(record.aliases ?? [])]) {
      this.keyByIdentity.delete(historyKey(record.provider, identity));
    }
  }

  private persist(): void {
    const directory = path.dirname(this.options.path);
    const temporary = `${this.options.path}.${process.pid}.tmp`;
    try {
      mkdirSync(directory, { recursive: true, mode: 0o700 });
      const payload: PersistedHistory = {
        schemaVersion: SCHEMA_VERSION,
        records: [...this.recordsByKey.values()]
          .sort((left, right) => historyKey(left.provider, left.canonicalId)
            .localeCompare(historyKey(right.provider, right.canonicalId))),
      };
      writeFileSync(temporary, JSON.stringify(payload), { encoding: "utf8", mode: 0o600 });
      chmodSync(temporary, 0o600);
      renameSync(temporary, this.options.path);
      this.historyWarningMessage = undefined;
    } catch {
      this.historyWarningMessage = HISTORY_STORAGE_WARNING;
      try { writeFileSync(temporary, "", { encoding: "utf8" }); } catch { /* best effort cleanup */ }
    }
  }
}

function normalizeObservation(value: RetainedHistoryObservation): NormalizedHistoryObservation | undefined {
  if (!isRecord(value) || (value.provider !== "claude_code" && value.provider !== "codex")) return undefined;
  const id = bounded(value.id, MAX_ID_LENGTH);
  const canonicalId = bounded(value.canonicalId, MAX_CANONICAL_ID_LENGTH) ?? id;
  const title = bounded(value.title, MAX_TITLE_LENGTH) ?? `${value.provider === "codex" ? "Codex" : "Claude Code"} session`;
  const subtitle = bounded(value.subtitle, MAX_TEXT_LENGTH) ?? "";
  const project = bounded(value.project, MAX_TEXT_LENGTH);
  const cwd = absolutePath(value.cwd, MAX_TEXT_LENGTH);
  const fallbackProject = cwd ? path.basename(cwd) || cwd : undefined;
  const owner = bounded(value.owner, 128) ?? (value.provider === "codex" ? "Codex" : "Claude");
  const host = value.host === undefined ? undefined : HOSTS.has(value.host) ? value.host : undefined;
  const updatedAt = iso(value.updatedAt);
  const observedAt = iso(value.observedAt);
  if (!id || !canonicalId || !title || !(project || fallbackProject) || !owner || !cwd || !updatedAt || !observedAt) return undefined;
  if (value.host !== undefined && !host) return undefined;
  const sourceProfile = bounded(value.sourceProfile, MAX_PROFILE_LENGTH);
  const configHome = value.configHome === undefined ? undefined : absolutePath(value.configHome, MAX_CONFIG_HOME_LENGTH);
  if (value.configHome !== undefined && !configHome) return undefined;
  const aliases = normalizeAliases(value.aliases, canonicalId, id);
  if (value.aliases !== undefined && !aliases) return undefined;
  const transcriptPath = value.transcriptPath === undefined
    ? undefined : absolutePath(value.transcriptPath, MAX_TEXT_LENGTH);
  if (value.transcriptPath !== undefined && !transcriptPath) return undefined;
  return {
    id,
    provider: value.provider,
    canonicalId,
    ...(aliases?.length ? { aliases } : {}),
    title,
    subtitle,
    ...(sourceProfile ? { sourceProfile } : {}),
    project: project ?? fallbackProject!,
    owner,
    ...(host ? { host } : {}),
    cwd,
    ...(configHome ? { configHome } : {}),
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
  return [record.id, record.canonicalId, ...(record.aliases ?? []), record.title, record.subtitle,
    record.sourceProfile, record.project, record.owner, record.host, record.cwd, record.configHome]
    .filter(Boolean).join(" ").toLocaleLowerCase().includes(query);
}

function normalizeAliases(value: unknown, canonicalId: string, id: string): string[] | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || value.length > MAX_ALIASES) return undefined;
  const aliases = value.flatMap((candidate) => {
    const alias = bounded(candidate, MAX_CANONICAL_ID_LENGTH);
    return alias && alias !== canonicalId && alias !== id ? [alias] : [];
  });
  return aliases.length ? [...new Set(aliases)] : [];
}

function mergeAliases(
  previous: string[] | undefined,
  current: string[] | undefined,
  canonicalId: string,
  id: string,
): { aliases?: string[] } {
  const aliases = [...new Set([...(previous ?? []), ...(current ?? [])])]
    .filter((alias) => alias !== canonicalId && alias !== id);
  return aliases.length ? { aliases } : {};
}

function historyKey(provider: RetainedHistoryProvider, canonicalId: string): string {
  return `${provider}\u0000${canonicalId}`;
}

function matchesIdentity(record: RetainedHistoryRecord, id: string): boolean {
  return record.id === id || record.canonicalId === id || record.aliases?.includes(id) === true;
}

function isActive(record: RetainedHistoryRecord, activeIds: ReadonlySet<string>): boolean {
  return [...activeIds].some((id) => matchesIdentity(record, id));
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
