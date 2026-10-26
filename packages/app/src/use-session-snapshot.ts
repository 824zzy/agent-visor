import { useEffect, useState } from "react";
import {
  serverMessageSchema,
  type SessionHistoryPage,
  type SessionSnapshot,
  type SessionSummary,
} from "@agent-visor/protocol";
import {
  connectDaemon,
  type DaemonConnection,
  type DaemonConnectionHandlers,
} from "./daemon-connection";

export type ConnectionState =
  | { status: "connecting"; snapshot?: undefined }
  | { status: "connected"; snapshot: SessionSnapshot }
  | { status: "failed"; snapshot?: undefined };

type DaemonConnector = (handlers: DaemonConnectionHandlers) => DaemonConnection;

export function useSessionSnapshot(): ConnectionState {
  const [state, setState] = useState<ConnectionState>({ status: "connecting" });

  useEffect(() => observeSessionSnapshots(setState), []);

  return state;
}

export function observeSessionSnapshots(
  onState: (state: ConnectionState) => void,
  connect: DaemonConnector = connectDaemon,
): () => void {
  const connection = connect({
    url: daemonUrl(),
    onDisconnect: () => onState({ status: "connecting" }),
    onMessage: (data) => {
      const snapshot = sessionSnapshotFromServerData(data);
      if (snapshot) onState({ status: "connected", snapshot });
    },
    onOpen: (opened) => {
      opened.send(JSON.stringify({ type: "subscribe_sessions" }));
    },
  });
  return () => connection.close();
}

export async function focusSession(sessionId: string): Promise<{ ok: boolean; error?: string }> {
  return new Promise((resolve) => {
    const socket = new WebSocket(daemonUrl());
    const id = `focus-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const deadline = setTimeout(() => finish({ ok: false }), 5_000);
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ type: "focus_session", id, sessionId }));
    });
    socket.addEventListener("message", (event) => {
      try {
        const parsed = serverMessageSchema.safeParse(JSON.parse(String(event.data)));
        if (parsed.success && parsed.data.type === "native_action_result" && parsed.data.id === id) {
          finish({ ok: parsed.data.ok, ...(parsed.data.error ? { error: parsed.data.error } : {}) });
        }
      } catch { /* wait for a valid result */ }
    });
    socket.addEventListener("error", () => finish({ ok: false }));

    function finish(result: { ok: boolean; error?: string }): void {
      clearTimeout(deadline);
      socket.close();
      resolve(result);
    }
  });
}

/** Retry only the explicit detection action; this never focuses or acknowledges a session. */
export async function retryDetection(sessionId: string): Promise<{ ok: boolean; error?: string }> {
  return new Promise((resolve) => {
    const socket = new WebSocket(daemonUrl());
    const id = `retry-detection-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const deadline = setTimeout(() => finish({ ok: false }), 5_000);
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ type: "retry_detection", id, sessionId }));
    });
    socket.addEventListener("message", (event) => {
      try {
        const parsed = serverMessageSchema.safeParse(JSON.parse(String(event.data)));
        if (parsed.success && parsed.data.type === "native_action_result" && parsed.data.id === id) {
          finish({ ok: parsed.data.ok, ...(parsed.data.error ? { error: parsed.data.error } : {}) });
        }
      } catch { /* wait for a valid result */ }
    });
    socket.addEventListener("error", () => finish({ ok: false }));

    function finish(result: { ok: boolean; error?: string }): void {
      clearTimeout(deadline);
      socket.close();
      resolve(result);
    }
  });
}

export type ResumeActionState = "focused" | "matched" | "joined" | "reopening" | "unavailable" | "uncertain";

export async function resumeSession(sessionId: string): Promise<{
  ok: boolean;
  state: ResumeActionState;
  error?: string;
}> {
  return new Promise((resolve) => {
    const socket = new WebSocket(daemonUrl());
    const id = `resume-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const deadline = setTimeout(() => finish({ ok: false, state: "uncertain" }), 15_000);
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ type: "resume_session", id, sessionId }));
    });
    socket.addEventListener("message", (event) => {
      try {
        const parsed = serverMessageSchema.safeParse(JSON.parse(String(event.data)));
        if (parsed.success && parsed.data.type === "resume_action_result" && parsed.data.id === id) {
          finish({
            ok: parsed.data.ok,
            state: parsed.data.state,
            ...(parsed.data.error ? { error: parsed.data.error } : {}),
          });
        }
      } catch { /* wait for a valid result */ }
    });
    socket.addEventListener("error", () => finish({ ok: false, state: "uncertain" }));

    function finish(result: { ok: boolean; state: ResumeActionState; error?: string }): void {
      clearTimeout(deadline);
      socket.close();
      resolve(result);
    }
  });
}

export function sessionSnapshotFromServerData(data: string): SessionSnapshot | undefined {
  try {
    const parsed = serverMessageSchema.safeParse(parseJSON(data));
    return parsed.success && parsed.data.type === "session_snapshot"
      ? parsed.data
      : undefined;
  } catch {
    return undefined;
  }
}

export function sessionHistoryPageFromServerData(data: string): SessionHistoryPage | undefined {
  try {
    const parsed = serverMessageSchema.safeParse(parseJSON(data));
    return parsed.success && parsed.data.type === "session_history_page"
      ? parsed.data
      : undefined;
  } catch {
    return undefined;
  }
}

/** Merge fetched History into the browser only; live snapshots stay untouched. */
export function mergeSessionHistory(
  live: SessionSummary[],
  history: SessionHistoryPage | undefined,
): SessionSummary[] {
  const sessions = new Map(live.map((session) => [session.id, session]));
  for (const session of history?.sessions ?? []) {
    const current = sessions.get(session.id);
    if (!current || shouldPreferRetainedHistory(session, current)) sessions.set(session.id, session);
  }
  return [...sessions.values()];
}

function shouldPreferRetainedHistory(history: SessionSummary, live: SessionSummary): boolean {
  // The summary carries only provider/route facts. Never use a matching title,
  // cwd, or recency to transfer a retained CLI origin to a catalog row.
  if (history.source !== "Codex" || history.owner !== "Codex CLI"
    || history.sessionClass !== "terminal" || history.ambientEligible !== false
    || history.canOpenOwner) return false;
  if (live.source !== "Codex" || hasExactLiveTerminalRoute(live)) return false;
  // A Codex catalog row is a non-terminal, unowned projection even when a
  // configured home gives it a presentation label such as "Codex · Copilot".
  // Route ownership is the source fact; labels never transfer provenance.
  const catalogOnly = (live.sessionClass !== "terminal" && live.canOpenOwner
    && live.sessionState?.routeOwnership !== "owned")
    || (live.owner === "Codex CLI" && !live.canOpenOwner);
  if (!catalogOnly) return false;
  return true;
}

function hasExactLiveTerminalRoute(session: SessionSummary): boolean {
  return session.canOpenOwner
    && session.sessionClass === "terminal"
    && ["Ghostty", "Herdr", "cmux", "iTerm2", "Terminal", "Codex CLI"].includes(session.owner);
}

function parseJSON(data: string): unknown {
  try {
    return JSON.parse(data);
  } catch {
    return undefined;
  }
}

export function daemonUrl(): string {
  if (typeof window === "undefined") return "ws://127.0.0.1:6768";
  return window.agentVisor?.daemonUrl ?? "ws://127.0.0.1:6768";
}
