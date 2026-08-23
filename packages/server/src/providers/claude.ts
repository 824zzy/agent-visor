import path from "node:path";
import type { ProviderAdapter, DiscoveredProviderSession } from "../sessions.js";
import type { ProviderEnvironment } from "./environment.js";
import {
  applicationTargetForProcess, isRecord, iso, ownerForProcess, terminalTargetForProcess,
} from "./shared.js";

const terminalStatuses = new Set([
  "ended", "exited", "closed", "deactivated", "inactive", "stopped", "terminated",
]);

export class ClaudeProvider implements ProviderAdapter {
  readonly id = "claude_code" as const;

  constructor(private readonly environment: ProviderEnvironment) {}

  async discover(): Promise<DiscoveredProviderSession[]> {
    const directory = path.join(this.environment.home, ".claude", "sessions");
    const processes = await this.environment.processes();
    const byPID = new Map(processes.map((process) => [process.pid, process]));
    const results: DiscoveredProviderSession[] = [];

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
      const transcriptStamp = await this.environment.stamp(transcript);
      if (!process.tty && entrypoint.includes("vscode")) {
        if (!transcriptStamp
          || this.environment.now().valueOf() - transcriptStamp.modifiedAt.valueOf()
            > this.environment.observedWindowMs) continue;
      }
      const metadataStamp = await this.environment.stamp(metadataPath);
      const title = string(metadata.name) || await claudeTranscriptTitle(this.environment, transcript);
      const owner = process.tty
        ? ownerForProcess(pid, processes)
        : entrypoint.includes("vscode") ? "Cursor" : "Claude";
      const terminalTarget = terminalTargetForProcess(process, cwd, processes);
      const applicationTarget = applicationTargetForProcess(process.pid, processes);

      results.push({
        id: sessionID,
        provider: "claude_code",
        title: title || undefined,
        subtitle: status === "busy" ? "Claude Code is working" : "Claude Code session",
        cwd,
        owner,
        section: "working",
        updatedAt: iso(transcriptStamp?.modifiedAt ?? metadataStamp?.modifiedAt ?? this.environment.now()),
        canOpenOwner: true,
        canEnterChat: true,
        chatPath: transcript,
        ...(terminalTarget ? {
          controlTarget: { kind: "terminal" as const, target: terminalTarget },
          messageTransport: "terminal" as const,
        } : applicationTarget ? {
          controlTarget: { kind: "application" as const, target: applicationTarget },
        } : {}),
      });
    }

    return results;
  }
}

function claudeTranscriptPath(home: string, sessionID: string, cwd: string): string {
  const project = cwd.replaceAll("/", "-").replaceAll(".", "-").replaceAll("_", "-");
  return path.join(home, ".claude", "projects", project, `${sessionID}.jsonl`);
}

async function claudeTranscriptTitle(
  environment: ProviderEnvironment,
  transcriptPath: string,
): Promise<string> {
  const content = await environment.readHeadTail(transcriptPath);
  if (!content) return "";
  const lines = `${content.head}\n${content.tail}`.split("\n");
  let firstUser = "";
  let customTitle = "";
  for (const line of lines) {
    let value: unknown;
    try { value = JSON.parse(line); } catch { continue; }
    if (!isRecord(value)) continue;
    if (value.type === "custom-title") customTitle = string(value.customTitle || value.title);
    if (!firstUser && value.type === "user") firstUser = claudeUserText(value);
  }
  return customTitle || firstUser;
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
