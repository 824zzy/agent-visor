import path from "node:path";
import { TRANSCRIPT_STALE_CEILING_MS, type NativeHelperTerminalTarget } from "@agent-visor/protocol";
import type { ProviderAdapter, DiscoveredProviderSession } from "../sessions.js";
import type { FileStamp, ProcessRecord, ProviderEnvironment } from "./environment.js";
import type {
  ClaudeAgentInventoryRow,
  ClaudeAgentInventoryResult,
} from "./claude-agent-inventory.js";
import { ClaudeDesktopSessions } from "./claude-desktop.js";
import { resolveClaudePresence, type ClaudePresenceReport } from "./claude-presence.js";
export type { ClaudePresenceReport } from "./claude-presence.js";
import {
  applicationTargetForProcess, isRecord, iso, ownerForProcess, processInstanceToken,
  terminalTargetForProcess,
} from "./shared.js";

const terminalStatuses = new Set([
  "ended", "exited", "closed", "deactivated", "inactive", "stopped", "terminated",
]);

// Claude session metadata distinguishes an active turn from a session that is
// waiting for the next prompt. Keep this allowlist narrow: an unfamiliar
// status must not make a live terminal writable just because its process is
// present.
const readyStatuses = new Set([
  "idle", "ready", "waiting", "waiting_for_input", "awaiting_input",
]);
const knownInventoryStates = new Set(["working", "blocked", "done", "failed", "stopped"]);
const removedConversationRetentionMs = TRANSCRIPT_STALE_CEILING_MS;
const maxRemovedConversationIds = 512;

type TranscriptSummary = {
  customTitle: string;
  firstUser: string;
  completed: boolean;
  lifecycle?: DiscoveredProviderSession["claudeLifecycle"];
};
const emptySummary: TranscriptSummary = { customTitle: "", firstUser: "", completed: false };

type InventorySnapshot = {
  rows: readonly ClaudeAgentInventoryRow[];
  authoritative: boolean;
  observedAt: number;
};
type InventoryRead = {
  snapshot?: InventorySnapshot;
  mode: "canonical" | "blocked" | "legacy";
  /** A failed/unsupported read can retain a last-good snapshot during grace. */
  outage: boolean;
};

type BackgroundMetadata = {
  sessionID?: string;
  process?: ProcessRecord;
};

type FailureLifecycle = {
  state: string;
  alert: boolean;
  acknowledged: boolean;
};

export class ClaudeProvider implements ProviderAdapter {
  readonly id = "claude_code" as const;
  private readonly summaries = new Map<string, { size: number; modifiedAt: number; summary: TranscriptSummary }>();
  private readonly desktopSessions: ClaudeDesktopSessions;
  private hiddenSessionIdsForPublication: ReadonlySet<string> = new Set();
  /** In-memory lifecycle evidence keeps startup failures quiet and watched failures actionable. */
  private readonly failureLifecycleBySession = new Map<string, FailureLifecycle>();
  private inventoryBackgroundIds: ReadonlySet<string> = new Set();
  /** Tombstones suppress late hooks until a fresh row or interactive record proves reuse. */
  private removedConversationIds: ReadonlyMap<string, number> = new Map();

  constructor(
    private readonly environment: ProviderEnvironment,
    private readonly reportPresence?: (report: ClaudePresenceReport) => void,
  ) {
    this.desktopSessions = new ClaudeDesktopSessions(environment);
  }

