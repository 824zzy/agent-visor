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
