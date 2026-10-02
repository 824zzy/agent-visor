import { access, constants } from "node:fs/promises";
import path from "node:path";
import { machineWork, runProcess, type ProcessResult } from "../machine.js";

export const claudeAgentRefreshIntervalMs = 3_000;
export const claudeAgentCommandDeadlineMs = 2_000;
export const claudeAgentMaxOutputBytes = 1_048_576;
export const claudeAgentStaleGraceMs = 30_000;
export const claudeAgentUnsupportedRetryMs = 30_000;

const claudeAgentCommand = ["agents", "--json", "--all"] as const;
const maxRows = 2_048;
const maxStringLength = 4_096;

export type ClaudeAgentInventoryRow = {
  /** Background rows have a short job id; interactive rows do not. */
  id?: string;
  kind: string;
  cwd: string;
  startedAt: number;
  name?: string;
  sessionId?: string;
  pid?: number;
  state?: string;
  status?: string;
  waitingFor?: string;
  /** Optional process metadata kept only for filtering internal rows. */
  entrypoint?: string;
  source?: string;
  agent?: string;
  spare?: boolean;
};

type FetchWindow = {
  startedAt: number;
  completedAt: number;
};

export type ClaudeAgentInventorySuccess = FetchWindow & {
  kind: "success";
  root: string;
  rows: readonly ClaudeAgentInventoryRow[];
  /** Identity can remain usable after live state has expired. */
  freshness: "fresh" | "stale";
  authoritative: boolean;
};

export type ClaudeAgentInventoryUnsupported = FetchWindow & {
  kind: "unsupported";
  root: string;
  reason: "config_root" | "executable_missing" | "command_unavailable";
  lastGood?: ClaudeAgentInventorySuccess;
};

export type ClaudeAgentInventoryFailure = FetchWindow & {
  kind: "failure";
  root: string;
  reason: "timed_out" | "process_failed" | "invalid_json" | "invalid_rows";
  lastGood?: ClaudeAgentInventorySuccess;
};

export type ClaudeAgentInventoryResult =
  | ClaudeAgentInventorySuccess
  | ClaudeAgentInventoryUnsupported
  | ClaudeAgentInventoryFailure;

export type ClaudeAgentInventoryRunner = (
  executable: string,
  arguments_: readonly string[],
  options: { deadlineMs: number; maxOutputBytes: number },
) => Promise<ProcessResult>;

export type ClaudeAgentInventoryOptions = {
  home: string;
  /** The inherited value. An empty value means the default root. */
  configDir?: string;
  now?: () => Date;
  refreshIntervalMs?: number;
  staleGraceMs?: number;
  unsupportedRetryMs?: number;
  resolveExecutable?: () => Promise<string | undefined>;
  run?: ClaudeAgentInventoryRunner;
};

/**
 * Read Claude's supported agent-view inventory without making it authoritative
 * until the response has passed the complete shape checks below. The reader is
 * intentionally dormant: discovery decides when to call it and how to merge
 * its rows with the existing transcript and process evidence.
 */
export class ClaudeAgentInventory {
  private readonly root: string;
  private readonly configSupported: boolean;
  private readonly clock: () => Date;
  private readonly refreshInterval: number;
  private readonly staleGrace: number;
  private readonly unsupportedRetry: number;
  private readonly resolveExecutable: () => Promise<string | undefined>;
  private readonly run: ClaudeAgentInventoryRunner;
  private cached: ClaudeAgentInventoryResult | undefined;
  private inFlight: Promise<ClaudeAgentInventoryResult> | undefined;
  private retryAt = 0;

  constructor(options: ClaudeAgentInventoryOptions) {
    this.root = path.resolve(options.home, ".claude");
    this.clock = options.now ?? (() => new Date());
    this.refreshInterval = options.refreshIntervalMs ?? claudeAgentRefreshIntervalMs;
    this.staleGrace = options.staleGraceMs ?? claudeAgentStaleGraceMs;
    this.unsupportedRetry = options.unsupportedRetryMs ?? claudeAgentUnsupportedRetryMs;
    const inheritedConfigDir = options.configDir ?? process.env.CLAUDE_CONFIG_DIR ?? "";
    this.configSupported = inheritedConfigDir.trim() === ""
      || (path.isAbsolute(inheritedConfigDir) && path.resolve(inheritedConfigDir) === this.root);
    this.resolveExecutable = options.resolveExecutable
      ?? (() => resolveClaudeExecutable(options.home));
    this.run = options.run ?? ((executable, arguments_, runOptions) => machineWork.run(
      () => runProcess(executable, [...arguments_], runOptions),
    ));
  }