  async discover(forceInventory = false): Promise<DiscoveredProviderSession[]> {
    const directory = path.join(this.environment.home, ".claude", "sessions");
    const processes = forceInventory && this.environment.processesFresh
      ? await this.environment.processesFresh()
      : await this.environment.processes();
    const byPID = new Map(processes.map((process) => [process.pid, process]));
    const inventoryRead = await this.readInventory(forceInventory);
    const inventory = inventoryRead.snapshot;
    const inventoryMode = inventoryRead.mode === "canonical" || inventoryRead.mode === "blocked";
    const inventoryRows = new Map(
      (inventory?.rows ?? []).flatMap((row) =>
        isUsableInventoryBackground(row)
          ? [[row.id!.toLowerCase(), row] as const] : []),
    );
    const backgroundMetadata = new Map<string, BackgroundMetadata>();
    const hiddenInventoryJobs = new Set<string>();
    const claudeExecutable = inventoryMode && this.environment.claudeExecutable
      ? await this.environment.claudeExecutable()
      : undefined;
    const results: DiscoveredProviderSession[] = [];
    const transcripts = new Set<string>();
    const desktopProfiles = new Map<string, ReturnType<ClaudeDesktopSessions["read"]>>();
    const spares = new Set<string>();
    const interactiveSessionIds = new Set<string>();
    const parkedSessionIds = new Set<string>();
    const parkedGhosttyApplications = new Map<number, string | undefined>();

    // An attach client need not publish session metadata. Discover the
    // terminal frontend independently; only a current view can expose a job.
    for (const process of processes) {
      if (!process.tty || !isClaudeCommand(process.command, this.environment.home)) continue;
      let ancestor: ProcessRecord | undefined = process;
      const visited = new Set<number>();
      while (ancestor && !visited.has(ancestor.pid)) {
        visited.add(ancestor.pid);
        if (ancestor.command.endsWith("/Ghostty.app/Contents/MacOS/ghostty")) {
          if (!parkedGhosttyApplications.has(ancestor.pid)) {
            parkedGhosttyApplications.set(ancestor.pid, ancestor.processStartToken
              ?? processInstanceToken(ancestor.pid, await this.environment.processStartedAt(ancestor.pid)));
          }
          break;
        }
        ancestor = byPID.get(ancestor.parentPID);
      }
    }

    for (const file of await this.environment.directory(directory)) {
      const match = /^(\d+)\.json$/.exec(file);
      if (!match) continue;
      const pid = Number(match[1]);
      const process = byPID.get(pid);
      if (!process) continue;
      const metadataPath = path.join(directory, file);
      const raw = await this.environment.read(metadataPath, 256 * 1_024);
      if (!raw) continue;

      let metadata: unknown;
      try { metadata = JSON.parse(raw); } catch { continue; }
      if (!isRecord(metadata)) continue;
      const sessionID = string(metadata.sessionId);
      const cwd = string(metadata.cwd);
      const kind = string(metadata.kind);
      const jobId = string(metadata.jobId).toLowerCase();
      const entrypoint = string(metadata.entrypoint).toLowerCase();
      const status = string(metadata.status).toLowerCase();
      // The Claude daemon pre-warms an idle worker for the next background
      // job. It has no conversation until claimed, when Claude drops the flag.
      if (metadata.spare === true) {
        if (sessionID) spares.add(sessionID);
        if (jobId) hiddenInventoryJobs.add(jobId);
        for (const row of inventoryRows.values()) {
          if (row.sessionId?.toLowerCase() === sessionID.toLowerCase() && row.id) {
            hiddenInventoryJobs.add(row.id.toLowerCase());
          }
        }
        continue;
      }
      // The inventory is the canonical source for background jobs. Session
      // metadata can lag, omit a PID, or retain launcher details that no
      // longer describe the worker, so only retain it as enrichment.
      if (inventoryMode && kind === "bg") {
        const row = inventoryRows.get(jobId);
        if (row && !isInternalBackgroundMetadata(entrypoint, cwd)) {
          backgroundMetadata.set(row.id!, {
            ...(fullSessionID(sessionID) ? { sessionID: fullSessionID(sessionID) } : {}),
            process,
          });
          continue;
        }
        // A stale last-good snapshot must not veto a newly observable legacy
        // background route; a complete empty/fresh snapshot and a blocked
        // nondefault root remain fail-closed.
        if (inventoryRead.mode === "blocked" || inventory?.authoritative !== false) continue;
      }
      if (!sessionID || !cwd || (kind !== "interactive" && kind !== "bg")) continue;
      if (entrypoint.startsWith("sdk") || terminalStatuses.has(status)) continue;
      if (cwd.includes(".claude-mem") || cwd.includes("observer-sessions")) continue;
      // A parked host can show either overview or an attached background job.
      // Its own UUID/parkedJobId do not identify that displayed conversation.
      if (kind === "interactive" && metadata.parkedJobId !== undefined) {
        parkedSessionIds.add(sessionID);
        continue;
      }
      const backgroundTarget = kind === "bg"
        ? claudeBackgroundTarget(process, byPID, sessionID, string(metadata.jobId), cwd, entrypoint, this.environment.home)
        : undefined;
      if (kind === "bg" ? !backgroundTarget
        : !isClaudeCommand(process.command, this.environment.home)) continue;

      const transcript = claudeTranscriptPath(this.environment.home, sessionID, cwd);
      transcripts.add(transcript);
      const transcriptStamp = await this.environment.stamp(transcript);
      if (!process.tty && entrypoint.includes("vscode")) {
        if (!transcriptStamp
          || this.environment.now().valueOf() - transcriptStamp.modifiedAt.valueOf()
            > this.environment.observedWindowMs) continue;
      }
      const metadataStamp = await this.environment.stamp(metadataPath);
      const summary = await this.transcriptSummary(transcript, transcriptStamp);
      const owner = process.tty
        ? ownerForProcess(pid, processes)
        : entrypoint.includes("vscode") ? "Cursor" : "Claude";
      const processStartToken = processInstanceToken(
        pid,
        await this.environment.processStartedAt(pid),
      );
      // A background worker's tty is a private daemon PTY, not a visible
      // terminal tab. It must be attached through Claude's CLI instead.
      const terminalTarget = kind === "interactive" ? terminalTargetForProcess(
        process,
        cwd,
        processes,
        processStartToken,
      ) : undefined;
      const applicationTarget = applicationTargetForProcess(process.pid, processes);
      const desktopProfile = !terminalTarget && applicationTarget?.bundleIdentifier === "com.anthropic.claudefordesktop"
        ? entrypoint === "claude-desktop-3p" ? "Claude-3p"
          : entrypoint === "claude-desktop" ? "Claude" : undefined
        : undefined;
      if (desktopProfile && !desktopProfiles.has(desktopProfile)) {
        desktopProfiles.set(desktopProfile, this.desktopSessions.read(desktopProfile));
      }
      const desktopSession = desktopProfile
        ? (await desktopProfiles.get(desktopProfile))?.get(sessionID) : undefined;
      const metadataName = string(metadata.name);
      const title = desktopSession?.title || summary.customTitle
        || (backgroundTarget && (!metadataName || metadataName === backgroundTarget.jobId)
          ? `Claude Code · ${backgroundTarget.jobId}` : metadataName)
        || summary.firstUser;
      const desktopTranscript = !process.tty && entrypoint.startsWith("claude-desktop");
      const turnState = status === "busy"
        ? "working" as const
        : readyStatuses.has(status) ? "ready" as const
        : !status && desktopTranscript
          ? summary.lifecycle?.phase ?? (summary.completed ? "ready" as const : "unknown" as const)
          : "unknown" as const;
      const claudeLifecycle = desktopTranscript && summary.lifecycle?.phase === turnState
        ? summary.lifecycle : undefined;
      const completionAt = turnState === "ready" && summary.lifecycle?.phase === "ready"
        ? summary.lifecycle.observedAt : undefined;
      const section = turnState === "unknown" ? "history" as const : turnState;
      const attached = backgroundTarget
        ? await attachedTerminalTarget(backgroundTarget.jobId, backgroundTarget.cwd, processes, this.environment)
        : undefined;
      const controlTarget = backgroundTarget
        ? { kind: "claude_background" as const, target: { ...backgroundTarget, ...(attached ? { attached } : {}) } }
        : terminalTarget
        ? { kind: "terminal" as const, target: terminalTarget }
        : desktopSession ? { kind: "url" as const, url: desktopSession.url }
        : applicationTarget ? { kind: "application" as const, target: applicationTarget } : undefined;

      results.push({
        id: sessionID,
        provider: "claude_code",
        title: title || undefined,
        subtitle: turnState === "working" ? "Claude Code is working"
          : turnState === "ready" ? "Ready to continue" : "Check Claude for current status",
        cwd,
        owner,
        section,
        updatedAt: completionAt ?? claudeLifecycle?.observedAt
          ?? iso(transcriptStamp?.modifiedAt ?? metadataStamp?.modifiedAt ?? this.environment.now()),
        canOpenOwner: controlTarget !== undefined,
        canEnterChat: true,
        sessionClass: terminalTarget || backgroundTarget ? "terminal" : "interactive",
        ...(kind === "bg" ? { ambientEligible: false } : {}),
        conversationState: "open",
        turnState,
        ...(claudeLifecycle ? { claudeLifecycle } : {}),
        ...(completionAt ? { completionAt } : {}),
        chatPath: transcript,
        ...(controlTarget ? { controlTarget } : {}),
        ...(terminalTarget ? { messageTransport: "terminal" as const } : {}),
      });
      if (kind === "interactive") {
        const interactiveID = fullSessionID(sessionID);
        if (interactiveID) interactiveSessionIds.add(interactiveID.toLowerCase());
      }
    }

    const { jobs: presenceByJob, report: presence } = await resolveClaudePresence(
      [...inventoryRows.values()].filter((row) => !hiddenInventoryJobs.has(row.id!.toLowerCase())),
      inventory?.authoritative === true, parkedGhosttyApplications,
      this.environment.ghosttyTerminalViews
        ? (titles) => this.environment.ghosttyTerminalViews!(titles) : undefined,
    );
    // Observability must never change session discovery or cause a retry.
    try { this.reportPresence?.(presence); } catch { /* Diagnostic sink unavailable. */ }

    if (inventory) {
      for (const row of inventoryRows.values()) {
        if (hiddenInventoryJobs.has(row.id!.toLowerCase())) continue;
        const metadata = backgroundMetadata.get(row.id!);
        const transcriptSessionID = inventory.authoritative
          ? fullSessionID(row.sessionId) ?? fullSessionID(metadata?.sessionID)
          : fullSessionID(metadata?.sessionID) ?? fullSessionID(row.sessionId);
        // A row with no trusted full UUID is retained in the inventory cache,
        // but it cannot become a public conversation until metadata or a later
        // inventory refresh supplies that identity.
        if (!transcriptSessionID) continue;
        const transcript = claudeTranscriptPath(
          this.environment.home, transcriptSessionID, row.cwd,
        );
        transcripts.add(transcript);
        const transcriptStamp = await this.environment.stamp(transcript);
        const summary = await this.transcriptSummary(transcript, transcriptStamp);
        const session = await this.backgroundSession(
          row, metadata, summary, transcript, transcriptStamp, processes, claudeExecutable,
          inventory.authoritative, inventory.observedAt, this.environment.now().valueOf(),
          interactiveSessionIds.has(transcriptSessionID.toLowerCase()) || presenceByJob.get(row.id!)?.reason === "conversation",
        );
        if (session) {
          const evidence = presenceByJob.get(row.id!);
          session.claudePresence = interactiveSessionIds.has(transcriptSessionID.toLowerCase())
            ? "interactive" : evidence?.reason;
          const displayed = evidence?.displayed;
          if (displayed && session.controlTarget?.kind === "claude_background") {
            session.controlTarget.target.displayed = displayed;
            session.controlTarget.target.application = "Ghostty";
            session.owner = "Ghostty";
          }
          const interactiveIndex = results.findIndex((candidate) =>
            candidate.id.toLowerCase() === session.id.toLowerCase());
          const interactive = results[interactiveIndex];
          if (interactive) {
            // One current UI identity and its retained job are one conversation.
            // Inventory supplies its name/state; current metadata supplies the
            // interactive route, rather than stale `claude attach` launch argv.
            results[interactiveIndex] = {
              ...session,
              owner: interactive.owner,
              canOpenOwner: interactive.canOpenOwner || session.canOpenOwner,
              ...(interactive.controlTarget ? { controlTarget: interactive.controlTarget } : {}),
              ...(interactive.messageTransport ? { messageTransport: interactive.messageTransport } : {}),
            };
          } else results.push(session);
        }
      }
    }

    for (const file of this.summaries.keys()) {
      if (!transcripts.has(file)) this.summaries.delete(file);
    }
    const currentBackgroundIDs = inventory
      ? new Set([...inventoryRows.values()]
        .filter((row) => !hiddenInventoryJobs.has(row.id!.toLowerCase()))
        .flatMap((row) => {
          const metadata = backgroundMetadata.get(row.id!);
          const sessionID = inventory.authoritative
            ? fullSessionID(row.sessionId) ?? fullSessionID(metadata?.sessionID)
            : fullSessionID(metadata?.sessionID) ?? fullSessionID(row.sessionId);
          return sessionID ? [sessionID] : [];
        }))
      : this.inventoryBackgroundIds;
    const removedConversationIds = new Map(this.removedConversationIds);
    if (inventory?.authoritative) {
      const removedAt = this.environment.now().valueOf();
      for (const id of this.inventoryBackgroundIds) {
        if (!currentBackgroundIDs.has(id) && !removedConversationIds.has(id)) {
          removedConversationIds.set(id, removedAt);
        }
      }
      for (const id of currentBackgroundIDs) {
        removedConversationIds.delete(id);
      }
      for (const id of interactiveSessionIds) {
        removedConversationIds.delete(id);
      }
      for (const [id, removedAt] of removedConversationIds) {
        if (removedAt + removedConversationRetentionMs <= this.environment.now().valueOf()) {
          removedConversationIds.delete(id);
        }
      }
      for (const id of this.failureLifecycleBySession.keys()) {
        if (!currentBackgroundIDs.has(id)) this.failureLifecycleBySession.delete(id);
      }
      while (removedConversationIds.size > maxRemovedConversationIds) {
        removedConversationIds.delete(removedConversationIds.keys().next().value!);
      }
      this.inventoryBackgroundIds = currentBackgroundIDs;
      this.removedConversationIds = removedConversationIds;
    }
    this.hiddenSessionIdsForPublication = new Set([
      ...spares,
      ...[...parkedSessionIds].filter((id) => !interactiveSessionIds.has(id.toLowerCase())),
      ...this.removedConversationIds.keys(),
    ]);
    return results;
  }

