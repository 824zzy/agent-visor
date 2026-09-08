import type { ProviderEnvironment } from "./environment.js";
import { isRecord } from "./shared.js";

const lifecyclePrefixBytes = 8_192;

export type CodexLifecycle = {
  phase: "working" | "ready";
  observedAt: string;
  turnId?: string;
};

type Checkpoint = {
  file: string;
  size: number;
  modifiedAt: number;
  offset: number;
  state: CodexTranscriptState;
};

type CodexTranscriptState = {
  lifecycle?: CodexLifecycle;
  originator?: string;
};

/** Read turn boundaries and client identity together, without retaining content. */
export class CodexTranscriptReader {
  private readonly checkpoints = new Map<string, Checkpoint>();
  private checkpointLimit = 200;

  retain(sessionIds: string[]): void {
    const retained = new Set(sessionIds);
    for (const id of this.checkpoints.keys()) {
      if (!retained.has(id)) this.checkpoints.delete(id);
    }
    // Keep one small checkpoint per catalog record so catalogs larger than
    // one page do not re-read every transcript on every refresh.
    this.checkpointLimit = Math.max(200, retained.size);
  }

  async read(
    environment: ProviderEnvironment, sessionId: string, file: string,
  ): Promise<CodexTranscriptState | undefined> {
    const stamp = await environment.stamp(file);
    if (!stamp) return undefined;
    const previous = this.checkpoints.get(sessionId);
    const modifiedAt = stamp.modifiedAt.valueOf();
    const checkpoint = previous?.file === file && stamp.size >= previous.size
      && (stamp.size > previous.size || modifiedAt === previous.modifiedAt)
      ? previous : undefined;
    if (checkpoint?.offset === stamp.size && checkpoint.modifiedAt === modifiedAt) {
      return checkpoint.state;
    }
    let lifecycle = checkpoint?.state.lifecycle;
    let originator = checkpoint?.state.originator;
    const offset = await environment.scanLinePrefixes(file, lifecyclePrefixBytes, (line) => {
      try {
        const value = lifecycleRecord(line);
        if (isRecord(value) && value.type === "session_meta" && isRecord(value.payload)
          && value.payload.id === sessionId) {
          // Use the latest recorded client, not the first prompt or project name.
          originator = typeof value.payload.originator === "string"
            && value.payload.originator.length <= 256 ? value.payload.originator : undefined;
          return;
        }
        if (!isRecord(value) || value.type !== "event_msg" || !isRecord(value.payload)
          || typeof value.timestamp !== "string" || !Number.isFinite(Date.parse(value.timestamp))) return;
        const type = value.payload.type;
        if (type === "task_started" || type === "task_complete" || type === "turn_aborted") {
          const turnId = typeof value.payload.turn_id === "string"
            && value.payload.turn_id.length > 0 && value.payload.turn_id.length <= 256
            ? value.payload.turn_id : undefined;
          if ("turn_id" in value.payload && !turnId) return;
          const observedAt = new Date(value.timestamp).toISOString();
          if (lifecycle && observedAt < lifecycle.observedAt) return;
          if (type === "task_started" && turnId && lifecycle?.turnId === turnId) return;
          if (type !== "task_started" && lifecycle?.turnId && turnId
            && lifecycle.turnId !== turnId) return;
          const currentTurnId = type === "task_started" ? turnId : turnId ?? lifecycle?.turnId;
          lifecycle = {
            phase: type === "task_started" ? "working" : "ready",
            observedAt,
            ...(currentTurnId ? { turnId: currentTurnId } : {}),
          };
        }
      } catch { /* Large content rows and incomplete JSON are not lifecycle evidence. */ }
    }, checkpoint?.offset ?? 0);
    // ponytail: retain only bounded metadata, never prompts or tool output.
    // The offset stops at a newline. Partial writes/read failures are retried,
    // while unchanged transcripts and already-consumed bytes are not rescanned.
    const state = { lifecycle, originator };
    this.checkpoints.delete(sessionId);
    this.checkpoints.set(sessionId, { file, size: stamp.size, modifiedAt, offset, state });
    while (this.checkpoints.size > this.checkpointLimit) {
      this.checkpoints.delete(this.checkpoints.keys().next().value!);
    }
    return state;
  }
}

function lifecycleRecord(line: string): unknown {
  try { return JSON.parse(line); }
  catch {
    if (Buffer.byteLength(line) < lifecyclePrefixBytes) return undefined;
    // Session identity precedes the potentially huge instructions object.
    // Parse that complete header as JSON; never search inside prompt content.
    const instructions = /,\s*"base_instructions"\s*:/.exec(line);
    if (instructions) {
      try {
        const header: unknown = JSON.parse(line.slice(0, instructions.index) + "}}");
        if (isRecord(header) && header.type === "session_meta") return header;
      } catch { /* Unknown metadata layouts remain unclassified. */ }
    }
    // Codex puts identity before last_agent_message, which can be megabytes.
    // Match only the emitted root envelope, never marker-like text in content.
    const header = /^\{\s*"timestamp"\s*:\s*("(?:[^"\\]|\\.)*")\s*,\s*(?:"ordinal"\s*:\s*\d+\s*,\s*)?"type"\s*:\s*"event_msg"\s*,\s*"payload"\s*:\s*\{\s*"type"\s*:\s*"(task_started|task_complete|turn_aborted)"\s*,\s*"turn_id"\s*:\s*("(?:[^"\\]|\\.)*")\s*[,}]/.exec(line);
    return header ? {
      timestamp: JSON.parse(header[1]!), type: "event_msg",
      payload: { type: header[2], turn_id: JSON.parse(header[3]!) },
    } : undefined;
  }
}
