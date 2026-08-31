import { WebSocket, WebSocketServer } from "ws";
import {
  PROTOCOL_VERSION,
  CHAT_MAX_WIRE_BYTES,
  clientMessageSchema,
  sessionSnapshotSchema,
  type ClientMessage,
  type ChatCommands,
  type NativeServicesState,
  type ServerMessage,
  type SessionSnapshot,
} from "@agent-visor/protocol";
import type { SessionSnapshotSource } from "./sessions.js";
import { sendDaemonMessage } from "./outbound.js";

export interface NativeServicesSource {
  current(): NativeServicesState;
  subscribe(listener: (state: NativeServicesState) => void): () => void;
  action(message: Extract<ClientMessage, {
    type: "update_settings" | "native_service_action" | "set_agent_connection";
  }>): Promise<string | undefined>;
}

export type RunningServer = {
  url: string;
  close: () => Promise<void>;
};

export async function startServer(options: {
  port: number;
  token: string;
  /** Tests may lower the production bound to exercise disconnect handling. */
  maxPayload?: number;
  nativeServices?: NativeServicesSource;
} & (
  | { snapshot: SessionSnapshot; source?: never }
  | { source: SessionSnapshotSource; snapshot?: never }
)): Promise<RunningServer> {
  if (options.token.length < 32) {
    throw new Error("The Agent Visor daemon token must contain at least 32 characters.");
  }
  const maxPayload = options.maxPayload ?? CHAT_MAX_WIRE_BYTES;
  if (!Number.isInteger(maxPayload) || maxPayload <= 0 || maxPayload > CHAT_MAX_WIRE_BYTES) {
    throw new Error("The Agent Visor daemon maxPayload must be a positive value within the protocol bound.");
  }
  const source = options.source ?? fixedSource(sessionSnapshotSchema.parse(options.snapshot));
  const subscribers = new Set<WebSocket>();
  const nativeSubscribers = new Set<WebSocket>();
  const server = new WebSocketServer({
    host: "127.0.0.1",
    port: options.port,
    maxPayload,
    verifyClient: ({ req }, done) => {
      const request = new URL(req.url ?? "/", "ws://127.0.0.1");
      done(request.searchParams.get("token") === options.token, 401, "Unauthorized");
    },
  });

  const unsubscribe = source.subscribe((snapshot) => {
    for (const socket of subscribers) {
      if (socket.readyState === WebSocket.OPEN) {
        sendDaemonMessage(socket, snapshot, { requestType: "session_snapshot" });
      }
    }
  });

  const unsubscribeNative = options.nativeServices?.subscribe((state) => {
    for (const socket of nativeSubscribers) {
      if (socket.readyState === WebSocket.OPEN) {
        sendDaemonMessage(socket, state, { requestType: "native_services_state" });
      }
    }
  });

  server.on("connection", (socket) => {
    sendDaemonMessage(socket, { type: "hello", protocolVersion: PROTOCOL_VERSION });
    socket.on("error", (error) => handleSocketError(socket, error));
    socket.once("close", () => {
      subscribers.delete(socket);
      nativeSubscribers.delete(socket);
    });

    socket.on("message", (data) => {
      void (async () => {
      let value: unknown;
      try {
        value = JSON.parse(data.toString());
      } catch {
        return;
      }

      const parsed = clientMessageSchema.safeParse(value);
      if (!parsed.success) return;

      if (parsed.data.type === "health") {
        sendDaemonMessage(socket, { type: "health", status: "ok" }, { requestType: parsed.data.type });
      } else if (parsed.data.type === "subscribe_sessions") {
        subscribers.add(socket);
        sendDaemonMessage(socket, source.current(), { requestType: parsed.data.type });
      } else if (parsed.data.type === "get_native_services") {
        if (options.nativeServices) {
          nativeSubscribers.add(socket);
          sendDaemonMessage(socket, options.nativeServices.current(), { requestType: parsed.data.type });
        }
      } else if (parsed.data.type === "focus_session") {
        const error = source.focusSession
          ? await source.focusSession(parsed.data.sessionId)
          : "Exact session focus is unavailable.";
        sendDaemonMessage(socket, {
          type: "native_action_result",
          id: parsed.data.id,
          ok: !error,
          ...(error ? { error } : {}),
        }, {
          requestType: parsed.data.type,
          requestId: parsed.data.id,
          sessionId: parsed.data.sessionId,
        });
      } else if (parsed.data.type === "update_settings"
        || parsed.data.type === "native_service_action"
        || parsed.data.type === "set_agent_connection") {
        const error = options.nativeServices
          ? await options.nativeServices.action(parsed.data)
          : "Native services are unavailable.";
        sendDaemonMessage(socket, {
          type: "native_action_result",
          id: parsed.data.id,
          ok: !error,
          ...(error ? { error } : {}),
        }, { requestType: parsed.data.type, requestId: parsed.data.id });
      } else if (parsed.data.type === "open_chat") {
        if (source.chatPage) {
          try {
            source.acknowledgeReady?.(parsed.data.sessionId);
            const page = await source.chatPage(
              parsed.data.sessionId,
              parsed.data.before,
              parsed.data.limit,
              parsed.data.generation,
            );
            sendDaemonMessage(socket, {
              ...page,
              ...(parsed.data.id ? { requestId: parsed.data.id } : {}),
              mode: parsed.data.before === undefined ? "latest" : "earlier",
            }, {
              requestType: parsed.data.type,
              ...(parsed.data.id ? { requestId: parsed.data.id } : {}),
              sessionId: parsed.data.sessionId,
            });
          } catch (error) {
            reportRequestFailure(error);
            sendDaemonMessage(socket, {
              ...failedChatPage(parsed.data.sessionId),
              ...(parsed.data.id ? { requestId: parsed.data.id } : {}),
              mode: parsed.data.before === undefined ? "latest" : "earlier",
            }, {
              requestType: parsed.data.type,
              ...(parsed.data.id ? { requestId: parsed.data.id } : {}),
              sessionId: parsed.data.sessionId,
            });
          }
        }
      } else if (parsed.data.type === "get_chat_commands") {
        try {
          const commands = source.chatCommands
            ? await source.chatCommands(parsed.data.sessionId)
            : emptyChatCommands(parsed.data.sessionId);
          sendDaemonMessage(socket, commands, {
            requestType: parsed.data.type,
            requestId: parsed.data.id,
            sessionId: parsed.data.sessionId,
          });
        } catch (error) {
          reportRequestFailure(error);
          sendDaemonMessage(socket, emptyChatCommands(parsed.data.sessionId), {
            requestType: parsed.data.type,
            requestId: parsed.data.id,
            sessionId: parsed.data.sessionId,
          });
        }
      } else if (parsed.data.type === "send_chat"
        || parsed.data.type === "cancel_chat"
        || parsed.data.type === "respond_chat"
        || parsed.data.type === "cycle_permission_mode") {
        let error: string | undefined;
        try {
          error = source.chatAction
            ? await source.chatAction(parsed.data)
            : "Chat actions are unavailable.";
        } catch (caught) {
          // Always settle an action request. A provider exception must retain
          // the request-scoped identity so the renderer can fail the exact
          // optimistic delivery instead of waiting for its TTL.
          error = caught instanceof Error ? caught.message : "Chat action failed.";
          reportRequestFailure(caught);
        }
        const actionMetadata = parsed.data.type === "cancel_chat" ? {
          action: "cancel" as const,
          sessionId: parsed.data.sessionId,
          generation: parsed.data.generation,
          ...(parsed.data.deliveryId ? { deliveryId: parsed.data.deliveryId } : {}),
        } : parsed.data.type === "send_chat" ? {
          action: "send" as const,
          sessionId: parsed.data.sessionId,
          generation: parsed.data.generation,
          deliveryId: parsed.data.deliveryId,
        } : parsed.data.type === "cycle_permission_mode" ? {
          action: "cycle_permission_mode" as const,
          sessionId: parsed.data.sessionId,
          generation: parsed.data.generation,
        } : {
          action: "respond" as const,
          sessionId: parsed.data.sessionId,
        };
        sendDaemonMessage(socket, {
          type: "chat_action_result",
          id: parsed.data.id,
          ...actionMetadata,
          ok: !error,
          ...(error ? { error } : {}),
        }, {
          requestType: parsed.data.type,
          requestId: parsed.data.id,
          sessionId: parsed.data.sessionId,
        });
      }
      })().catch(reportRequestFailure);
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("listening", resolve);
    server.once("error", reject);
  });

  const address = server.address();
  if (typeof address === "string" || address === null) {
    await closeServer(server);
    throw new Error("The Agent Visor daemon did not receive a TCP port.");
  }

  return {
    url: `ws://127.0.0.1:${address.port}?token=${encodeURIComponent(options.token)}`,
    close: async () => {
      unsubscribe();
      unsubscribeNative?.();
      await closeServer(server);
    },
  };
}

function emptyChatCommands(sessionId: string): ChatCommands {
  return { type: "chat_commands", sessionId, commands: [], truncated: false };
}

function fixedSource(snapshot: SessionSnapshot): SessionSnapshotSource {
  return {
    current: () => structuredClone(snapshot),
    subscribe: () => () => undefined,
  };
}

function failedChatPage(sessionId: string): ServerMessage {
  const readOnlyReason = "Unable to load this conversation record.";
  return {
    type: "chat_page",
    sessionId,
    items: [{
      id: "chat-load-error",
      kind: "system",
      text: readOnlyReason,
      tone: "error",
      category: "other",
    }],
    hasMoreBefore: false,
    capabilities: {
      canSendText: false,
      canSendImages: false,
      canCancel: false,
      canApprove: false,
      canAnswer: false,
      readOnlyReason,
    },
    pendingAction: null,
  };
}

function reportRequestFailure(error: unknown): void {
  console.error(`Agent Visor request failed: ${String(error)}`);
}

function handleSocketError(socket: WebSocket, error: unknown): void {
  if (isPayloadTooLarge(error)) {
    // ws normally sends 1009 itself. This explicit close keeps oversized-frame
    // errors handled when receiver timing differs across Electron/Node builds.
    try { socket.close(1009, "Message too large"); } catch { socket.terminate(); }
    return;
  }
  reportRequestFailure(error);
  socket.terminate();
}

function isPayloadTooLarge(error: unknown): boolean {
  if (typeof error !== "object" || error === null) return false;
  const candidate = error as { code?: unknown; message?: unknown };
  return candidate.code === "WS_ERR_UNSUPPORTED_MESSAGE_LENGTH"
    || (typeof candidate.message === "string" && /max payload size exceeded/i.test(candidate.message));
}

async function closeServer(server: WebSocketServer): Promise<void> {
  for (const client of server.clients) client.terminate();
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}