  /**
   * Return a recent snapshot immediately when possible, refreshing in the
   * background. The first read waits for one bounded command so callers can
   * distinguish "empty" from "not available". Later reads never make a
   * provider refresh wait on Claude's process.
   */
  async read(): Promise<ClaudeAgentInventoryResult> {
    const now = this.clock().valueOf();
    if (!this.configSupported) {
      return this.cached ?? this.unsupported(now, now, "config_root");
    }

    if (this.cached && now - this.cached.completedAt < this.refreshInterval) {
      return this.cachedView(now);
    }
    if (this.cached?.kind === "unsupported" && now < this.retryAt) {
      return this.cachedView(now);
    }
    if (this.inFlight) {
      return this.cached ? this.cachedView(now) : this.inFlight;
    }

    const refresh = this.refresh();
    if (this.cached) {
      void refresh;
      return this.cachedView(now);
    }
    return refresh;
  }

  /** Force one bounded read for an explicit user navigation request. */
  refreshNow(): Promise<ClaudeAgentInventoryResult> {
    if (this.inFlight) return this.inFlight;
    return this.refresh();
  }

  private refresh(): Promise<ClaudeAgentInventoryResult> {
    const pending = this.fetch();
    this.inFlight = pending;
    void pending.then((result) => {
      if (this.inFlight === pending) this.inFlight = undefined;
      this.cached = result;
      this.retryAt = result.kind === "unsupported"
        ? result.completedAt + this.unsupportedRetry : 0;
    }, () => {
      if (this.inFlight === pending) this.inFlight = undefined;
    });
    return pending;
  }

  private async fetch(): Promise<ClaudeAgentInventoryResult> {
    const startedAt = this.clock().valueOf();
    if (!this.configSupported) return this.unsupported(startedAt, this.clock().valueOf(), "config_root");

    let executable: string | undefined;
    try {
      executable = await this.resolveExecutable();
    } catch {
      return this.unsupported(startedAt, this.clock().valueOf(), "executable_missing");
    }
    if (!executable || !path.isAbsolute(executable)) {
      return this.unsupported(startedAt, this.clock().valueOf(), "executable_missing");
    }

    let result: ProcessResult;
    try {
      result = await this.run(executable, claudeAgentCommand, {
        deadlineMs: claudeAgentCommandDeadlineMs,
        maxOutputBytes: claudeAgentMaxOutputBytes,
      });
    } catch {
      return this.failure(startedAt, this.clock().valueOf(), "process_failed");
    }
    const completedAt = this.clock().valueOf();
    if (result.status === "timed_out") {
      return this.failure(startedAt, completedAt, "timed_out");
    }
    if (result.status !== "success") {
      if (isUnsupportedCommand(result)) {
        return this.unsupported(startedAt, completedAt, "command_unavailable");
      }
      return this.failure(startedAt, completedAt, "process_failed");
    }

    let value: unknown;
    try {
      value = JSON.parse(result.stdout);
    } catch {
      return this.failure(startedAt, completedAt, "invalid_json");
    }
    const rows = parseRows(value);
    if (!rows) return this.failure(startedAt, completedAt, "invalid_rows");
    return {
      kind: "success", root: this.root, rows, startedAt, completedAt,
      freshness: "fresh", authoritative: true,
    };
  }

  private cachedView(now: number): ClaudeAgentInventoryResult {
    const cached = this.cached;
    if (!cached) throw new Error("Claude inventory cache is empty");
    if (cached.kind === "success") return snapshotView(cached, now, this.staleGrace, this.refreshInterval);
    if (!cached.lastGood) return cached;
    return {
      ...cached,
      lastGood: snapshotView(cached.lastGood, now, this.staleGrace, this.refreshInterval),
    };
  }

