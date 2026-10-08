import { appendFile, chmod, mkdir, rename, stat } from "node:fs/promises";
import path from "node:path";
import type { ClaudePresenceReport } from "./providers/claude.js";

const statuses = new Set(["not_required", "inventory_unavailable", "reader_unavailable", "read_failed", "read_succeeded"]);
const count = (value: number) => Number.isInteger(value) && value >= 0 ? Math.min(value, 16_384) : 0;

/** Bounded local transitions; ambient polling never stores titles, paths, IDs, or errors. */
export class ClaudePresenceDiagnostics {
  private writes = Promise.resolve();
  private queued = 0;
  private previous = "";

  constructor(private readonly dataRoot: string) {}

  record(report: ClaudePresenceReport): void {
    if (!statuses.has(report.status) || this.queued >= 16) return;
    const safe = {
      status: report.status, parkedApplications: count(report.parkedApplications),
      terminalViews: count(report.terminalViews), conversationTitles: count(report.conversationTitles),
      overviewTitles: count(report.overviewTitles), unrecognizedTitles: count(report.unrecognizedTitles),
      matchedConversations: count(report.matchedConversations),
    };
    const key = JSON.stringify(safe);
    if (key === this.previous) return;
    this.previous = key;
    const line = JSON.stringify({ observedAt: new Date().toISOString(), ...safe }) + "\n";
    this.queued++;
    this.writes = this.writes.then(async () => {
      const directory = path.join(this.dataRoot, "diagnostics");
      const file = path.join(directory, "claude-presence.jsonl");
      await mkdir(directory, { recursive: true, mode: 0o700 });
      let bytes = 0;
      try { bytes = (await stat(file)).size; } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
      if (bytes + Buffer.byteLength(line) > 65_536) await rename(file, file + ".previous");
      await appendFile(file, line, { mode: 0o600 });
      await chmod(file, 0o600);
    }).catch(() => {
      if (this.previous === key) this.previous = "";
      // A diagnostic failure must not interrupt or retry session discovery.
    }).finally(() => { this.queued--; });
  }

  async flush(): Promise<void> { await this.writes; }
}
