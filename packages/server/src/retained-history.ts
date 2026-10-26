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
const HOSTS = new Set(["Ghostty", "cmux", "Herdr", "iTerm2", "Terminal"] as const);
const HISTORY_STORAGE_WARNING = "Retained history storage is unavailable.";

export type RetainedHistoryProvider = "claude_code" | "codex" | "paseo";
export type RetainedHistoryHost = "Ghostty" | "cmux" | "Herdr" | "iTerm2" | "Terminal";
export type RetainedHistoryRemovalReason = "agent_visor" | "provider_archived";
export type RetainedHistoryRemovalResult = "removed" | "not_found" | "storage_unavailable";
export type RetainedHistoryRepairResult = "updated" | "not_found" | "storage_unavailable" | "conflict";
export type RetainedHistoryResumeUnavailableReason =
  | "missing_provenance"
  | "unsupported_profile"
  | "unsupported_override"
  | "missing_transcript"
  | "missing_executable"
  | "missing_working_directory"
  | "host_not_supported"
  | "ambiguous_identity";

/** Safe launch references retained from a verified live Claude observation. */
export type RetainedHistoryClaudeResumeCapability = {
  version: 1;
  provider: "claude_code";
  host: "Ghostty";
  executableRef: string;
  executableVersion?: string;
  configRootRef?: string;
  settingsFileRef?: string;
  settingSources?: Array<"user" | "project" | "local">;
  profileRef?: string;
  profileState: "present" | "verified_absent";
  /** Names only; values, tokens, URLs, and the environment are discarded. */
  overrideNames: string[];
  provenanceObservedAt: string;
};

/** Safe launch references retained from a verified live Codex CLI observation. */
export type RetainedHistoryCodexResumeCapability = {
  version: 1;
  /** Native helper provider, intentionally distinct from the catalog provider. */
  provider: "codex_cli";
  host: "Ghostty";
  executableRef: string;
  executableVersion?: string;
  configRootRef: string;
  profileRef?: string;
  profileState: "present" | "verified_absent";
  /** Names only; values, tokens, URLs, and the environment are discarded. */
  overrideNames: string[];
  provenanceObservedAt: string;
};

export type RetainedHistoryResumeCapability =
  | RetainedHistoryClaudeResumeCapability
  | RetainedHistoryCodexResumeCapability;