  hiddenSessionIds(): ReadonlySet<string> {
    return this.hiddenSessionIdsForPublication;
  }

  acknowledgeFailure(sessionId: string): void {
    const lifecycle = this.failureLifecycleBySession.get(sessionId.toLowerCase());
    if (!lifecycle || lifecycle.state !== "failed" || !lifecycle.alert) return;
    lifecycle.acknowledged = true;
    lifecycle.alert = false;
  }

  async resolveForFocus(sessionId: string): Promise<DiscoveredProviderSession | undefined> {
    return (await this.discover(true)).find((session) => session.id === sessionId);
  }

  private async readInventory(force = false): Promise<InventoryRead> {
    if (!this.environment.claudeAgentInventory) return { mode: "legacy", outage: false };
    let result: ClaudeAgentInventoryResult;
    try {
      result = force && this.environment.claudeAgentInventoryFresh
        ? await this.environment.claudeAgentInventoryFresh()
        : await this.environment.claudeAgentInventory();
    }
    catch { return { mode: "legacy", outage: true };
    }
    const snapshot = result.kind === "success" ? result : result.lastGood;
    if (snapshot) return {
      mode: "canonical", outage: result.kind !== "success",
      snapshot: {
        rows: snapshot.rows,
        authoritative: snapshot.authoritative,
        observedAt: snapshot.startedAt,
      },
    };
    return {
      outage: result.kind !== "unsupported" || result.reason !== "config_root",
      mode: result.kind === "unsupported" && result.reason === "config_root"
        ? "blocked" : "legacy",
    };
  }

