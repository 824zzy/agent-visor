import type { ProviderEnvironment } from "./environment.js";
import { isRecord } from "./shared.js";

const lifecyclePrefixBytes = 8_192;
const questionReplyPrefixBytes = 65_536;

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
  /** Turn progress only; settings, navigation, and unknown records cannot refresh it. */
  activityAt?: string;
  originator?: string;
  pendingQuestionIds?: string[];
  questionAt?: string;
  pendingAsyncQuestions?: {
    callId: string;
    remaining: number[];
    observedAt: string;
  }[];
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
    rawThreadId = sessionId,
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
    let activityAt = checkpoint?.state.activityAt;
    let originator = checkpoint?.state.originator;
    const pendingQuestionIds = new Set(checkpoint?.state.pendingQuestionIds);
    const pendingAsyncQuestions = new Map(checkpoint?.state.pendingAsyncQuestions?.map((question) => [
      question.callId, { ...question, remaining: [...question.remaining] },
    ]));
    let questionAt = checkpoint?.state.questionAt;
    let largeReply = false;
    const resolveReplies = (value: Record<string, unknown>, payload: Record<string, unknown>) => {
      if (value.type !== "response_item" || payload.type !== "message" || payload.role !== "user"
        || typeof value.timestamp !== "string" || !Number.isFinite(Date.parse(value.timestamp))) return;
      const observedAt = new Date(value.timestamp).toISOString();
      for (const reply of asyncQuestionReplies(payload)) {
        const question = pendingAsyncQuestions.get(reply.callId);
        if (!question || observedAt < question.observedAt) continue;
        question.remaining = question.remaining.filter((index) => index !== reply.index);
        if (!question.remaining.length) pendingAsyncQuestions.delete(reply.callId);
      }
    };
    const offset = await environment.scanLinePrefixes(file, lifecyclePrefixBytes, (line) => {
      try {
        const value = lifecycleRecord(line);
        if (isRecord(value) && value.type === "session_meta" && isRecord(value.payload)
          && value.payload.id === rawThreadId) {
          // Use the latest recorded client, not the first prompt or project name.
          originator = typeof value.payload.originator === "string"
            && value.payload.originator.length <= 256 ? value.payload.originator : undefined;
          return;
        }
        if (!isRecord(value) || !isRecord(value.payload)
          || typeof value.timestamp !== "string" || !Number.isFinite(Date.parse(value.timestamp))) return;
        const type = value.payload.type;
        if (value.type === "response_item" && type === "function_call_output"
          && typeof value.payload.call_id === "string" && pendingAsyncQuestions.has(value.payload.call_id)) {
          try {
            const output: unknown = typeof value.payload.output === "string" ? JSON.parse(value.payload.output) : undefined;
            if (isRecord(output) && output.accepted === false) pendingAsyncQuestions.delete(value.payload.call_id);
          } catch { /* Delivery acknowledgment is not an answer; unknown output stays pending. */ }
        }
        if (value.type === "response_item" && type === "message" && value.payload.role === "user") {
          if (pendingAsyncQuestions.size && !Array.isArray(value.payload.content)) largeReply = true;
          resolveReplies(value, value.payload);
        }
        if (value.type === "event_msg"
          && (type === "task_started" || type === "task_complete" || type === "turn_aborted")) {
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
          pendingQuestionIds.clear();
          questionAt = undefined;
          activityAt = observedAt;
        } else if (lifecycle?.phase === "working" && isTurnProgress(value.type, value.payload)) {
          const observedAt = new Date(value.timestamp).toISOString();
          if (observedAt < lifecycle.observedAt || (activityAt && observedAt < activityAt)) return;
          if ("turn_id" in value.payload && value.payload.turn_id !== lifecycle.turnId) return;
          activityAt = observedAt;
          const callId = typeof value.payload.call_id === "string" ? value.payload.call_id : undefined;
          if (callId && callId.length <= 512) {
            if (value.type === "response_item" && type === "function_call"
              && ["request_user_input_async", "functions.request_user_input_async"].includes(String(value.payload.name))) {
              const args: unknown = typeof value.payload.arguments === "string" ? JSON.parse(value.payload.arguments) : undefined;
              if (isRecord(args) && Array.isArray(args.questions) && args.questions.length > 0
                && args.questions.length <= 32 && pendingAsyncQuestions.size < 32
                && args.questions.every((question) => isRecord(question)
                  && typeof question.title === "string" && question.title.trim().length > 0)) {
                pendingAsyncQuestions.set(callId, {
                  callId, remaining: args.questions.map((_, index) => index), observedAt,
                });
              }
            } else if ((value.type === "response_item" && type === "function_call"
              && ["request_user_input", "functions.request_user_input"].includes(String(value.payload.name)))
              || (value.type === "event_msg" && type === "request_user_input")) {
              if (pendingQuestionIds.size < 32) pendingQuestionIds.add(callId);
              questionAt = observedAt;
            } else if (value.type === "response_item" && type === "function_call_output") {
              pendingQuestionIds.delete(callId);
            }
          }
        }
      } catch { /* Large content rows and incomplete JSON are not lifecycle evidence. */ }
    }, checkpoint?.offset ?? 0);
    if (largeReply && pendingAsyncQuestions.size) {
      // Only oversized user rows need the larger bounded read. Revisit this
      // delta, not previous turns; retain IDs/indices, never question answers.
      await environment.scanLinePrefixes(file, questionReplyPrefixBytes, (line) => {
        try {
          const value: unknown = JSON.parse(line);
          if (isRecord(value) && isRecord(value.payload)) resolveReplies(value, value.payload);
        } catch { /* Truncated or malformed content cannot acknowledge a question. */ }
      }, checkpoint?.offset ?? 0);
    }
    // ponytail: retain only bounded metadata, never prompts or tool output.
    // The offset stops at a newline. Partial writes/read failures are retried,
    // while unchanged transcripts and already-consumed bytes are not rescanned.
    const state = { lifecycle, activityAt, originator, pendingQuestionIds: [...pendingQuestionIds], questionAt,
      pendingAsyncQuestions: [...pendingAsyncQuestions.values()] };
    this.checkpoints.delete(sessionId);
    this.checkpoints.set(sessionId, { file, size: stamp.size, modifiedAt, offset, state });
    while (this.checkpoints.size > this.checkpointLimit) {
      this.checkpoints.delete(this.checkpoints.keys().next().value!);
    }
    return state;
  }
}

