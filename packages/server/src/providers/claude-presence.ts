import type { SessionSummary } from "@agent-visor/protocol";
import type { ClaudeAgentInventoryRow } from "./claude-agent-inventory.js";
import type { GhosttyTerminalView } from "./environment.js";

/** Counts only: never include terminal titles, paths, IDs, or native error text. */
export type ClaudePresenceReport = {
  status: "not_required" | "inventory_unavailable" | "reader_unavailable" | "read_failed" | "read_succeeded";
  parkedApplications: number;
  terminalViews: number;
  conversationTitles: number;
  overviewTitles: number;
  unrecognizedTitles: number;
  matchedConversations: number;
};

type Evidence = {
  reason: NonNullable<SessionSummary["claudePresence"]>;
  displayed?: GhosttyTerminalView;
};

/** One observation supplies both pill presence and exact click routing. No stale view cache. */
export async function resolveClaudePresence(
  rows: readonly ClaudeAgentInventoryRow[],
  authoritative: boolean,
  applications: ReadonlyMap<number, string | undefined>,
  readViews?: (conversationTitles: readonly string[]) => Promise<GhosttyTerminalView[]>,
): Promise<{ jobs: Map<string, Evidence>; report: ClaudePresenceReport }> {
  const report: ClaudePresenceReport = {
    status: !applications.size ? "not_required"
      : !authoritative ? "inventory_unavailable" : "reader_unavailable",
    parkedApplications: applications.size, terminalViews: 0,
    conversationTitles: 0, overviewTitles: 0, unrecognizedTitles: 0, matchedConversations: 0,
  };
  let views: GhosttyTerminalView[] = [];
  if (authoritative && applications.size && readViews) {
    try {
      views = await readViews([...new Set(rows.flatMap(row => row.name ? [row.name] : []))]);
      report.status = "read_succeeded";
    }
    catch { report.status = "read_failed"; }
  }
  const jobs = new Map<string, Evidence>(rows.map((row) => [row.id!, {
    reason: report.status === "not_required" || report.status === "read_succeeded"
      ? "not_displayed" : report.status,
  }]));
  const overviewDirectories = new Set<string>();
  const otherDirectories = new Set<string>();
  const ambiguousJobs = new Set<string>();
  const changedDirectories = new Set<string>();
  for (const view of views) {
    if (!applications.has(view.applicationPID)) continue;
    const expectedInstance = applications.get(view.applicationPID);
    if (!expectedInstance || expectedInstance !== view.processStartToken) {
      changedDirectories.add(view.cwd);
      continue;
    }
    report.terminalViews++;
    // The activity indicator is presentation only; name + directory identify a job.
    const name = /^[✳◐◑] /.test(view.title) ? view.title.slice(2)
      : view.titleUpdatesEnabled === true || view.viewMode === "conversation" ? view.title : "";
    if (view.viewMode === "overview" || /(?:^| · )claude agents$/.test(name || view.title)) {
      report.overviewTitles++;
      overviewDirectories.add(view.cwd);
      continue;
    }
    otherDirectories.add(view.cwd);
    if (!name || name === "Claude Code") {
      report.unrecognizedTitles++;
      for (const row of rows) {
        if (row.cwd === view.cwd && !jobs.get(row.id!)?.displayed) {
          jobs.set(row.id!, { reason: "unrecognized_title" });
        }
      }
      continue;
    }
    report.conversationTitles++;
    const matches = rows.filter((row) => row.name === name && row.cwd === view.cwd);
    if (matches.length === 1) jobs.set(matches[0]!.id!, { reason: "conversation", displayed: view });
    else for (const row of matches) ambiguousJobs.add(row.id!);
  }
  for (const row of rows) {
    if (ambiguousJobs.has(row.id!) && !jobs.get(row.id!)?.displayed) {
      jobs.set(row.id!, { reason: "ambiguous_title" });
    } else if (changedDirectories.has(row.cwd) && !jobs.get(row.id!)?.displayed) {
      jobs.set(row.id!, { reason: "process_changed" });
    } else if (overviewDirectories.has(row.cwd) && !otherDirectories.has(row.cwd)) {
      jobs.set(row.id!, { reason: "overview" });
    }
  }
  report.matchedConversations = [...jobs.values()].filter((evidence) => evidence.displayed).length;
  return { jobs, report };
}
