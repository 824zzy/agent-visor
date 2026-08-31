import { useCallback, useEffect, useRef, useState } from "react";
import {
  serverMessageSchema,
  type ChatImage,
  type ChatCommands,
  type ClientMessage,
  type SessionSection,
} from "@agent-visor/protocol";
import { connectDaemon, type DaemonConnection } from "./daemon-connection";
import { createChatSessionController, type ChatSessionState } from "./chat-session-controller";
import { daemonUrl } from "./use-session-snapshot";
import { CHAT_DELIVERY_TTL_MS, type PendingChatDelivery } from "./chat-delivery";
import { CHAT_INITIAL_PAGE_LIMIT } from "./chat-pagination-window";

type ChatState = ChatSessionState;

export function useChat(sessionId: string, section: SessionSection = "history") {
  const [state, setState] = useState<ChatState>({ sessionId, status: "loading" });
  const socket = useRef<DaemonConnection | undefined>(undefined);
  const slashCommandRequestSent = useRef(false);
  const [slashCommands, setSlashCommands] = useState<{
    sessionId: string;
    commands?: ChatCommands;
    error?: string;
  }>({ sessionId });
  const activeGeneration = useRef(0);
  const controller = useRef(createChatSessionController({
    onState: setState,
    onSlashCommands: (commands, currentSessionId, error) => {
      if (error || commands) slashCommandRequestSent.current = false;
      setSlashCommands({
        sessionId: currentSessionId,
        commands,
        error,
      });
    },
    onOpenLatest: (connection, currentSessionId, requestId) => {
      connection.send(JSON.stringify({
        type: "open_chat",
        id: requestId,
        sessionId: currentSessionId,
        generation: activeGeneration.current,
        limit: CHAT_INITIAL_PAGE_LIMIT,
      }));
    },
  })).current;
  const deliveryExpiryScheduler = useRef(createChatDeliveryExpiryScheduler({
    getExpiry: (generation) => controller.nextDeliveryExpiry(generation),
    expire: (generation) => controller.expireDeliveries(generation),
  })).current;

  useEffect(() => {
    const generation = controller.activate(sessionId, section);
    activeGeneration.current = generation;
    let connection: DaemonConnection;
    connection = connectDaemon({
      url: daemonUrl(),
      onDisconnect: () => {
        slashCommandRequestSent.current = false;
        controller.disconnect(generation);
      },
      onOpen: (opened) => {
        opened.send(JSON.stringify({ type: "subscribe_sessions" }));
        const requestId = crypto.randomUUID();
        controller.requestLatest(activeGeneration.current, requestId);
        opened.send(JSON.stringify({
          type: "open_chat",
          id: requestId,
          sessionId,
          generation: activeGeneration.current,
          limit: CHAT_INITIAL_PAGE_LIMIT,
        }));
      },
      onMessage: (data) => {
        controller.receive(generation, data, connection);
        deliveryExpiryScheduler.schedule(generation);
      },
    });
    socket.current = connection;

    return () => {
      controller.deactivate(generation);
      deliveryExpiryScheduler.clear();
      connection.close();
      socket.current = undefined;
      slashCommandRequestSent.current = false;
    };
  }, [controller, deliveryExpiryScheduler, sessionId]);

  useEffect(() => {
    controller.setSection(activeGeneration.current, section);
  }, [controller, section]);

  const visibleState = state.sessionId === sessionId
    ? state
    : { sessionId, status: "loading" as const };
  const visibleSlashCommands = slashCommands.sessionId === sessionId
    ? slashCommands.commands?.commands
    : undefined;
  const visibleSlashCommandsTruncated = slashCommands.sessionId === sessionId
    ? slashCommands.commands?.truncated ?? false
    : false;
  const visibleSlashCommandsError = slashCommands.sessionId === sessionId
    ? slashCommands.error
    : undefined;

  const sendDelivery = useCallback((delivery: PendingChatDelivery): void => {
    const generation = activeGeneration.current;
    const connection = socket.current;
    const message: ClientMessage = {
      type: "send_chat",
      id: delivery.requestId,
      sessionId,
      generation,
      deliveryId: delivery.deliveryId,
      text: delivery.draft.text,
      images: delivery.draft.images.flatMap((image) => {
        if (!image.data) return [];
        return [{
          ...image,
          data: image.data,
          byteLength: image.byteLength ?? encodedBase64ByteLength(image.data),
        }];
      }),
    };
    let sent = false;
    try {
      sent = Boolean(connection?.send(JSON.stringify(message)));
    } catch {
      sent = false;
    }
    if (!sent) {
      controller.failDelivery(
        generation,
        delivery.requestId,
        delivery.deliveryId,
        "The message could not be sent.",
      );
    }
    deliveryExpiryScheduler.schedule(generation);
  }, [controller, deliveryExpiryScheduler, sessionId]);

  const send = useCallback((text: string, images: ChatImage[]): boolean => {
    const generation = activeGeneration.current;
    const delivery = controller.beginDelivery(generation, { text, images });
    if (!delivery) return false;
    sendDelivery(delivery);
    return true;
  }, [controller, sendDelivery]);

  const noteComposerDraft = useCallback((draft: { text: string; images: ChatImage[] }) => {
    controller.noteComposerDraft(activeGeneration.current, draft);
  }, [controller]);

  const retryRecovery = useCallback((recoveryId: string) => {
    const retry = controller.retryRecovery(activeGeneration.current, recoveryId);
    if (!retry?.send) return;
    sendDelivery(retry.delivery);
  }, [controller, sendDelivery]);

  const dismissRecovery = useCallback((recoveryId: string) => {
    controller.dismissRecovery(activeGeneration.current, recoveryId);
  }, [controller]);

  const cancelChat = useCallback(() => {
    const connection = socket.current;
    if (!connection) return false;
    return controller.requestCancel(activeGeneration.current, connection);
  }, [controller, sessionId]);

  const cyclePermissionMode = useCallback(() => {
    const connection = socket.current;
    if (!connection) return false;
    return controller.requestCyclePermissionMode(activeGeneration.current, connection);
  }, [controller]);

  const respond = useCallback((message: Omit<Extract<ClientMessage, { type: "respond_chat" }>, "id" | "sessionId">) => {
    const connection = socket.current;
    if (!connection?.send(JSON.stringify({
      ...message,
      type: "respond_chat",
      id: crypto.randomUUID(),
      sessionId,
      generation: activeGeneration.current,
    }))) return;
  }, [sessionId]);

  const loadEarlier = useCallback(() => {
    const connection = socket.current;
    const before = visibleState.page?.nextBefore;
    if (!connection || before === undefined || visibleState.clientHistoryLimitReached) return;
    const requestId = crypto.randomUUID();
    const generation = activeGeneration.current;
    // Reserve before writing to the socket. A fast daemon response must find
    // its request identity, while a failed write must release that cursor so
    // the user can retry it.
    if (!controller.requestEarlier(generation, requestId, before)) return;
    let sent = false;
    try {
      sent = connection.send(JSON.stringify({
        type: "open_chat", id: requestId, sessionId,
        generation, before, limit: CHAT_INITIAL_PAGE_LIMIT,
      }));
    } catch {
      sent = false;
    }
    if (!sent) controller.cancelEarlier(generation, requestId);
  }, [controller, sessionId, visibleState.clientHistoryLimitReached, visibleState.page?.nextBefore]);

  const loadSlashCommands = useCallback(() => {
    const connection = socket.current;
    if (!connection || slashCommandRequestSent.current) return;
    slashCommandRequestSent.current = true;
    const id = crypto.randomUUID();
    controller.requestSlashCommands(activeGeneration.current, id);
    if (!connection.send(JSON.stringify({
      type: "get_chat_commands",
      id,
      sessionId,
    }))) {
      slashCommandRequestSent.current = false;
    }
  }, [sessionId]);

  return {
    ...visibleState,
    loadEarlier,
    loadSlashCommands,
    noteComposerDraft,
    respond,
    cancelChat,
    cyclePermissionMode,
    dismissRecovery,
    retryRecovery,
    send,
    slashCommands: visibleSlashCommands,
    slashCommandsError: visibleSlashCommandsError,
    slashCommandsTruncated: visibleSlashCommandsTruncated,
  };
}