/** The source client's structured reply resolves only the addressed question item. */
function asyncQuestionReplies(payload: Record<string, unknown>): { callId: string; index: number }[] {
  if (!Array.isArray(payload.content)) return [];
  const result: { callId: string; index: number }[] = [];
  for (const block of payload.content) {
    if (!isRecord(block) || block.type !== "input_text" || typeof block.text !== "string") continue;
    const match = /^\s*<send_user_message_question_reply>\s*([\s\S]*?)\s*<\/send_user_message_question_reply>\s*$/.exec(block.text);
    if (!match) continue;
    try {
      const decoded: unknown = JSON.parse(match[1]!);
      const replies = Array.isArray(decoded) ? decoded : [decoded];
      if (replies.length > 32) continue;
      for (const reply of replies) {
        if (!isRecord(reply) || typeof reply.questionItemId !== "string" || typeof reply.answer !== "string") continue;
        let target: unknown;
        try { target = JSON.parse(reply.questionItemId); }
        catch { continue; }
        if (Array.isArray(target) && target.length === 3
          && ["request_user_input_async", "functions.request_user_input_async"].includes(target[0])
          && typeof target[1] === "string" && target[1].length > 0 && target[1].length <= 512
          && Number.isInteger(target[2]) && target[2] >= 0 && target[2] < 32) {
          result.push({ callId: target[1], index: target[2] });
        }
      }
    } catch { /* Ordinary text and malformed replies cannot acknowledge a question. */ }
  }
  return result;
}

function isTurnProgress(type: unknown, payload: Record<string, unknown>): boolean {
  if (type === "event_msg") {
    return ["agent_message", "agent_reasoning", "item_started", "item_completed", "token_count", "request_user_input"]
      .includes(String(payload.type));
  }
  if (type !== "response_item") return false;
  if (payload.type === "message") return payload.role === "assistant";
  return ["reasoning", "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output", "web_search_call"]
    .includes(String(payload.type));
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
    // Progress headers can precede megabytes of answer or tool output. Parse
    // only the complete JSON envelope before its content field, so activity
    // does not depend on answer size or marker-like text inside that content.
    const content = /,\s*"(?:message|item|content|arguments|output|summary)"\s*:/.exec(line);
    if (content) {
      try {
        const header: unknown = JSON.parse(line.slice(0, content.index) + "}}");
        if (isRecord(header) && isRecord(header.payload)
          && (isTurnProgress(header.type, header.payload)
            || (header.type === "response_item" && header.payload.type === "message"
              && header.payload.role === "user"))) return header;
      } catch { /* Nested or unknown layouts are not progress evidence. */ }
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