export type RetainedHistoryObservation = {
  id: string;
  provider: RetainedHistoryProvider;
  /** Stable provider-qualified identity. Defaults to id for legacy callers. */
  canonicalId?: string;
  /** Explicitly verified provider aliases, never title/cwd-derived matches. */
  aliases?: string[];
  /** Verified native Claude identity associated with a Paseo agent. */
  nativeSessionAlias?: string;
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
  /** Launch authority captured from the exact live provider observation. */
  resume?: RetainedHistoryResumeCapability;
  /** Why this row remains History-only when resume provenance is incomplete. */
  resumeUnavailableReason?: RetainedHistoryResumeUnavailableReason;
  /** Provider completion identity, separate from retained updatedAt. */
  completionIdentity?: string;
  /** Explicitly known unopened/reviewed state; absent means legacy unknown. */
  completionUnseen?: boolean;
  /** Prior positive ambient eligibility; never implies current liveness. */
  ambientEligible?: boolean;
  updatedAt: string;
  observedAt: string;
  /** Explicit current frontend/process observation; never inferred by the store. */
  current?: boolean;
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

type RetainedHistoryTombstone = {
  provider: RetainedHistoryProvider;
  id: string;
  canonicalId: string;
  aliases?: string[];
  host?: RetainedHistoryHost;
  configHome?: string;
  removedAt: string;
  reason: RetainedHistoryRemovalReason;
};

type PersistedHistory = {
  schemaVersion: typeof SCHEMA_VERSION;
  records: RetainedHistoryRecord[];
  tombstones?: RetainedHistoryTombstone[];
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
  /** Durable removal intent survives provider catalogs and process restarts. */
  private readonly tombstonesByKey = new Map<string, RetainedHistoryTombstone>();
  private readonly tombstoneKeyByIdentity = new Map<string, string>();
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
    // A provider can expose the canonical ID and one or more verified public
    // projections in the same inventory. Keep that inventory's first public
    // projection stable, while retaining the later projections as aliases;
    // a later refresh with a single new public ID may still promote it.
    const normalizedByIdentity = new Map<string, {
      normalized: NormalizedHistoryObservation;
      current?: boolean;
    }>();
    for (const observation of observations) {
      const normalized = normalizeObservation(observation);
      if (!normalized) continue;
      const identity = historyKey(normalized.provider, normalized.canonicalId);
      const existing = normalizedByIdentity.get(identity);
      if (!existing) {
        normalizedByIdentity.set(identity, { normalized, current: observation.current });
      } else {
        normalizedByIdentity.set(identity, {
          current: existing.current === true || observation.current === true,
          normalized: {
            ...existing.normalized,
            ...mergeAliases(
              existing.normalized.aliases,
              [normalized.id, ...(normalized.aliases ?? [])],
              existing.normalized.canonicalId,
              existing.normalized.id,
            ),
          },
        });
      }
    }
    for (const { normalized, current } of normalizedByIdentity.values()) {
      const tombstoneKey = this.findTombstoneKey(normalized);
      if (tombstoneKey) {
        if (current !== true) continue;
        this.removeTombstone(tombstoneKey);
        changed = true;
      }
      const previousEntry = this.findEntry(normalized);
      const previous = previousEntry?.[1];
      const canonicalId = previous?.canonicalId ?? normalized.canonicalId;
      const publicId = normalized.id;
      // A fresh current observation is the newest launch context. Replace the
      // prior resume status in full: a lost modern transport clears stale
      // Ghostty authority, while newly verified provenance clears an older
      // unavailable reason.
      const currentResumeUpdate = current === true ? {
        resume: normalized.resume,
        resumeUnavailableReason: normalized.resumeUnavailableReason
          ?? (normalized.resume ? undefined : "missing_provenance" as const),
      } : {};
      const next: RetainedHistoryRecord = {
        ...(previous ?? {}),
        ...normalized,
        ...currentResumeUpdate,
        // A verified current observation is the public identity users see.
        // Preserve the prior public ID as an exact alias so an already-open
        // Chat lookup can continue to read the same canonical conversation.
        id: publicId,
        canonicalId,
        ...mergeAliases(
          previous?.aliases,
          [
            ...(previous && previous.id !== publicId ? [previous.id] : []),
            ...(normalized.aliases ?? []),
            ...(normalized.canonicalId !== canonicalId ? [normalized.canonicalId] : []),
          ],
          canonicalId,
          publicId,
        ),
        schemaVersion: SCHEMA_VERSION,
        // A fresh verified observation means the conversation is open again.
        ...(current !== false ? { closedAt: undefined } : (previous?.closedAt ? { closedAt: previous.closedAt } : {})),
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

  /** Remove one exact retained identity while preserving durable origin facts. */
  remove(id: string, reason: RetainedHistoryRemovalReason): RetainedHistoryRemovalResult {
    const providers: RetainedHistoryProvider[] = id.startsWith("codex:")
      ? ["codex"] : ["claude_code", "codex", "paseo"];
    for (const provider of providers) {
      const key = this.keyByIdentity.get(historyKey(provider, id));
      const record = key ? this.recordsByKey.get(key) : undefined;
      if (!key || !record) continue;
      const tombstoneKey = historyKey(record.provider, record.canonicalId);
      const tombstone: RetainedHistoryTombstone = {
        provider: record.provider,
        id: record.id,
        canonicalId: record.canonicalId,
        ...(record.aliases?.length ? { aliases: [...record.aliases] } : {}),
        ...(record.host ? { host: record.host } : {}),
        ...(record.configHome ? { configHome: record.configHome } : {}),
        removedAt: this.now().toISOString(),
        reason,
      };
      this.recordsByKey.delete(key);
      this.removeIdentityIndex(record);
      this.tombstonesByKey.set(tombstoneKey, tombstone);
      this.indexTombstone(tombstoneKey, tombstone);
      if (this.persist()) return "removed";
      this.removeTombstone(tombstoneKey);
      this.recordsByKey.set(key, record);
      this.indexRecord(key, record);
      return "storage_unavailable";
    }
    return "not_found";
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
      ? ["codex"] : ["claude_code", "codex", "paseo"];
    let found: RetainedHistoryRecord | undefined;
    for (const provider of providers) {
      const record = this.getForProvider(provider, id);
      if (!record) continue;
      // A bare UUID is a valid public projection for both providers. Choosing
      // the first catalog entry would let a stale provider claim another
      // provider's launch authority, so ambiguity fails closed.
      if (found) return undefined;
      found = record;
    }
    return found;
  }

  /** Provider-qualified lookup used by adapters during exact reconstruction. */
  getForProvider(provider: RetainedHistoryProvider, id: string): RetainedHistoryRecord | undefined {
    const key = this.keyByIdentity.get(historyKey(provider, id));
    const record = key ? this.recordsByKey.get(key) : undefined;
    return record ? structuredClone(record) : undefined;
  }

  /** Atomically replace launch references for one retained record only. */
  updateResume(
    provider: RetainedHistoryProvider,
    id: string,
    resume: RetainedHistoryResumeCapability,
    expected?: RetainedHistoryRecord,
  ): RetainedHistoryRepairResult {
    const key = this.keyByIdentity.get(historyKey(provider, id));
    const record = key ? this.recordsByKey.get(key) : undefined;
    if (!key || !record) return "not_found";
    if (expected && !sameRepairRecord(record, expected)) return "conflict";
    const previous = record;
    const next: RetainedHistoryRecord = {
      ...record,
      resume: structuredClone(resume),
      resumeUnavailableReason: undefined,
      // The provider config home is part of the source identity. A validated
      // provider capability may repair it only for this exact record.
      ...("configRootRef" in resume ? { configHome: resume.configRootRef } : {}),
    };
    this.recordsByKey.set(key, next);
    if (this.persist()) return "updated";
    this.recordsByKey.set(key, previous);
    return "storage_unavailable";
  }

  /** Atomically replace only the working directory for one retained record. */
  updateWorkingDirectory(
    provider: RetainedHistoryProvider,
    id: string,
    cwd: string,
    expected?: RetainedHistoryRecord,
  ): RetainedHistoryRepairResult {
    const key = this.keyByIdentity.get(historyKey(provider, id));
    const record = key ? this.recordsByKey.get(key) : undefined;
    if (!key || !record) return "not_found";
    if (expected && !sameRepairRecord(record, expected)) return "conflict";
    const previous = record;
    const next: RetainedHistoryRecord = {
      ...record,
      cwd,
    };
    this.recordsByKey.set(key, next);
    if (this.persist()) return "updated";
    this.recordsByKey.set(key, previous);
    return "storage_unavailable";
  }

  /** Persist attention state without changing semantic activity or liveness. */
  updateCompletionAttention(
    provider: RetainedHistoryProvider,
    id: string,
    identity: string,
    unseen: boolean,
  ): RetainedHistoryRepairResult {
    const key = this.keyByIdentity.get(historyKey(provider, id));
    const record = key ? this.recordsByKey.get(key) : undefined;
    if (!key || !record) return "not_found";
    if (record.completionIdentity !== undefined && record.completionIdentity !== identity) {
      return "conflict";
    }
    const next: RetainedHistoryRecord = {
      ...record,
      completionIdentity: identity,
      completionUnseen: unseen,
    };
    this.recordsByKey.set(key, next);
    if (this.persist()) return "updated";
    this.recordsByKey.set(key, record);
    return "storage_unavailable";
  }

  /** Return provider-qualified origin even after AV removal suppressed the row. */
  getOriginForProvider(provider: RetainedHistoryProvider, id: string): {
    provider: RetainedHistoryProvider;
    id: string;
    canonicalId: string;
    aliases?: string[];
    nativeSessionAlias?: string;
    host?: RetainedHistoryHost;
    configHome?: string;
  } | undefined {
    const record = this.getForProvider(provider, id);
    if (record) return originFromRecord(record);
    const key = this.tombstoneKeyByIdentity.get(historyKey(provider, id));
    const tombstone = key ? this.tombstonesByKey.get(key) : undefined;
    if (!tombstone) return undefined;
    return {
      provider: tombstone.provider,
      id: tombstone.id,
      canonicalId: tombstone.canonicalId,
      ...(tombstone.aliases?.length ? { aliases: [...tombstone.aliases] } : {}),
      ...(tombstone.host ? { host: tombstone.host } : {}),
      ...(tombstone.configHome ? { configHome: tombstone.configHome } : {}),
    };
  }

  /** Exact provider-qualified suppression check for stale catalog projections. */
  isSuppressed(provider: RetainedHistoryProvider, ids: readonly string[] | string): boolean {
    const values = typeof ids === "string" ? [ids] : ids;
    return values.some((id) => this.tombstoneKeyByIdentity.has(historyKey(provider, id)));
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
      let invalidTombstone = false;
      if (value.tombstones !== undefined) {
        if (!Array.isArray(value.tombstones)) {
          invalidTombstone = true;
        } else {
          for (const candidate of value.tombstones) {
            const tombstone = normalizeTombstone(candidate);
            if (tombstone) {
              const key = historyKey(tombstone.provider, tombstone.canonicalId);
              this.tombstonesByKey.set(key, tombstone);
              this.indexTombstone(key, tombstone);
            } else {
              invalidTombstone = true;
            }
          }
        }
      }
      if (invalidRecord || invalidTombstone) this.historyWarningMessage = HISTORY_STORAGE_WARNING;
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

  private indexTombstone(key: string, tombstone: RetainedHistoryTombstone): void {
    for (const identity of [tombstone.id, tombstone.canonicalId, ...(tombstone.aliases ?? [])]) {
      this.tombstoneKeyByIdentity.set(historyKey(tombstone.provider, identity), key);
    }
  }

  private removeTombstone(key: string): void {
    const tombstone = this.tombstonesByKey.get(key);
    if (!tombstone) return;
    this.tombstonesByKey.delete(key);
    for (const identity of [tombstone.id, tombstone.canonicalId, ...(tombstone.aliases ?? [])]) {
      this.tombstoneKeyByIdentity.delete(historyKey(tombstone.provider, identity));
    }
  }

  private findTombstoneKey(observation: NormalizedHistoryObservation): string | undefined {
    for (const identity of [observation.canonicalId, observation.id, ...(observation.aliases ?? [])]) {
      const key = this.tombstoneKeyByIdentity.get(historyKey(observation.provider, identity));
      if (key) return key;
    }
    return undefined;
  }

  private persist(): boolean {
    const directory = path.dirname(this.options.path);
    const temporary = `${this.options.path}.${process.pid}.tmp`;
    try {
      mkdirSync(directory, { recursive: true, mode: 0o700 });
      const payload: PersistedHistory = {
        schemaVersion: SCHEMA_VERSION,
        records: [...this.recordsByKey.values()]
          .sort((left, right) => historyKey(left.provider, left.canonicalId)
            .localeCompare(historyKey(right.provider, right.canonicalId))),
        tombstones: [...this.tombstonesByKey.values()]
          .sort((left, right) => historyKey(left.provider, left.canonicalId)
            .localeCompare(historyKey(right.provider, right.canonicalId))),
      };
      writeFileSync(temporary, JSON.stringify(payload), { encoding: "utf8", mode: 0o600 });
      chmodSync(temporary, 0o600);
      renameSync(temporary, this.options.path);
      this.historyWarningMessage = undefined;
      return true;
    } catch {
      this.historyWarningMessage = HISTORY_STORAGE_WARNING;
      try { writeFileSync(temporary, "", { encoding: "utf8" }); } catch { /* best effort cleanup */ }
      return false;
    }
  }
}

function normalizeObservation(value: RetainedHistoryObservation): NormalizedHistoryObservation | undefined {
  if (!isRecord(value) || (value.provider !== "claude_code" && value.provider !== "codex"
    && value.provider !== "paseo")) return undefined;
  const id = bounded(value.id, MAX_ID_LENGTH);
  const canonicalId = bounded(value.canonicalId, MAX_CANONICAL_ID_LENGTH) ?? id;
  const title = bounded(value.title, MAX_TITLE_LENGTH) ?? `${value.provider === "codex" ? "Codex" : value.provider === "paseo" ? "Paseo" : "Claude Code"} session`;
  const subtitle = bounded(value.subtitle, MAX_TEXT_LENGTH) ?? "";
  const project = bounded(value.project, MAX_TEXT_LENGTH);
  const cwd = absolutePath(value.cwd, MAX_TEXT_LENGTH);
  const fallbackProject = cwd ? path.basename(cwd) || cwd : undefined;
  const owner = bounded(value.owner, 128) ?? (value.provider === "codex" ? "Codex" : value.provider === "paseo" ? "Paseo" : "Claude");
  const hostValue = value.host;
  const host = typeof hostValue === "string" && HOSTS.has(hostValue as RetainedHistoryHost)
    ? hostValue as RetainedHistoryHost : undefined;
  const updatedAt = iso(value.updatedAt);
  const observedAt = iso(value.observedAt);
  if (!id || !canonicalId || !title || !(project || fallbackProject) || !owner || !cwd || !updatedAt || !observedAt) return undefined;
  if (value.host !== undefined && !host) return undefined;
  const sourceProfile = bounded(value.sourceProfile, MAX_PROFILE_LENGTH);
  const configHome = value.configHome === undefined ? undefined : absolutePath(value.configHome, MAX_CONFIG_HOME_LENGTH);
  if (value.configHome !== undefined && !configHome) return undefined;
  const aliases = normalizeAliases(value.aliases, canonicalId, id);
  if (value.aliases !== undefined && !aliases) return undefined;
  const nativeSessionAlias = value.nativeSessionAlias === undefined
    ? undefined : bounded(value.nativeSessionAlias, MAX_ID_LENGTH);
  if (value.nativeSessionAlias !== undefined && !nativeSessionAlias) return undefined;
  const transcriptPath = value.transcriptPath === undefined
    ? undefined : absolutePath(value.transcriptPath, MAX_TEXT_LENGTH);
  if (value.transcriptPath !== undefined && !transcriptPath) return undefined;
  const resume = value.resume === undefined ? undefined : normalizeResumeCapability(value.resume);
  const resumeContextInvalid = resume !== undefined
    && (host !== "Ghostty" || resume.host !== host
      || (configHome !== undefined && "configRootRef" in resume
        && resume.configRootRef !== undefined && resume.configRootRef !== configHome));
  const resumeDetailsInvalid = value.resume !== undefined
    && (!resume || value.provider === "paseo" || (value.provider === "claude_code"
      ? resume.provider !== "claude_code" : resume.provider !== "codex_cli") || resumeContextInvalid);
  const parsedResumeUnavailableReason = value.resumeUnavailableReason === undefined
    ? undefined : normalizeResumeUnavailableReason(value.resumeUnavailableReason);
  const resumeUnavailableReason = (resumeContextInvalid && host !== "Ghostty")
    ? "host_not_supported" as const
    : (resumeDetailsInvalid
      || (value.resumeUnavailableReason !== undefined && !parsedResumeUnavailableReason)
      ? "missing_provenance" as const
      : parsedResumeUnavailableReason);
  const completionIdentity = value.completionIdentity === undefined
    ? undefined : bounded(value.completionIdentity, MAX_ID_LENGTH);
  if (value.completionIdentity !== undefined && !completionIdentity) return undefined;
  const completionUnseen = value.completionUnseen === undefined
    ? undefined : value.completionUnseen;
  if (value.completionUnseen !== undefined && typeof completionUnseen !== "boolean") return undefined;
  const ambientEligible = value.ambientEligible === undefined
    ? undefined : value.ambientEligible;
  if (value.ambientEligible !== undefined && typeof ambientEligible !== "boolean") return undefined;
  return {
    id,
    provider: value.provider,
    canonicalId,
    ...(aliases?.length ? { aliases } : {}),
    ...(nativeSessionAlias ? { nativeSessionAlias } : {}),
    title,
    subtitle,
    ...(sourceProfile ? { sourceProfile } : {}),
    project: project ?? fallbackProject!,
    owner,
    ...(host ? { host } : {}),
    cwd,
    ...(configHome ? { configHome } : {}),
    ...(transcriptPath ? { transcriptPath } : {}),
    ...(!resumeDetailsInvalid && resume ? { resume } : {}),
    ...(resumeUnavailableReason ? { resumeUnavailableReason } : {}),
    ...(completionIdentity ? { completionIdentity } : {}),
    ...(completionUnseen !== undefined ? { completionUnseen } : {}),
    ...(ambientEligible !== undefined ? { ambientEligible } : {}),
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

function normalizeTombstone(value: unknown): RetainedHistoryTombstone | undefined {
  if (!isRecord(value) || (value.provider !== "claude_code" && value.provider !== "codex"
    && value.provider !== "paseo")) return undefined;
  const id = bounded(value.id, MAX_ID_LENGTH);
  const canonicalId = bounded(value.canonicalId, MAX_CANONICAL_ID_LENGTH);
  const removedAt = iso(value.removedAt);
  const reason = value.reason === "agent_visor" || value.reason === "provider_archived"
    ? value.reason : undefined;
  const aliases = normalizeAliases(value.aliases, canonicalId ?? "", id ?? "");
  const hostValue = value.host;
  const host = typeof hostValue === "string" && HOSTS.has(hostValue as RetainedHistoryHost)
    ? hostValue as RetainedHistoryHost : undefined;
  const configHome = value.configHome === undefined ? undefined : absolutePath(value.configHome, MAX_CONFIG_HOME_LENGTH);
  if (!id || !canonicalId || !removedAt || !reason || (value.aliases !== undefined && !aliases)
    || (value.host !== undefined && !host) || (value.configHome !== undefined && !configHome)) return undefined;
  return {
    provider: value.provider,
    id,
    canonicalId,
    ...(aliases?.length ? { aliases } : {}),
    ...(host ? { host } : {}),
    ...(configHome ? { configHome } : {}),
    removedAt,
    reason,
  };
}

function originFromRecord(record: RetainedHistoryRecord): {
  provider: RetainedHistoryProvider;
  id: string;
  canonicalId: string;
  aliases?: string[];
  nativeSessionAlias?: string;
  host?: RetainedHistoryHost;
  configHome?: string;
} {
  return {
    provider: record.provider,
    id: record.id,
    canonicalId: record.canonicalId,
    ...(record.aliases?.length ? { aliases: [...record.aliases] } : {}),
    ...(record.nativeSessionAlias ? { nativeSessionAlias: record.nativeSessionAlias } : {}),
    ...(record.host ? { host: record.host } : {}),
    ...(record.configHome ? { configHome: record.configHome } : {}),
  };
}

function sameRecord(left: RetainedHistoryRecord, right: RetainedHistoryRecord): boolean {
  return JSON.stringify(durableRecordFacts(left)) === JSON.stringify(durableRecordFacts(right));
}

function durableRecordFacts(record: RetainedHistoryRecord): Record<string, unknown> {
  const { observedAt: _observedAt, resume, ...facts } = record;
  if (!resume) return facts;
  const { provenanceObservedAt: _provenanceObservedAt, ...resumeFacts } = resume;
  return { ...facts, resume: resumeFacts };
}

function matches(record: RetainedHistoryRecord, query: string): boolean {
  if (!query) return true;
  return [record.id, record.canonicalId, ...(record.aliases ?? []), record.title, record.subtitle,
    record.sourceProfile, record.project, record.owner, record.host, record.cwd, record.configHome]
    .filter(Boolean).join(" ").toLocaleLowerCase().includes(query);
}

function normalizeAliases(value: unknown, canonicalId: string, id: string): string[] | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) return undefined;
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

function sameRepairRecord(current: RetainedHistoryRecord, expected: RetainedHistoryRecord): boolean {
  return JSON.stringify({
    provider: current.provider,
    id: current.id,
    canonicalId: current.canonicalId,
    aliases: current.aliases,
    host: current.host,
    cwd: current.cwd,
    configHome: current.configHome,
    transcriptPath: current.transcriptPath,
    resume: current.resume,
    resumeUnavailableReason: current.resumeUnavailableReason,
    completionIdentity: current.completionIdentity,
    completionUnseen: current.completionUnseen,
    ambientEligible: current.ambientEligible,
    closedAt: current.closedAt,
    updatedAt: current.updatedAt,
    observedAt: current.observedAt,
  }) === JSON.stringify({
    provider: expected.provider,
    id: expected.id,
    canonicalId: expected.canonicalId,
    aliases: expected.aliases,
    host: expected.host,
    cwd: expected.cwd,
    configHome: expected.configHome,
    transcriptPath: expected.transcriptPath,
    resume: expected.resume,
    resumeUnavailableReason: expected.resumeUnavailableReason,
    completionIdentity: expected.completionIdentity,
    completionUnseen: expected.completionUnseen,
    ambientEligible: expected.ambientEligible,
    closedAt: expected.closedAt,
    updatedAt: expected.updatedAt,
    observedAt: expected.observedAt,
  });
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

function normalizeResumeCapability(value: unknown): RetainedHistoryResumeCapability | undefined {
  if (!isRecord(value) || value.version !== 1 || value.host !== "Ghostty"
    || (value.provider !== "claude_code" && value.provider !== "codex_cli")) return undefined;
  const executableRef = absolutePath(value.executableRef, MAX_CONFIG_HOME_LENGTH);
  const executableVersion = value.executableVersion === undefined
    ? undefined : bounded(value.executableVersion, 128);
  const configRootRef = value.configRootRef === undefined
    ? undefined : absolutePath(value.configRootRef, MAX_CONFIG_HOME_LENGTH);
  const settingsFileRef = value.settingsFileRef === undefined
    ? undefined : absolutePath(value.settingsFileRef, MAX_CONFIG_HOME_LENGTH);
  const profileRef = value.profileRef === undefined ? undefined : profileName(value.profileRef);
  const profileState = value.profileState === "present" || value.profileState === "verified_absent"
    ? value.profileState : undefined;
  const overrideNames = normalizeOverrideNames(value.overrideNames);
  const provenanceObservedAt = iso(value.provenanceObservedAt);
  if (!executableRef || !profileState || !provenanceObservedAt || !overrideNames
    || (value.executableVersion !== undefined && !executableVersion)
    || (value.profileRef !== undefined && !profileRef)) return undefined;
  if (value.provider === "codex_cli") {
    const configRoot = absolutePath(value.configRootRef, MAX_CONFIG_HOME_LENGTH);
    if (!configRoot || value.settingsFileRef !== undefined || value.settingSources !== undefined) return undefined;
    return {
      version: 1,
      provider: "codex_cli",
      host: "Ghostty",
      executableRef,
      ...(executableVersion ? { executableVersion } : {}),
      configRootRef: configRoot,
      ...(profileRef ? { profileRef } : {}),
      profileState,
      overrideNames,
      provenanceObservedAt,
    };
  }
  const settingSources = normalizeSettingSources(value.settingSources);
  if ((value.configRootRef !== undefined && !configRootRef)
    || (value.settingsFileRef !== undefined && !settingsFileRef)
    || (value.settingSources !== undefined && !settingSources)) return undefined;
  return {
    version: 1,
    provider: "claude_code",
    host: "Ghostty",
    executableRef,
    ...(executableVersion ? { executableVersion } : {}),
    ...(configRootRef ? { configRootRef } : {}),
    ...(settingsFileRef ? { settingsFileRef } : {}),
    ...(settingSources?.length ? { settingSources } : {}),
    ...(profileRef ? { profileRef } : {}),
    profileState,
    overrideNames,
    provenanceObservedAt,
  };
}

function normalizeSettingSources(value: unknown): Array<"user" | "project" | "local"> | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || value.length > 3) return undefined;
  const values = value.flatMap((candidate) => candidate === "user" || candidate === "project" || candidate === "local"
    ? [candidate] : []);
  return values.length === value.length ? [...new Set(values)] : undefined;
}

function normalizeOverrideNames(value: unknown): string[] | undefined {
  if (!Array.isArray(value) || value.length > 32) return undefined;
  const values = value.flatMap((candidate) => {
    const name = typeof candidate === "string" && /^[A-Z][A-Z0-9_]{0,127}$/.test(candidate)
      ? candidate : undefined;
    return name ? [name] : [];
  });
  return values.length === value.length ? [...new Set(values)] : undefined;
}

function profileName(value: unknown): string | undefined {
  return typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value)
    ? value : undefined;
}

function normalizeResumeUnavailableReason(value: unknown): RetainedHistoryResumeUnavailableReason | undefined {
  return value === "missing_provenance" || value === "unsupported_profile"
    || value === "unsupported_override" || value === "missing_transcript"
    || value === "missing_executable" || value === "missing_working_directory"
    || value === "host_not_supported"
    || value === "ambiguous_identity" ? value : undefined;
}

function iso(value: unknown): string | undefined {
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) return undefined;
  return new Date(value).toISOString();
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
