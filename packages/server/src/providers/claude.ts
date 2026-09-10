import path from "node:path";
import type { ProviderAdapter, DiscoveredProviderSession } from "../sessions.js";
import type { FileStamp, ProviderEnvironment } from "./environment.js";
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

type TranscriptSummary = { customTitle: string; firstUser: string; completed: boolean };
const emptySummary: TranscriptSummary = { customTitle: "", firstUser: "", completed: false };

export class ClaudeProvider implements ProviderAdapter {
  readonly id = "claude_code" as const;
  private readonly summaries = new Map<string, { size: number; modifiedAt: number; summary: TranscriptSummary }>();
  private readonly desktopSessions: ClaudeDesktopSessions;

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

    for (const file of await this.environment.directory(directory)) {
      const match = /^(\d+)\.json$/.exec(file);
      if (!match) continue;
      const pid = Number(match[1]);
      const process = byPID.get(pid);
      if (!process || !path.basename(process.command).toLowerCase().includes("claude")) continue;
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
      if (!sessionID || !cwd || kind !== "interactive") continue;
      if (entrypoint.startsWith("sdk") || terminalStatuses.has(status)) continue;
      if (cwd.includes(".claude-mem") || cwd.includes("observer-sessions")) continue;

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
      const terminalTarget = terminalTargetForProcess(
        process,
        cwd,
        processes,
        processStartToken,
      );
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
      const title = desktopSession?.title || summary.customTitle || string(metadata.name) || summary.firstUser;
      const turnState = status === "busy"
        ? "working" as const
        : readyStatuses.has(status) ? "ready" as const
        : !status && !process.tty && entrypoint.startsWith("claude-desktop") && summary.completed
          ? "ready" as const : "unknown" as const;
      const section = turnState === "unknown" ? "history" as const : turnState;
      const controlTarget = terminalTarget
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
        updatedAt: iso(transcriptStamp?.modifiedAt ?? metadataStamp?.modifiedAt ?? this.environment.now()),
        canOpenOwner: controlTarget !== undefined,
        canEnterChat: true,
        sessionClass: terminalTarget ? "terminal" : "interactive",
        conversationState: "open",
        turnState,
        chatPath: transcript,
        ...(controlTarget ? { controlTarget } : {}),
        ...(terminalTarget ? { messageTransport: "terminal" as const } : {}),
      });
    }

    for (const file of this.summaries.keys()) {
      if (!transcripts.has(file)) this.summaries.delete(file);
    }
    return results;
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
  for (const chunk of [content.head, content.tail]) {
    // The head may contain an old completed turn. Only the current tail can
    // prove completion; a large/partial newer message must clear old evidence.
    completed = false;
    for (const line of chunk.split("\n")) {
      let value: unknown;
      try { value = JSON.parse(line); } catch {
        if (line.trim()) completed = false;
        continue;
      }
      if (!isRecord(value) || value.isSidechain === true) continue;
      if (value.type === "custom-title") customTitle = string(value.customTitle || value.title);
      if (!firstUser && value.type === "user") firstUser = claudeUserText(value);
      // Only an explicit completed assistant turn is a recovery signal. Tool
      // calls, partial streams and later user input invalidate older completion;
      // bookkeeping records (titles, summaries, etc.) do not create activity.
      if (value.type === "user" && value.isMeta !== true) completed = false;
      if (value.type === "assistant") {
        const message = isRecord(value.message) ? value.message : undefined;
        completed = message?.stop_reason === "end_turn";
      }
      if (value.type === "system" && value.subtype === "turn_duration") completed = true;
    }
  }
  return { customTitle, firstUser, completed };
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