  private async backgroundSession(
    row: ClaudeAgentInventoryRow,
    metadata: BackgroundMetadata | undefined,
    summary: TranscriptSummary,
    transcript: string,
    transcriptStamp: FileStamp | undefined,
    processes: ProcessRecord[],
    executable: string | undefined,
    authoritative: boolean,
    observedAt: number,
    checkedAt: number,
    ambientEligible: boolean,
  ): Promise<DiscoveredProviderSession | undefined> {
    // Do not publish a temporary public ID for a row whose UUID is absent.
    // The next inventory refresh can safely promote it once identity is
    // available without creating a second pill or breaking open-chat links.
    const sessionID = authoritative
      ? fullSessionID(row.sessionId) ?? fullSessionID(metadata?.sessionID)
      : fullSessionID(metadata?.sessionID) ?? fullSessionID(row.sessionId);
    if (!sessionID) return undefined;
    const jobId = row.id!.toLowerCase();
    const attached = await attachedTerminalTarget(jobId, row.cwd, processes, this.environment);
    const application = attached?.application
      ?? (metadata?.process
        ? terminalApplication(ownerForProcess(metadata.process.pid, processes))
        : undefined)
      ?? "Terminal";
    const target = authoritative && isKnownInventoryState(row.state)
      && executable && path.isAbsolute(executable)
      ? {
        jobId, cwd: row.cwd, executable, application,
        ...(attached ? { attached } : {}),
      } : undefined;
    const failurePresentation = this.failurePresentation(sessionID, row, authoritative);
    const state = failurePresentation?.turnState
      ?? inventoryTurnState(row, summary, authoritative, checkedAt);
    const inventoryName = meaningfulInventoryName(row.name, jobId);
    const title = inventoryName || summary.customTitle
      || summary.firstUser || `Claude Code · ${jobId}`;
    const lifecycle = summary.lifecycle;
    const updatedAt = lifecycle?.observedAt
      ?? iso(transcriptStamp?.modifiedAt ?? new Date(row.startedAt));
    return {
      id: sessionID,
      provider: "claude_code",
      title,
      subtitle: state === "working" ? "Claude Code is working"
        : state === "needs_you" ? row.waitingFor || "Claude Code needs attention"
        : state === "ready" ? "Ready to continue"
        : state === "history" ? "Claude Code session stopped" : "Check Claude for current status",
      cwd: row.cwd,
      owner: application,
      section: state === "unknown" || state === "history" ? "history" : state,
      updatedAt,
      ...(state === "ready" && lifecycle?.phase === "ready" ? { completionAt: lifecycle.observedAt } : {}),
      canOpenOwner: target !== undefined,
      canEnterChat: true,
      sessionClass: "terminal",
      // A worker, attach argv, or parked overview is not an open conversation.
      // Current interactive metadata or a unique current Ghostty conversation
      // title establishes presence; ownership and parked IDs alone do not.
      ambientEligible,
      conversationState: "open",
      turnState: state === "history" ? "unknown" : state,
      chatPath: transcript,
      ...(target ? { controlTarget: { kind: "claude_background" as const, target } } : {}),
      claudeInventoryState: { authoritative, observedAt, checkedAt },
      ...(failurePresentation?.failureAlert !== undefined
        ? { failureAlert: failurePresentation.failureAlert } : {}),
    };
  }

