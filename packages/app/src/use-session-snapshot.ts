import { useEffect, useState } from "react";
import {
  serverMessageSchema,
  type SessionSnapshot,
} from "@agent-visor/protocol";

type ConnectionState =
  | { status: "connecting"; snapshot?: undefined }
  | { status: "connected"; snapshot: SessionSnapshot }
  | { status: "failed"; snapshot?: undefined };

export function useSessionSnapshot(): ConnectionState {
  const [state, setState] = useState<ConnectionState>({ status: "connecting" });

  useEffect(() => {
    const socket = new WebSocket(daemonUrl());

    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ type: "subscribe_sessions" }));
    });
    socket.addEventListener("message", (event) => {
      const snapshot = sessionSnapshotFromServerData(String(event.data));
      if (snapshot) setState({ status: "connected", snapshot });
    });
    socket.addEventListener("error", () => setState({ status: "failed" }));

    return () => socket.close();
  }, []);

  return state;
}

export async function focusSession(sessionId: string): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = new WebSocket(daemonUrl());
    const id = `focus-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const deadline = setTimeout(() => finish(false), 5_000);
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ type: "focus_session", id, sessionId }));
    });
    socket.addEventListener("message", (event) => {
      try {
        const parsed = serverMessageSchema.safeParse(JSON.parse(String(event.data)));
        if (parsed.success && parsed.data.type === "native_action_result" && parsed.data.id === id) {
          finish(parsed.data.ok);
        }
      } catch { /* wait for a valid result */ }
    });
    socket.addEventListener("error", () => finish(false));

    function finish(result: boolean): void {
      clearTimeout(deadline);
      socket.close();
      resolve(result);
    }
  });
}

export function sessionSnapshotFromServerData(data: string): SessionSnapshot | undefined {
  try {
    const parsed = serverMessageSchema.safeParse(JSON.parse(data));
    return parsed.success && parsed.data.type === "session_snapshot"
      ? parsed.data
      : undefined;
  } catch {
    return undefined;
  }
}

export function daemonUrl(): string {
  if (typeof window === "undefined") return "ws://127.0.0.1:6768";
  return window.agentVisor?.daemonUrl ?? "ws://127.0.0.1:6768";
}
