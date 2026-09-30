import path from "node:path";
import type { NativeHelperTerminalTarget } from "@agent-visor/protocol";
import type { ProviderAdapter, DiscoveredProviderSession } from "../sessions.js";
import type { FileStamp, ProcessRecord, ProviderEnvironment } from "./environment.js";
import { ClaudeDesktopSessions } from "./claude-desktop.js";
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

type TranscriptSummary = {
  customTitle: string;
  firstUser: string;
  completed: boolean;
  lifecycle?: DiscoveredProviderSession["claudeLifecycle"];
};
const emptySummary: TranscriptSummary = { customTitle: "", firstUser: "", completed: false };

export class ClaudeProvider implements ProviderAdapter {
  readonly id = "claude_code" as const;
  private readonly summaries = new Map<string, { size: number; modifiedAt: number; summary: TranscriptSummary }>();
  private readonly desktopSessions: ClaudeDesktopSessions;
  private spareSessionIds: ReadonlySet<string> = new Set();

  constructor(private readonly environment: ProviderEnvironment) {
    this.desktopSessions = new ClaudeDesktopSessions(environment);
  }

  async discover(): Promise<DiscoveredProviderSession[]> {
    const directory = path.join(this.environment.home, ".claude", "sessions");
    const processes = await this.environment.processes();
    const byPID = new Map(processes.map((process) => [process.pid, process]));
    const results: DiscoveredProviderSession[] = [];
    const transcripts = new Set<string>();
    const desktopProfiles = new Map<string, ReturnType<ClaudeDesktopSessions["read"]>>();
    const spares = new Set<string>();

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
      const entrypoint = string(metadata.entrypoint).toLowerCase();
      const status = string(metadata.status).toLowerCase();
      // The Claude daemon pre-warms an idle worker for the next background
      // job. It has no conversation until claimed, when Claude drops the flag.
      if (metadata.spare === true) {
        if (sessionID) spares.add(sessionID);
        continue;
      }
      if (!sessionID || !cwd || (kind !== "interactive" && kind !== "bg")) continue;
      if (entrypoint.startsWith("sdk") || terminalStatuses.has(status)) continue;
      if (cwd.includes(".claude-mem") || cwd.includes("observer-sessions")) continue;
      const backgroundTarget = kind === "bg"
        ? claudeBackgroundTarget(process, byPID, sessionID, string(metadata.jobId), cwd, entrypoint, this.environment.home)
        : undefined;
      if (kind === "bg" ? !backgroundTarget
        : !path.basename(process.command).toLowerCase().includes("claude")) continue;

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
        updatedAt: claudeLifecycle?.observedAt
          ?? iso(transcriptStamp?.modifiedAt ?? metadataStamp?.modifiedAt ?? this.environment.now()),
        canOpenOwner: controlTarget !== undefined,
        canEnterChat: true,
        sessionClass: terminalTarget || backgroundTarget ? "terminal" : "interactive",
        conversationState: "open",
        turnState,
        ...(claudeLifecycle ? { claudeLifecycle } : {}),
        chatPath: transcript,
        ...(controlTarget ? { controlTarget } : {}),
        ...(terminalTarget ? { messageTransport: "terminal" as const } : {}),
      });
    }

    for (const file of this.summaries.keys()) {
      if (!transcripts.has(file)) this.summaries.delete(file);
    }
    this.spareSessionIds = spares;
    return results;
  }

  hiddenSessionIds(): ReadonlySet<string> {
    return this.spareSessionIds;
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
  if (!executable && process.command.startsWith(path.join(home, ".local/share/claude/versions") + path.sep)
    && /^\d+\.\d+\.\d+$/.test(path.basename(process.command))) executable = process.command;
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

function string(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}
