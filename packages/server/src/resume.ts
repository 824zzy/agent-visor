import { chmodSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import path from "node:path";
import type {
  HistoryRepairSelection,
  NativeHelperGhosttyResumeDispatch,
  NativeHelperGhosttyResumeTarget,
  NativeHelperGhosttyTerminalView,
} from "@agent-visor/protocol";
import { nativeHelperGhosttyResumeDispatchSchema } from "@agent-visor/protocol";
import type {
  RetainedHistoryRecord,
  RetainedHistoryResumeUnavailableReason,
} from "./retained-history.js";
import type { DiscoveredProviderSession } from "./sessions.js";

export type ResumeLiveness =
  | { state: "live"; session: DiscoveredProviderSession }
  | { state: "stopped" }
  | { state: "unknown"; reason: string };

export type ResumeTargetResult =
  | { state: "eligible"; target: NativeHelperGhosttyResumeTarget }
  | { state: "unavailable"; reason: string };

export type ResumeRepairValidation =
  | { state: "valid"; capability: import("./retained-history.js").RetainedHistoryResumeCapability }
  | { state: "unavailable"; reason: string };

export type ResumeReconciliation =
  | { state: "matched"; sessionId: string; terminal: NativeHelperGhosttyTerminalView }
  | { state: "pending"; reason: string }
  | { state: "unavailable"; reason: string }
  /**
   * A retryable unknown is limited to the short post-dispatch startup window.
   * Other unknown outcomes remain conservative and do not trigger another
   * provider read in this initial launch slice.
   */
  | { state: "unknown"; reason: string; retryable?: boolean };

/** Provider-specific evidence and launch strategy used only by explicit Resume. */
export type ResumeProviderID = "claude_code" | "codex";
export type ResumeNativeProvider = "claude_code" | "codex_cli";

export interface ResumeProviderAdapter {
  readonly id: ResumeProviderID;
  /** Native helper discriminator; catalog and wire providers are different for Codex. */
  readonly nativeProvider?: ResumeNativeProvider;
  resumeLiveness(record: RetainedHistoryRecord): Promise<ResumeLiveness>;
  resumeTarget(record: RetainedHistoryRecord, attemptId: string, nonce: string): ResumeTargetResult;
  /** Validate one explicit provider repair without dispatching or mutating state. */
  validateRepair?(record: RetainedHistoryRecord, selection: HistoryRepairSelection): ResumeRepairValidation;
  reconcileResume(
    record: RetainedHistoryRecord,
    dispatch: NativeHelperGhosttyResumeDispatch,
  ): Promise<ResumeReconciliation>;
}

export interface ResumeNativeController {
  openGhosttyResume(target: NativeHelperGhosttyResumeTarget): Promise<NativeHelperGhosttyResumeDispatch>;
  focusGhosttyTerminal(target: NativeHelperGhosttyTerminalView): Promise<void>;
}

export type ResumeAttemptState = "claimed" | "dispatched" | "matched" | "unknown" | "unavailable";

export type ResumeAttempt = {
  version: 1;
  attemptId: string;
  provider: ResumeProviderID;
  sessionId: string;
  canonicalId: string;
  state: ResumeAttemptState;
  claimedAt: string;
  updatedAt: string;
  dispatch?: NativeHelperGhosttyResumeDispatch;
  reason?: string;
};

type PersistedAttempts = { version: 1; attempts: ResumeAttempt[] };

export type ResumeClaim =
  | { state: "created"; attempt: ResumeAttempt }
  | { state: "join"; attempt: ResumeAttempt }
  | { state: "blocked"; attempt: ResumeAttempt };

/** Small atomic JSON journal; a claim is durable before native dispatch. */
export class ResumeAttemptStore {
  private readonly attempts = new Map<string, ResumeAttempt>();
  private readonly now: () => Date;
  private fingerprint = "";
  private loadFailure: string | undefined;

  constructor(private readonly file: string | undefined, now: () => Date = () => new Date()) {
    this.now = now;
    this.load();
  }

  get(canonicalId: string): ResumeAttempt | undefined;
  get(provider: ResumeProviderID, canonicalId: string): ResumeAttempt | undefined;
  get(providerOrCanonicalId: ResumeProviderID | string, canonicalID?: string): ResumeAttempt | undefined {
    const provider = canonicalID === undefined ? "claude_code" : providerOrCanonicalId as ResumeProviderID;
    const canonicalId = canonicalID ?? providerOrCanonicalId;
    const attempt = this.attempts.get(attemptKey(provider, canonicalId));
    return attempt ? structuredClone(attempt) : undefined;
  }

  claim(
    sessionId: string,
    canonicalId: string,
    provider: ResumeProviderID = "claude_code",
  ): ResumeClaim | { state: "unavailable"; reason: string } {
    if (!this.file) return { state: "unavailable", reason: "Resume state has no durable store." };
    if (this.loadFailure) return { state: "unavailable", reason: this.loadFailure };
    const key = attemptKey(provider, canonicalId);
    const existing = this.attempts.get(key);
    if (existing) {
      // The in-memory coordinator joins concurrent calls before reaching the
      // journal. A claimed row loaded after restart has no live owner and
      // therefore cannot authorize replay of a possibly-created window.
      return { state: "blocked", attempt: structuredClone(existing) };
    }
    const now = this.now().toISOString();
    const attempt: ResumeAttempt = {
      version: 1,
      attemptId: randomUUID(),
      provider,
      sessionId,
      canonicalId,
      state: "claimed",
      claimedAt: now,
      updatedAt: now,
    };
    this.attempts.set(key, attempt);
    if (!this.persist()) {
      this.attempts.delete(key);
      return { state: "unavailable", reason: "Resume state could not be saved." };
    }
    return { state: "created", attempt: structuredClone(attempt) };
  }

  update(
    canonicalId: string,
    state: ResumeAttemptState,
    patch: { dispatch?: NativeHelperGhosttyResumeDispatch; reason?: string } = {},
    provider: ResumeProviderID = "claude_code",
  ): ResumeAttempt | undefined {
    const key = attemptKey(provider, canonicalId);
    const current = this.attempts.get(key);
    if (!current) return undefined;
    const next: ResumeAttempt = {
      ...current,
      state,
      updatedAt: this.now().toISOString(),
      ...(patch.dispatch ? { dispatch: structuredClone(patch.dispatch) } : {}),
      ...(patch.reason ? { reason: patch.reason } : {}),
    };
    this.attempts.set(key, next);
    if (this.persist()) return structuredClone(next);
    this.attempts.set(key, current);
    return undefined;
  }

  private load(): void {
    if (!this.file) return;
    try {
      let metadata;
      try {
        metadata = statSync(this.file);
      } catch (error) {
        if (isMissingFile(error)) return;
        this.loadFailure = "Resume state could not be read.";
        return;
      }
      if (!metadata.isFile() || metadata.size > 1_048_576) {
        this.loadFailure = "Resume state is invalid or too large.";
        return;
      }
      const value: unknown = JSON.parse(readFileSync(this.file, "utf8"));
      if (!isRecord(value) || value.version !== 1 || !Array.isArray(value.attempts)) {
        this.loadFailure = "Resume state is incompatible.";
        return;
      }
      for (const candidate of value.attempts) {
        const normalized = normalizeAttempt(candidate);
        if (!normalized) {
          this.attempts.clear();
          this.loadFailure = "Resume state is invalid.";
          return;
        }
        const key = attemptKey(normalized.provider, normalized.canonicalId);
        if (this.attempts.has(key)) {
          this.attempts.clear();
          this.loadFailure = "Resume state contains duplicate identities.";
          return;
        }
        this.attempts.set(key, normalized);
      }
      this.fingerprint = this.serialize();
    } catch {
      this.attempts.clear();
      this.loadFailure = "Resume state could not be read.";
    }
  }

  private persist(): boolean {
    const value = this.serialize();
    if (!this.file || this.loadFailure) return false;
    if (value === this.fingerprint) return true;
    const draft = `${this.file}.${process.pid}.${randomUUID()}.tmp`;
    try {
      mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
      writeFileSync(draft, value, { encoding: "utf8", mode: 0o600, flag: "wx" });
      chmodSync(draft, 0o600);
      renameSync(draft, this.file);
      this.fingerprint = value;
      return true;
    } catch {
      try { writeFileSync(draft, "", { encoding: "utf8" }); } catch { /* best effort cleanup */ }
      return false;
    }
  }

  private serialize(): string {
    const payload: PersistedAttempts = {
      version: 1,
      attempts: [...this.attempts.values()].sort((left, right) =>
        attemptKey(left.provider, left.canonicalId).localeCompare(attemptKey(right.provider, right.canonicalId))),
    };
    return JSON.stringify(payload);
  }
}

export type ResumeResult =
  | { state: "focused"; sessionId: string }
  | { state: "matched"; sessionId: string; attemptId: string }
  | { state: "joined"; sessionId: string; attemptId: string }
  | { state: "unavailable"; sessionId: string; reason: string }
  | { state: "uncertain"; sessionId: string; attemptId: string; reason: string };

type ResumeCoordinatorOptions = {
  history: {
    get(id: string): RetainedHistoryRecord | undefined;
    getForProvider?(provider: ResumeProviderID, id: string): RetainedHistoryRecord | undefined;
    isSuppressed(provider: "claude_code" | "codex", ids: readonly string[] | string): boolean;
  };
  /** Legacy single-provider injection retained for Claude tests/callers. */
  provider?: ResumeProviderAdapter;
  providers?: Partial<Record<ResumeProviderID, ResumeProviderAdapter>>;
  helper: ResumeNativeController;
  attempts: ResumeAttemptStore;
  focusLive(session: DiscoveredProviderSession): Promise<void>;
  onMatched?(record: RetainedHistoryRecord): void;
};

/** Keep delayed provider startup outside the prepared live-focus action path. */
const resumeReconciliationPollDelaysMs = [25, 50, 100] as const;

/** One cold coordinator, intentionally outside the live focus action queue. */
export class ResumeCoordinator {
  private readonly inFlight = new Map<string, Promise<ResumeResult>>();

  constructor(private readonly options: ResumeCoordinatorOptions) {}

  resumeSession(sessionId: string): Promise<ResumeResult> {
    const record = this.options.history.get(sessionId);
    if (!record || !record.closedAt) {
      return Promise.resolve({ state: "unavailable", sessionId, reason: "This conversation is not closed History." });
    }
    const provider = this.providerFor(record.provider);
    if (!provider) {
      return Promise.resolve({ state: "unavailable", sessionId, reason: "This provider is not supported for Ghostty resume." });
    }
    if (this.options.history.isSuppressed(record.provider, [record.id, record.canonicalId, ...(record.aliases ?? [])])) {
      return Promise.resolve({ state: "unavailable", sessionId, reason: "This session was removed from Agent Visor History." });
    }
    const canonicalId = record.canonicalId;
    const key = attemptKey(record.provider, canonicalId);
    const existing = this.inFlight.get(key);
    if (existing) {
      const attempt = this.options.attempts.get(record.provider, canonicalId);
      return Promise.resolve({
        state: "joined",
        sessionId,
        attemptId: attempt?.attemptId ?? "unknown",
      });
    }
    const operation = this.perform(record, provider);
    this.inFlight.set(key, operation);
    void operation.then(() => undefined, () => undefined).finally(() => {
      if (this.inFlight.get(key) === operation) this.inFlight.delete(key);
    });
    return operation;
  }

  private async perform(record: RetainedHistoryRecord, provider: ResumeProviderAdapter): Promise<ResumeResult> {
    const liveness = await provider.resumeLiveness(record).catch(() => ({
      state: "unknown" as const,
      reason: `Fresh ${record.provider} liveness is unavailable.`,
    }));
    if (liveness.state === "live") {
      try {
        await this.options.focusLive(liveness.session);
        return { state: "focused", sessionId: record.id };
      } catch (error) {
        return { state: "unavailable", sessionId: record.id, reason: errorMessage(error, "Exact session focus is unavailable.") };
      }
    }
    if (liveness.state === "unknown") {
      return { state: "unavailable", sessionId: record.id, reason: liveness.reason };
    }
    const attemptID = randomUUID();
    const nonce = randomNonce();
    const preflightTarget = provider.resumeTarget(record, attemptID, nonce);
    if (preflightTarget.state !== "eligible") {
      return { state: "unavailable", sessionId: record.id, reason: preflightTarget.reason };
    }
    const claim = this.options.attempts.claim(record.id, record.canonicalId, record.provider);
    if (claim.state === "unavailable") {
      return { state: "unavailable", sessionId: record.id, reason: claim.reason };
    }
    if (claim.state === "join" || claim.state === "blocked") {
      return claim.state === "join"
        ? { state: "joined", sessionId: record.id, attemptId: claim.attempt.attemptId }
        : { state: "uncertain", sessionId: record.id, attemptId: claim.attempt.attemptId,
          reason: claim.attempt.reason ?? "A previous resume attempt is unresolved." };
    }
    const attempt = claim.attempt;
    if (!this.historyStillAuthorizes(record)) {
      const reason = "This session was removed from Agent Visor History before dispatch.";
      this.options.attempts.update(record.canonicalId, "unavailable", { reason }, record.provider);
      return { state: "unavailable", sessionId: record.id, reason };
    }
    // Bind the native request to the durable claim identity. The preflight
    // above only validates the provider references; dispatch must never use a
    // correlation ID that was not written to the journal first.
    const targetResult = provider.resumeTarget(record, attempt.attemptId, nonce);
    if (targetResult.state !== "eligible") {
      const reason = targetResult.reason;
      this.options.attempts.update(record.canonicalId, "unavailable", { reason }, record.provider);
      return { state: "unavailable", sessionId: record.id, reason };
    }
    let dispatch: NativeHelperGhosttyResumeDispatch;
    try {
      dispatch = await this.options.helper.openGhosttyResume(targetResult.target);
    } catch (error) {
      const reason = errorMessage(error, "Ghostty resume dispatch is uncertain.");
      this.options.attempts.update(record.canonicalId, "unknown", { reason }, record.provider);
      return { state: "uncertain", sessionId: record.id, attemptId: attempt.attemptId, reason };
    }
    if (dispatch.attemptId !== attempt.attemptId || dispatch.sessionId !== targetResult.target.sessionId
      || dispatch.provider !== nativeProviderFor(provider) || dispatch.nonce !== targetResult.target.nonce) {
      const reason = "Ghostty returned an invalid resume receipt.";
      this.options.attempts.update(record.canonicalId, "unknown", { reason }, record.provider);
      return { state: "uncertain", sessionId: record.id, attemptId: attempt.attemptId, reason };
    }
    if (!this.options.attempts.update(record.canonicalId, "dispatched", { dispatch }, record.provider)) {
      return { state: "uncertain", sessionId: record.id, attemptId: attempt.attemptId,
        reason: "Resume dispatch state could not be saved." };
    }
    let reconciliation: ResumeReconciliation;
    try {
      reconciliation = await this.reconcileAfterDispatch(record, dispatch, provider);
    } catch (error) {
      const reason = errorMessage(error, `${resumeProviderName(record.provider)} resume identity is still unavailable.`);
      this.options.attempts.update(record.canonicalId, "unknown", { reason }, record.provider);
      return { state: "uncertain", sessionId: record.id, attemptId: attempt.attemptId, reason };
    }
    if (reconciliation.state !== "matched" || reconciliation.sessionId !== record.canonicalId) {
      const reason = reconciliation.state === "matched"
        ? `The resumed ${resumeProviderName(record.provider)} conversation identity did not match the retained row.`
        : reconciliation.reason ?? `The resumed ${resumeProviderName(record.provider)} conversation could not be matched.`;
      this.options.attempts.update(record.canonicalId, reconciliation.state === "unavailable" ? "unavailable" : "unknown", { reason }, record.provider);
      return { state: reconciliation.state === "unavailable" ? "unavailable" : "uncertain",
        sessionId: record.id, attemptId: attempt.attemptId, reason };
    }
    const terminal = reconciliation.terminal;
    if (!terminal) {
      const reason = `The resumed ${resumeProviderName(record.provider)} surface could not be linked exactly.`;
      this.options.attempts.update(record.canonicalId, "unknown", { reason }, record.provider);
      return { state: "uncertain", sessionId: record.id, attemptId: attempt.attemptId, reason };
    }
    try {
      await this.options.helper.focusGhosttyTerminal(terminal);
    } catch (error) {
      const reason = errorMessage(error, `The resumed ${resumeProviderName(record.provider)} surface could not be focused.`);
      this.options.attempts.update(record.canonicalId, "unknown", { reason }, record.provider);
      return { state: "uncertain", sessionId: record.id, attemptId: attempt.attemptId, reason };
    }
    if (!this.options.attempts.update(record.canonicalId, "matched", {}, record.provider)) {
      return { state: "uncertain", sessionId: record.id, attemptId: attempt.attemptId,
        reason: "Resume completion state could not be saved." };
    }
    this.options.onMatched?.(record);
    return { state: "matched", sessionId: record.id, attemptId: attempt.attemptId };
  }

  /**
   * Claude may publish its exact UUID after the native Ghostty receipt. Poll
   * only the same attempt while the adapter says startup identity is pending;
   * this coordinator is intentionally separate from the normal live-action
   * queue, and no poll may create or dispatch another frontend.
   */
  private async reconcileAfterDispatch(
    record: RetainedHistoryRecord,
    dispatch: NativeHelperGhosttyResumeDispatch,
    provider: ResumeProviderAdapter,
  ): Promise<ResumeReconciliation> {
    let reconciliation = await provider.reconcileResume(record, dispatch);
    for (const delayMs of resumeReconciliationPollDelaysMs) {
      if (!isStartupReconciliationPending(reconciliation)) return reconciliation;
      await delay(delayMs);
      reconciliation = await provider.reconcileResume(record, dispatch);
    }
    return reconciliation;
  }

  private historyStillAuthorizes(record: RetainedHistoryRecord): boolean {
    const ids = [record.id, record.canonicalId, ...(record.aliases ?? [])];
    if (this.options.history.isSuppressed(record.provider, ids)) return false;
    const getCurrent = this.options.history.getForProvider
      ? (id: string) => this.options.history.getForProvider!(record.provider, id)
      : (id: string) => this.options.history.get(id);
    const current = getCurrent(record.id) ?? getCurrent(record.canonicalId);
    return current?.provider === record.provider
      && current.canonicalId === record.canonicalId
      && current.closedAt !== undefined;
  }

  private providerFor(provider: ResumeProviderID): ResumeProviderAdapter | undefined {
    return this.options.providers?.[provider]
      ?? (this.options.provider?.id === provider ? this.options.provider : undefined);
  }
}

function normalizeAttempt(value: unknown): ResumeAttempt | undefined {
  if (!isRecord(value) || value.version !== 1
    || (value.provider !== "claude_code" && value.provider !== "codex")
    || typeof value.attemptId !== "string" || !value.attemptId
    || typeof value.sessionId !== "string" || !value.sessionId
    || typeof value.canonicalId !== "string" || !value.canonicalId
    || !["claimed", "dispatched", "matched", "unknown", "unavailable"].includes(String(value.state))
    || typeof value.claimedAt !== "string" || !Number.isFinite(Date.parse(value.claimedAt))
    || typeof value.updatedAt !== "string" || !Number.isFinite(Date.parse(value.updatedAt))) return undefined;
  if (value.attemptId.length > 128 || value.sessionId.length > 512 || value.canonicalId.length > 1_024) {
    return undefined;
  }
  const dispatch = isRecord(value.dispatch)
    ? nativeHelperGhosttyResumeDispatchSchema.safeParse(value.dispatch)
    : undefined;
  if (value.dispatch !== undefined && (!dispatch || !dispatch.success)) return undefined;
  const provider = value.provider as ResumeProviderID;
  const expectedNativeProvider = provider === "codex" ? "codex_cli" : "claude_code";
  if (dispatch?.success && dispatch.data.provider !== expectedNativeProvider) return undefined;
  return {
    version: 1,
    provider,
    attemptId: value.attemptId,
    sessionId: value.sessionId,
    canonicalId: value.canonicalId,
    state: value.state as ResumeAttemptState,
    claimedAt: new Date(value.claimedAt).toISOString(),
    updatedAt: new Date(value.updatedAt).toISOString(),
    ...(dispatch?.success ? { dispatch: dispatch.data } : {}),
    ...(typeof value.reason === "string" && value.reason.length <= 1_024 ? { reason: value.reason } : {}),
  };
}

function attemptKey(provider: ResumeProviderID, canonicalId: string): string {
  return `${provider}\u0000${canonicalId}`;
}

function nativeProviderFor(provider: ResumeProviderAdapter): ResumeNativeProvider {
  return provider.nativeProvider ?? (provider.id === "codex" ? "codex_cli" : "claude_code");
}

function resumeProviderName(provider: ResumeProviderID): string {
  return provider === "codex" ? "Codex" : "Claude";
}

function isMissingFile(error: unknown): boolean {
  return isRecord(error) && error.code === "ENOENT";
}

function randomNonce(): string {
  return randomUUID().replaceAll("-", "").slice(0, 32);
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback;
}

function isStartupReconciliationPending(reconciliation: ResumeReconciliation): boolean {
  return reconciliation.state === "pending"
    || (reconciliation.state === "unknown" && reconciliation.retryable === true);
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Keep this import-visible for adapter implementations that classify legacy rows.
export type ResumeEligibilityReason = RetainedHistoryResumeUnavailableReason | "unknown_liveness";
