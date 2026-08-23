import { useCallback, useEffect, useRef, useState } from "react";
import {
  serverMessageSchema,
  type AppSettingsPatch,
  type NativeServicesState,
} from "@agent-visor/protocol";
import { daemonUrl } from "./use-session-snapshot";

export function useNativeServices() {
  const [state, setState] = useState<NativeServicesState>();
  const [error, setError] = useState<string>();
  const socketRef = useRef<WebSocket | undefined>(undefined);

  useEffect(() => {
    const socket = new WebSocket(daemonUrl());
    socketRef.current = socket;
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ type: "get_native_services" }));
    });
    socket.addEventListener("message", (event) => {
      const raw = String(event.data);
      const next = nativeServicesFromServerData(raw);
      if (next) {
        setState(next);
        setError(undefined);
        return;
      }
      try {
        const parsed = serverMessageSchema.safeParse(JSON.parse(raw));
        if (parsed.success && parsed.data.type === "native_action_result" && !parsed.data.ok) {
          setError(parsed.data.error ?? "The native action failed.");
        }
      } catch { /* ignore unrelated daemon messages */ }
    });
    socket.addEventListener("error", () => setError("Native services are unavailable."));
    return () => {
      socketRef.current = undefined;
      socket.close();
    };
  }, []);

  const send = useCallback((message: object) => {
    const socket = socketRef.current;
    if (socket?.readyState !== WebSocket.OPEN) {
      setError("Native services are still connecting.");
      return;
    }
    socket.send(JSON.stringify(message));
  }, []);

  return {
    state,
    error,
    update: (patch: AppSettingsPatch) => send({
      type: "update_settings",
      id: crypto.randomUUID(),
      patch,
    }),
    act: (action: "request_accessibility" | "open_accessibility_settings"
      | "request_notifications" | "check_updates" | "open_update") => send({
      type: "native_service_action",
      id: crypto.randomUUID(),
      action,
    }),
  };
}

export function nativeServicesFromServerData(data: string): NativeServicesState | undefined {
  try {
    const parsed = serverMessageSchema.safeParse(JSON.parse(data));
    return parsed.success && parsed.data.type === "native_services_state"
      ? parsed.data : undefined;
  } catch {
    return undefined;
  }
}