  private failurePresentation(
    sessionID: string,
    row: ClaudeAgentInventoryRow,
    authoritative: boolean,
  ): { turnState: "needs_you" | "history"; failureAlert: boolean } | undefined {
    const state = string(row.state).toLowerCase();
    const key = sessionID.toLowerCase();
    const previous = this.failureLifecycleBySession.get(key);
    if (!authoritative) {
      if (state !== "failed") return undefined;
      if (previous?.state === "failed") {
        return {
          turnState: previous.alert && !previous.acknowledged ? "needs_you" : "history",
          failureAlert: previous.alert && !previous.acknowledged,
        };
      }
      // A stale failed row is historical evidence. It must not become a new
      // alert while the provider is unavailable or its cache is outside grace.
      return { turnState: "history", failureAlert: false };
    }
    if (state !== "failed") {
      if (isKnownInventoryState(state)) {
        this.failureLifecycleBySession.set(key, {
          state, alert: false, acknowledged: false,
        });
      }
      return undefined;
    }

    const newlyFailed = this.removedConversationIds.has(key)
      || (previous !== undefined && previous.state !== "failed");
    const acknowledged = previous?.state === "failed" && previous.acknowledged;
    const alert = newlyFailed || (previous?.state === "failed" && previous.alert && !acknowledged);
    this.failureLifecycleBySession.set(key, {
      state, alert, acknowledged: !!acknowledged,
    });
    return {
      turnState: alert ? "needs_you" : "history",
      failureAlert: alert,
    };
  }

