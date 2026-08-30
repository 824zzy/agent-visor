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
  lifecycle?: CodexLifecycle;
};

/** Desktop turn boundaries are authoritative even when a lifecycle hook is lost. */
export class CodexLifecycleReader {
  private readonly checkpoints = new Map<string, Checkpoint>();

  async read(
    environment: ProviderEnvironment, sessionId: string, file: string,
  ): Promise<CodexLifecycle | undefined> {
    const stamp = await environment.stamp(file);
    if (!stamp) return undefined;
    const previous = this.checkpoints.get(sessionId);
    const modifiedAt = stamp.modifiedAt.valueOf();
    const checkpoint = previous?.file === file && stamp.size >= previous.size
      && (stamp.size > previous.size || modifiedAt === previous.modifiedAt)
      ? previous : undefined;
    if (checkpoint?.offset === stamp.size && checkpoint.modifiedAt === modifiedAt) {
      return checkpoint.lifecycle;
    }
    let lifecycle = checkpoint?.lifecycle;
    const offset = await environment.scanLinePrefixes(file, lifecyclePrefixBytes, (line) => {
      try {
        const value = lifecycleRecord(line);
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
    this.checkpoints.delete(sessionId);
    this.checkpoints.set(sessionId, { file, size: stamp.size, modifiedAt, offset, lifecycle });
    while (this.checkpoints.size > 200) {
      this.checkpoints.delete(this.checkpoints.keys().next().value!);
    }
    return lifecycle;
  }
}

function lifecycleRecord(line: string): unknown {
  try { return JSON.parse(line); }
  catch {
    if (Buffer.byteLength(line) < lifecyclePrefixBytes) return undefined;
    // Codex puts identity before last_agent_message, which can be megabytes.
    // Match only the emitted root envelope, never marker-like text in content.
    const header = /^\{\s*"timestamp"\s*:\s*("(?:[^"\\]|\\.)*")\s*,\s*(?:"ordinal"\s*:\s*\d+\s*,\s*)?"type"\s*:\s*"event_msg"\s*,\s*"payload"\s*:\s*\{\s*"type"\s*:\s*"(task_started|task_complete|turn_aborted)"\s*,\s*"turn_id"\s*:\s*("(?:[^"\\]|\\.)*")\s*[,}]/.exec(line);
    return header ? {
      timestamp: JSON.parse(header[1]!), type: "event_msg",
      payload: { type: header[2], turn_id: JSON.parse(header[3]!) },
    } : undefined;
  }
}
