import path from "node:path";
import type { DiscoveredProviderSession, ProviderAdapter, ProviderID } from "../sessions.js";
import type { ProviderEnvironment } from "./environment.js";
import { isRecord, iso } from "./shared.js";

const threadsSQL = `
select hex(thread_id) as thread_id, session_id, agent_id,
       substr(coalesce(title, ''), 1, 500) as title,
       substr(coalesce(title_override, ''), 1, 500) as title_override,
       updated_at, interacted_at, main_worktree_paths, archived
from sidebar_threads
order by coalesce(interacted_at, updated_at) desc
limit 500`;

export class ZedProvider implements ProviderAdapter {
  readonly id = "zed" as const;
  private lastRows: unknown[] = [];

  constructor(private readonly environment: ProviderEnvironment) {}

  async discover(): Promise<DiscoveredProviderSession[]> {
    const processes = await this.environment.processes();
    const zedRunning = processes.some((process) => {
      const identity = `${process.command} ${process.arguments}`.toLowerCase();
      return identity.includes("/zed") && identity.includes(".app/");
    });
    if (!zedRunning) return [];
    const database = await zedDatabase(this.environment);
    if (!database) return [];
    const queried = await this.environment.sqlite(database, threadsSQL);
    if (queried.length > 0) this.lastRows = queried;
    const values = queried.length > 0 ? queried : this.lastRows;
    const results: DiscoveredProviderSession[] = [];

    for (const value of values) {
      if (!isRecord(value) || number(value.archived) !== 0) continue;
      const id = string(value.session_id);
      const provider = providerID(string(value.agent_id));
      const cwd = string(value.main_worktree_paths).split(/\r?\n/).find(Boolean) ?? "";
      const touched = laterDate(string(value.interacted_at), string(value.updated_at));
      if (!id || !provider || !cwd || !touched) continue;
      if (this.environment.now().valueOf() - touched.valueOf() > this.environment.observedWindowMs) {
        continue;
      }
      results.push({
        id,
        provider,
        title: string(value.title_override) || string(value.title) || undefined,
        subtitle: `${providerName(provider)} session hosted by Zed`,
        cwd,
        owner: "Zed",
        section: "history",
        updatedAt: iso(touched),
        canOpenOwner: true,
        canEnterChat: provider !== "auggie",
        authority: 2,
      });
    }
    return results;
  }
}

async function zedDatabase(environment: ProviderEnvironment): Promise<string | undefined> {
  const scopes = ["0-stable", "0-preview", "0-nightly", "0-dev"];
  let best: { path: string; modifiedAt: number } | undefined;
  for (const scope of scopes) {
    const candidate = path.join(
      environment.home,
      "Library", "Application Support", "Zed", "db", scope, "db.sqlite",
    );
    const database = await environment.stamp(candidate);
    if (!database) continue;
    const wal = await environment.stamp(`${candidate}-wal`);
    const modifiedAt = Math.max(database.modifiedAt.valueOf(), wal?.modifiedAt.valueOf() ?? 0);
    if (!best || modifiedAt > best.modifiedAt) best = { path: candidate, modifiedAt };
  }
  return best?.path;
}

function providerID(identifier: string): ProviderID | undefined {
  let normalized = identifier.trim().toLowerCase();
  for (const suffix of ["-acp", "-agent", "_acp"]) {
    if (normalized.endsWith(suffix)) normalized = normalized.slice(0, -suffix.length);
  }
  if (["claude", "claude-code", "claudecode"].includes(normalized)) return "claude_code";
  if (["codex", "pi", "cursor", "auggie"].includes(normalized)) return normalized as ProviderID;
  return undefined;
}

function providerName(provider: ProviderID): string {
  return provider === "claude_code" ? "Claude Code"
    : provider[0]!.toUpperCase() + provider.slice(1);
}

function laterDate(first: string, second: string): Date | undefined {
  const dates = [first, second]
    .filter(Boolean)
    .map((value) => new Date(value))
    .filter((value) => !Number.isNaN(value.valueOf()));
  return dates.sort((left, right) => right.valueOf() - left.valueOf())[0];
}

function string(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function number(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
