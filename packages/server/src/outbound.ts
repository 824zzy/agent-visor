import {
  CHAT_MAX_WIRE_BYTES,
  daemonErrorSchema,
  serverMessageSchema,
  type DaemonError,
  type ServerMessage,
} from "@agent-visor/protocol";

export type DaemonSendContext = {
  requestType?: string;
  requestId?: string;
  sessionId?: string;
};

export type DaemonSendSocket = {
  send(data: string): void;
};

export type SerializedDaemonMessage = {
  data: string;
  message: ServerMessage;
  usedFallback: boolean;
};

/** Keep test-only lower limits inside the production protocol ceiling. */
export function daemonWireLimit(maxBytes = CHAT_MAX_WIRE_BYTES): number {
  if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0) return CHAT_MAX_WIRE_BYTES;
  return Math.min(maxBytes, CHAT_MAX_WIRE_BYTES);
}

/**
 * Validate and serialize every daemon-bound message before it reaches a socket.
 * The optional limit is test-only; production always uses the protocol bound.
 */
export function serializeDaemonMessage(
  value: unknown,
  context: DaemonSendContext = {},
  maxBytes = CHAT_MAX_WIRE_BYTES,
): SerializedDaemonMessage {
  const errorContext = contextFor(value, context);
  const limit = daemonWireLimit(maxBytes);
  const parsed = serverMessageSchema.safeParse(value);
  if (!parsed.success) {
    return fallback("invalid_response", errorContext);
  }

  let data: string;
  try {
    data = JSON.stringify(parsed.data);
  } catch {
    return fallback("serialization_failed", errorContext);
  }
  if (Buffer.byteLength(data, "utf8") > limit) {
    return fallback("response_too_large", errorContext);
  }
  return { data, message: parsed.data, usedFallback: false };
}

/**
 * The only production socket-send seam. Callers cannot accidentally bypass
 * protocol validation or the outbound wire ceiling.
 */
export function sendDaemonMessage(
  socket: DaemonSendSocket,
  value: unknown,
  context: DaemonSendContext = {},
  maxBytes = CHAT_MAX_WIRE_BYTES,
): boolean {
  const serialized = serializeDaemonMessage(value, context, maxBytes);
  try {
    socket.send(serialized.data);
    return true;
  } catch {
    return false;
  }
}

function fallback(
  code: DaemonError["code"],
  context: DaemonSendContext & { responseType?: string },
): SerializedDaemonMessage {
  // ponytail: if the daemon wire ceiling changes, keep this fallback small
  // enough to report an outbound failure without another oversized response.
  const message = code === "response_too_large"
    ? "Daemon response exceeded the protocol wire limit."
    : code === "invalid_response"
      ? "Daemon produced an invalid protocol response."
      : "Daemon response could not be serialized.";
  const error = daemonErrorSchema.parse({
    type: "daemon_error",
    code,
    message,
    ...(context.responseType ? { responseType: context.responseType } : {}),
    ...(context.requestType ? { requestType: context.requestType } : {}),
    ...(context.requestId ? { requestId: context.requestId } : {}),
    ...(context.sessionId ? { sessionId: context.sessionId } : {}),
  });
  return {
    data: JSON.stringify(error),
    message: error,
    usedFallback: true,
  };
}

function contextFor(
  value: unknown,
  context: DaemonSendContext,
): DaemonSendContext & { responseType?: string } {
  const record = isRecord(value) ? value : undefined;
  return {
    responseType: boundedString(record?.type, 64),
    requestType: boundedString(context.requestType, 64),
    requestId: boundedString(context.requestId, 128) ?? boundedString(record?.id, 128),
    sessionId: boundedString(context.sessionId, 512) ?? boundedString(record?.sessionId, 512),
  };
}

function boundedString(value: unknown, maximum: number): string | undefined {
  return typeof value === "string" && value.length > 0 && value.length <= maximum ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
