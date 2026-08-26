import { useCallback, useEffect, useRef, useState } from "react";
import {
  serverMessageSchema,
  type ChatImage,
  type ChatPage,
  type ClientMessage,
} from "@agent-visor/protocol";
import { mergeChatPage } from "./chat-presentation";
import { daemonUrl } from "./use-session-snapshot";

type ChatState = {
  status: "loading" | "loaded" | "failed";
  page?: ChatPage;
  error?: string;
};

export function useChat(sessionId: string) {
  const [state, setState] = useState<ChatState>({ status: "loading" });
  const socket = useRef<WebSocket | undefined>(undefined);
  const nextPageMode = useRef<"latest" | "earlier">("latest");
  const latestUpdatedAt = useRef<string | undefined>(undefined);

  useEffect(() => {
    const connection = new WebSocket(daemonUrl());
    socket.current = connection;
    const openLatest = () => {
      nextPageMode.current = "latest";
      connection.send(JSON.stringify({ type: "open_chat", sessionId, limit: 500 }));
    };
    connection.addEventListener("open", () => {
      connection.send(JSON.stringify({ type: "subscribe_sessions" }));
      openLatest();
    });
    connection.addEventListener("message", (event) => {
      const message = serverMessageFromData(String(event.data));
      if (!message) return;
      if (message.type === "chat_page" && message.sessionId === sessionId) {
        const mode = nextPageMode.current;
        setState((current) => ({
          status: "loaded",
          page: mergeChatPage(current.page, message, mode),
        }));
        nextPageMode.current = "latest";
      }
      if (message.type === "session_snapshot") {
        const updatedAt = message.sessions.find(({ id }) => id === sessionId)?.updatedAt;
        if (latestUpdatedAt.current && updatedAt && latestUpdatedAt.current !== updatedAt
          && nextPageMode.current !== "earlier") openLatest();
        latestUpdatedAt.current = updatedAt;
      }
      if (message.type === "chat_action_result") {
        setState((current) => ({ ...current, error: message.ok ? undefined : message.error }));
        if (message.ok) openLatest();
      }
    });
    connection.addEventListener("error", () => setState({ status: "failed" }));
    return () => {
      connection.close();
      socket.current = undefined;
    };
  }, [sessionId]);

  const send = useCallback((text: string, images: ChatImage[]) => {
    const connection = socket.current;
    if (!connection || connection.readyState !== WebSocket.OPEN) return;
    const id = crypto.randomUUID();
    const message: ClientMessage = {
      type: "send_chat",
      id,
      sessionId,
      text,
      images: images.flatMap((image) => image.data ? [{ ...image, data: image.data }] : []),
    };
    setState((current) => current.page ? ({
      ...current,
      page: {
        ...current.page,
        items: [...current.page.items, {
          id: `pending-${id}`,
          kind: "user",
          text,
          images,
          timestamp: new Date().toISOString(),
        }],
      },
      error: undefined,
    }) : current);
    connection.send(JSON.stringify(message));
  }, [sessionId]);

  const respond = useCallback((message: Omit<Extract<ClientMessage, { type: "respond_chat" }>, "id" | "sessionId">) => {
    const connection = socket.current;
    if (!connection || connection.readyState !== WebSocket.OPEN) return;
    connection.send(JSON.stringify({
      ...message,
      type: "respond_chat",
      id: crypto.randomUUID(),
      sessionId,
    }));
  }, [sessionId]);

  const loadEarlier = useCallback(() => {
    const connection = socket.current;
    const before = state.page?.nextBefore;
    if (!connection || connection.readyState !== WebSocket.OPEN || before === undefined) return;
    nextPageMode.current = "earlier";
    connection.send(JSON.stringify({ type: "open_chat", sessionId, before, limit: 500 }));
  }, [sessionId, state.page?.nextBefore]);

  return { ...state, loadEarlier, respond, send };
}

export function serverMessageFromData(data: string) {
  try {
    const parsed = serverMessageSchema.safeParse(JSON.parse(data));
    return parsed.success ? parsed.data : undefined;
  } catch {
    return undefined;
  }
}