  private async transcriptSummary(file: string, stamp: FileStamp | undefined): Promise<TranscriptSummary> {
    const previous = this.summaries.get(file);
    if (stamp && previous?.size === stamp.size && previous.modifiedAt === stamp.modifiedAt.valueOf()) {
      return previous.summary;
    }
    const summary = await claudeTranscriptSummary(this.environment, file);
    if (summary && stamp) {
      // Re-read only changed transcripts and retain only active-session
      // summaries. Do not cache read failures; they must be recoverable.
      this.summaries.set(file, { size: stamp.size, modifiedAt: stamp.modifiedAt.valueOf(), summary });
    } else {
      this.summaries.delete(file);
    }
    return summary ?? emptySummary;
  }
}

/** Find a terminal window already running `claude attach <jobId>`. */
async function attachedTerminalTarget(
  jobId: string,
  jobCwd: string,
  processes: ProcessRecord[],
  environment: ProviderEnvironment,
): Promise<NativeHelperTerminalTarget | undefined> {
  for (const process of processes) {
    const [program, verb, id] = process.arguments.trim().split(/\s+/);
    if (path.basename(program ?? "") !== "claude" || verb !== "attach" || id !== jobId) continue;
    const target = terminalTargetForProcess(
      process, await environment.cwd(process.pid) ?? jobCwd, processes,
      processInstanceToken(process.pid, await environment.processStartedAt(process.pid)),
    );
    if (target) return target;
  }
  return undefined;
}

