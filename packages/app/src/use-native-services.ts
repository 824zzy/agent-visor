import { useCallback, useEffect, useRef, useState } from "react";
import {
  serverMessageSchema,
  type AgentConnection,
  type AppSettingsPatch,
  type NativeServicesState,
} from "@agent-visor/protocol";
import { connectDaemon, type DaemonConnection } from "./daemon-connection";
import { daemonUrl } from "./use-session-snapshot";

export function useNativeServices() {
  const [state, setState] = useState<NativeServicesState>();
  const [error, setError] = useState<string>();
  const connectionRef = useRef<DaemonConnection | undefined>(undefined);

  useEffect(() => {
    const connection = connectDaemon({
      url: daemonUrl(),
      onDisconnect: () => setError("Native services are reconnecting."),
      onOpen: (opened) => {
        opened.send(JSON.stringify({ type: "get_native_services" }));
      },
      onMessage: (raw) => {
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
      },
    });
    connectionRef.current = connection;
    return () => {
      connectionRef.current = undefined;
      connection.close();
    };
  }, []);

  const send = useCallback((message: object) => {
    const connection = connectionRef.current;
    if (!connection?.send(JSON.stringify(message))) {
      setError("Native services are still connecting.");
    }
  }, []);

  const update = useCallback((patch: AppSettingsPatch) => send({
    type: "update_settings",
    id: crypto.randomUUID(),
    patch,
  }), [send]);
  const act = useCallback((action: "request_accessibility" | "open_accessibility_settings"
    | "request_notifications" | "check_updates" | "open_update") => send({
      type: "native_service_action",
      id: crypto.randomUUID(),
      action,
    }), [send]);
  const setAgentConnection = useCallback((
    agent: Extract<AgentConnection["id"], "claude" | "auggie" | "codex">,
    enabled: boolean,
  ) => send(agentConnectionRequest(agent, enabled, crypto.randomUUID())), [send]);

  return { state, error, update, act, setAgentConnection };
}

export function agentConnectionRequest(
  agent: "claude" | "auggie" | "codex",
  enabled: boolean,
  id: string,
) {
  return { type: "set_agent_connection" as const, id, agent, enabled };
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