  private unsupported(
    startedAt: number,
    completedAt: number,
    reason: ClaudeAgentInventoryUnsupported["reason"],
  ): ClaudeAgentInventoryUnsupported {
    return {
      kind: "unsupported", root: this.root, reason, startedAt, completedAt,
      ...(reason !== "config_root"
        ? this.cached?.kind === "success"
          ? { lastGood: snapshotView(this.cached, completedAt, this.staleGrace, this.refreshInterval) }
          : this.cached?.lastGood
            ? { lastGood: snapshotView(this.cached.lastGood, completedAt, this.staleGrace, this.refreshInterval) }
            : {}
        : {}),
    };
  }

  private failure(
    startedAt: number,
    completedAt: number,
    reason: ClaudeAgentInventoryFailure["reason"],
  ): ClaudeAgentInventoryFailure {
    const lastGood = this.cached?.kind === "success" ? this.cached : this.cached?.lastGood;
    const current = { kind: "failure" as const, root: this.root, reason, startedAt, completedAt };
    return lastGood
      ? { ...current, lastGood: snapshotView(lastGood, completedAt, this.staleGrace, this.refreshInterval) }
      : current;
  }
}

export async function resolveClaudeExecutable(home: string): Promise<string | undefined> {
  for (const candidate of trustedClaudeExecutableCandidates(home)) {
    try {
      await access(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Try the next known installation. Never use a path from inventory data.
    }
  }
  return undefined;
}

export function trustedClaudeExecutableCandidates(home: string): readonly string[] {
  return [
    path.join(home, ".local", "bin", "claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
  ];
}

function parseRows(value: unknown): ClaudeAgentInventoryRow[] | undefined {
  if (!Array.isArray(value) || value.length > maxRows) return undefined;
  const rows: ClaudeAgentInventoryRow[] = [];
  for (const entry of value) {
    if (!isRecord(entry)) return undefined;
    const kind = requiredString(entry.kind);
    const cwd = requiredString(entry.cwd);
    const startedAt = entry.startedAt;
    const id = requiredString(entry.id);
    const state = requiredString(entry.state);
    if (kind === undefined || cwd === undefined
      || typeof startedAt !== "number" || !Number.isFinite(startedAt) || startedAt <= 0) {
      return undefined;
    }
    if (kind === "background" && (id === undefined || state === undefined)) return undefined;
    const row: ClaudeAgentInventoryRow = { kind, cwd, startedAt };
    for (const key of [
      "id", "name", "sessionId", "state", "status", "waitingFor", "entrypoint", "source", "agent",
    ] as const) {
      const parsed = optionalFieldString(entry, key);
      if (!parsed.valid) return undefined;
      if (parsed.value !== undefined) row[key] = parsed.value;
    }
    if ("spare" in entry) {
      if (typeof entry.spare !== "boolean") return undefined;
      row.spare = entry.spare;
    }
    const pid = entry.pid;
    if (pid !== undefined) {
      if (typeof pid !== "number" || !Number.isInteger(pid) || pid <= 0) return undefined;
      row.pid = pid;
    }
    rows.push(row);
  }
  return rows;
}

function requiredString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed && trimmed.length <= maxStringLength ? trimmed : undefined;
}

function optionalFieldString(
  entry: Record<string, unknown>,
  key: "id" | "name" | "sessionId" | "state" | "status" | "waitingFor"
    | "entrypoint" | "source" | "agent",
): { valid: boolean; value?: string } {
  if (!(key in entry)) return { valid: true };
  const value = entry[key];
  const parsed = requiredString(value);
  return parsed === undefined ? { valid: false } : { valid: true, value: parsed };
}

function isUnsupportedCommand(result: Extract<ProcessResult, { status: "failed" }>): boolean {
  const stderr = result.stderr.toLowerCase();
  return /unknown command|unknown option|unrecognized option|invalid option|not a command/.test(stderr)
    || /usage:\s*claude(?:\s|$)/.test(stderr);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function snapshotView(
  snapshot: ClaudeAgentInventorySuccess,
  now: number,
  staleGraceMs: number,
  refreshIntervalMs: number,
): ClaudeAgentInventorySuccess {
  const age = Math.max(0, now - snapshot.completedAt);
  return {
    ...snapshot,
    freshness: age < refreshIntervalMs ? "fresh" : "stale",
    authoritative: age < staleGraceMs,
  };
}