function isNativeClaudeBinary(command: string, home: string): boolean {
  return path.dirname(command) === path.join(home, ".local/share/claude/versions")
    && /^\d+\.\d+\.\d+$/.test(path.basename(command));
}

function isClaudeCommand(command: string, home: string): boolean {
  // macOS comm can report the resolved native binary, whose name is a version.
  return path.basename(command).toLowerCase().includes("claude")
    || isNativeClaudeBinary(command, home);
}

function claudeBackgroundTarget(
  process: ProcessRecord,
  byPID: Map<number, ProcessRecord>,
  sessionID: string,
  jobId: string,
  cwd: string,
  entrypoint: string,
  home: string,
): { jobId: string; cwd: string; executable: string; application: "Ghostty" | "iTerm2" | "Terminal" } | undefined {
  if (entrypoint !== "cli" || !path.isAbsolute(cwd)
    || !/^[0-9a-f]{8}$/i.test(jobId) || !sessionID.toLowerCase().startsWith(jobId.toLowerCase())
    || !process.arguments.includes(`--session-id ${sessionID}`)
    || !process.arguments.includes("--agent claude")) return undefined;
  const application = ownerForProcess(process.pid, [...byPID.values()]);
  if (application !== "Ghostty" && application !== "iTerm2" && application !== "Terminal") return undefined;
  let parent = byPID.get(process.parentPID);
  const visited = new Set<number>();
  let executable: string | undefined;
  while (parent && !visited.has(parent.pid)) {
    visited.add(parent.pid);
    if (path.basename(parent.command) === "claude" && path.isAbsolute(parent.command)
      && !parent.command.includes(".app/")) {
      executable = parent.command;
      break;
    }
    parent = byPID.get(parent.parentPID);
  }
  if (!executable && isNativeClaudeBinary(process.command, home)) executable = process.command;
  return executable ? { jobId, cwd, executable, application } : undefined;
}

function claudeTranscriptPath(home: string, sessionID: string, cwd: string): string {
  const project = cwd.replaceAll("/", "-").replaceAll(".", "-").replaceAll("_", "-");
  return path.join(home, ".claude", "projects", project, `${sessionID}.jsonl`);
}

async function claudeTranscriptSummary(
  environment: ProviderEnvironment,
  transcriptPath: string,
): Promise<TranscriptSummary | undefined> {
  const content = await environment.readHeadTail(transcriptPath);
  if (!content) return undefined;
  let firstUser = "";
  let customTitle = "";
  let completed = false;
  let lifecycle: TranscriptSummary["lifecycle"];
  for (const chunk of [content.head, content.tail]) {
    // The head may contain an old completed turn. Only the current tail can
    // prove completion; a large/partial newer message must clear old evidence.
    completed = false;
    lifecycle = undefined;
    for (const line of chunk.split("\n")) {
      let value: unknown;
      try { value = JSON.parse(line); } catch {
        if (line.trim()) {
          completed = false;
          lifecycle = undefined;
        }
        continue;
      }
      if (!isRecord(value) || value.isSidechain === true) continue;
      if (value.type === "custom-title") customTitle = string(value.customTitle || value.title);
      if (!firstUser && value.type === "user") firstUser = claudeUserText(value);
      // Only an explicit completed assistant turn is a recovery signal. Tool
      // calls, partial streams and later user input invalidate older completion;
      // bookkeeping records (titles, summaries, etc.) do not create activity.
      if (value.type === "user" && value.isMeta !== true) {
        completed = false;
      } else if (value.type === "assistant") {
        const message = isRecord(value.message) ? value.message : undefined;
        completed = message?.stop_reason === "end_turn";
      } else if (value.type === "system" && value.subtype === "turn_duration") {
        completed = true;
      } else {
        continue;
      }
      const timestamp = Date.parse(string(value.timestamp));
      lifecycle = Number.isFinite(timestamp)
        ? { phase: completed ? "ready" : "working", observedAt: new Date(timestamp).toISOString() }
        : undefined;
    }
  }
  return { customTitle, firstUser, completed, ...(lifecycle ? { lifecycle } : {}) };
}