type ChatDeliveryExpiryTimerHandle = ReturnType<typeof setTimeout>;

export type ChatDeliveryExpiryScheduler = {
  schedule(generation: number): void;
  clear(): void;
};

export type ChatDeliveryExpirySchedulerOptions = {
  getExpiry(generation: number): number | undefined;
  expire(generation: number): void;
  now?: () => number;
  schedule?: (run: () => void, delay: number) => ChatDeliveryExpiryTimerHandle;
  cancel?: (handle: ChatDeliveryExpiryTimerHandle) => void;
};

/**
 * Keep expiry scheduling at the hook boundary. The controller owns delivery
 * records and the injected clock; this small seam owns exactly one timer and
 * makes cleanup/session-switch behavior deterministic in tests.
 */
export function createChatDeliveryExpiryScheduler(
  options: ChatDeliveryExpirySchedulerOptions,
): ChatDeliveryExpiryScheduler {
  const now = options.now ?? (() => Date.now());
  const scheduleTimer = options.schedule ?? ((run, delay) => setTimeout(run, delay));
  const cancelTimer = options.cancel ?? ((handle) => clearTimeout(handle));
  let timer: ChatDeliveryExpiryTimerHandle | undefined;

  function clear(): void {
    if (timer === undefined) return;
    cancelTimer(timer);
    timer = undefined;
  }

  function schedule(generation: number): void {
    clear();
    const expiry = options.getExpiry(generation);
    if (expiry === undefined) return;
    // Keep one bounded timer per active generation. The controller owns the
    // records; the hook owns scheduling and cleanup.
    // ponytail: if delivery traffic needs a different cadence, keep this
    // single-timer policy and update the shared TTL guidance with the tests.
    const delay = Math.max(0, Math.min(expiry - now(), CHAT_DELIVERY_TTL_MS));
    timer = scheduleTimer(() => {
      timer = undefined;
      options.expire(generation);
      schedule(generation);
    }, delay);
  }

  return { schedule, clear };
}

export function serverMessageFromData(data: string) {
  try {
    const parsed = serverMessageSchema.safeParse(JSON.parse(data));
    return parsed.success ? parsed.data : undefined;
  } catch {
    return undefined;
  }
}

function encodedBase64ByteLength(value: string): number {
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor(value.length * 3 / 4) - padding);
}