function claudeUserText(value: Record<string, unknown>): string {
  const message = isRecord(value.message) ? value.message : undefined;
  const content = message?.content;
  if (typeof content === "string") return content.trim();
  if (!Array.isArray(content)) return "";
  return content.flatMap((block) =>
    isRecord(block) && typeof block.text === "string" ? [block.text] : []).join("\n").trim();
}

function inventoryTurnState(
  row: ClaudeAgentInventoryRow,
  summary: TranscriptSummary,
  authoritative: boolean,
  checkedAt: number,
): "working" | "needs_you" | "ready" | "history" | "unknown" {
  const lifecycle = freshLifecycle(summary.lifecycle, checkedAt);
  if (!authoritative) {
    return lifecycle?.phase === "working" ? "working"
      : lifecycle ? "ready" : "unknown";
  }
  const state = string(row.state).toLowerCase();
  if (state === "working" || state === "blocked") {
    // The background worker can remain Working or blocked after its turn has
    // completed. A fresh idle status corroborates that durable completion;
    // an alive worker alone does not prove an active conversation turn.
    const completedAt = Date.parse(summary.lifecycle?.observedAt ?? "");
    if (string(row.status).toLowerCase() === "idle" && !string(row.waitingFor)
      && summary.completed && summary.lifecycle?.phase === "ready"
      && Number.isFinite(completedAt) && completedAt <= checkedAt) return "ready";
    // Current worker activity can outpace the aggregate blocked job state.
    if (state === "blocked" && (string(row.status).toLowerCase() !== "busy" || string(row.waitingFor))) {
      return "needs_you";
    }
    return "working";
  }
  if (state === "done") return "ready";
  if (state === "failed") return "needs_you";
  if (state === "stopped") return "history";
  if (lifecycle) return lifecycle.phase === "working" ? "working" : "ready";
  return "unknown";
}

function freshLifecycle(
  lifecycle: DiscoveredProviderSession["claudeLifecycle"] | undefined,
  checkedAt: number,
): DiscoveredProviderSession["claudeLifecycle"] | undefined {
  if (!lifecycle) return undefined;
  const observedAt = Date.parse(lifecycle.observedAt);
  return Number.isFinite(observedAt)
    && observedAt <= checkedAt
    && checkedAt - observedAt <= 30_000 ? lifecycle : undefined;
}

function meaningfulInventoryName(value: string | undefined, jobId: string | undefined): string {
  const name = string(value);
  return name && name.toLowerCase() !== string(jobId).toLowerCase() ? name : "";
}

function isKnownInventoryState(value: string | undefined): boolean {
  return value !== undefined && knownInventoryStates.has(value.toLowerCase());
}

function fullSessionID(value: string | undefined): string | undefined {
  const sessionID = string(value);
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(sessionID)
    ? sessionID.toLowerCase() : undefined;
}

function isUsableInventoryBackground(row: ClaudeAgentInventoryRow): boolean {
  return row.kind === "background"
    && !!row.id && /^[0-9a-f]{8}$/i.test(row.id)
    && path.isAbsolute(row.cwd)
    && !row.spare
    && !isInternalBackgroundMetadata(
      `${string(row.entrypoint)} ${string(row.source)} ${string(row.agent)}`.trim().toLowerCase(),
      row.cwd,
    );
}

function isInternalBackgroundMetadata(entrypoint: string, cwd: string): boolean {
  const marker = entrypoint.toLowerCase();
  const normalizedCwd = cwd.toLowerCase();
  return marker.startsWith("sdk") || marker.startsWith("observer")
    || marker.includes(".claude-mem") || marker.includes("observer-sessions")
    || normalizedCwd.includes(".claude-mem") || normalizedCwd.includes("observer-sessions");
}

function terminalApplication(value: string): "Ghostty" | "iTerm2" | "Terminal" | undefined {
  return value === "Ghostty" || value === "iTerm2" || value === "Terminal" ? value : undefined;
}

function string(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}
