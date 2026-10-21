import { useCallback, useEffect, useRef, useState } from "react";
import {
  serverMessageSchema,
  type SessionHistoryPage,
} from "@agent-visor/protocol";
import {
  connectDaemon,
  type DaemonConnection,
  type DaemonConnectionHandlers,
} from "./daemon-connection";
import { daemonUrl } from "./use-session-snapshot";

const HISTORY_PAGE_LIMIT = 100;

export type SessionHistoryState = {
  status: "loading" | "ready";
  page?: SessionHistoryPage;
  loadingMore: boolean;
};

type HistoryConnector = (handlers: DaemonConnectionHandlers) => DaemonConnection;
type HistoryRequest = { cursor?: string; append: boolean; query: string };
type HistoryListener = (state: SessionHistoryState) => void;

/**
 * Stateful public History client. It requests one bounded page at a time,
 * keeps search at the daemon boundary, and refreshes only when a live row
 * disappears from the current snapshot.
 */
export function createSessionHistoryController(
  onState: HistoryListener,
  connect: HistoryConnector = connectDaemon,
): {
  setQuery(query: string): void;
  loadMore(): void;
  observeLiveSessionIDs(ids: readonly string[]): void;
  close(): void;
} {
  let connection: DaemonConnection | undefined;
  let connected = false;
  let closed = false;
  let query = "";
  let state: SessionHistoryState = { status: "loading", loadingMore: false };
  let pending: HistoryRequest | undefined;
  let queued: HistoryRequest | undefined;
  let previousLiveIDs: Set<string> | undefined;

  const publish = (next: SessionHistoryState): void => {
    state = next;
    onState(next);
  };

  const request = (socket: DaemonConnection, next: HistoryRequest): void => {
    if (closed) return;
    if (pending) {
      queued = next;
      return;
    }
    pending = next;
    publish(next.append
      ? { ...state, loadingMore: true }
      : { status: "loading", page: state.page, loadingMore: false });
    const message = {
      type: "get_session_history" as const,
      id: `history-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      ...(next.query ? { query: next.query } : {}),
      ...(next.cursor ? { cursor: next.cursor } : {}),
      limit: HISTORY_PAGE_LIMIT,
    };
    socket.send(JSON.stringify(message));
  };

  const requestCurrent = (next: HistoryRequest): void => {
    if (!connected || !connection) {
      queued = next;
      return;
    }
    request(connection, next);
  };

  const handlePage = (page: SessionHistoryPage): void => {
    const current = pending;
    pending = undefined;
    if (!current) return;
    if (current.query !== query) {
      requestCurrent({ query, append: false });
      return;
    }
    const previousPage = current.append ? state.page : undefined;
    const sessions = current.append && previousPage
      ? mergeHistoryRows(previousPage.sessions, page.sessions)
      : page.sessions;
    publish({
      status: "ready",
      page: { ...page, sessions },
      loadingMore: false,
    });
    const next = queued;
    queued = undefined;
    if (next) requestCurrent(next);
  };

  const client = connect({
    url: daemonUrl(),
    onDisconnect: () => {
      connected = false;
      connection = undefined;
      pending = undefined;
      publish({ ...state, status: "loading", loadingMore: false });
    },
    onMessage: (data) => {
      const parsed = serverMessageSchema.safeParse(parseJSON(data));
      if (parsed.success && parsed.data.type === "session_history_page") handlePage(parsed.data);
    },
    onOpen: (opened) => {
      connection = opened;
      connected = true;
      const next = queued ?? { query, append: false };
      queued = undefined;
      request(opened, next);
    },
  });
  connection = client;

  return {
    setQuery(nextQuery: string): void {
      const next = nextQuery.trim();
      if (next === query && (pending?.query === next || state.status === "ready")) return;
      query = next;
      publish({ status: "loading", page: undefined, loadingMore: false });
      requestCurrent({ query, append: false });
    },
    loadMore(): void {
      if (state.loadingMore || !state.page?.nextCursor) return;
      requestCurrent({ query, cursor: state.page.nextCursor, append: true });
    },
    observeLiveSessionIDs(ids: readonly string[]): void {
      const current = new Set(ids);
      const closedLiveSession = previousLiveIDs !== undefined
        && [...previousLiveIDs].some((id) => !current.has(id));
      previousLiveIDs = current;
      if (closedLiveSession) requestCurrent({ query, append: false });
    },
    close(): void {
      closed = true;
      connected = false;
      pending = undefined;
      queued = undefined;
      client.close();
    },
  };
}

export function useSessionHistory(
  query: string,
  liveSessionIDs: readonly string[],
): SessionHistoryState & { loadMore(): void } {
  const [state, setState] = useState<SessionHistoryState>({ status: "loading", loadingMore: false });
  const controller = useRef<ReturnType<typeof createSessionHistoryController> | undefined>(undefined);
  const liveKey = liveSessionIDs.join("\0");

  useEffect(() => {
    const next = createSessionHistoryController(setState);
    controller.current = next;
    return () => {
      next.close();
      controller.current = undefined;
    };
  }, []);

  useEffect(() => {
    controller.current?.setQuery(query);
  }, [query]);

  useEffect(() => {
    controller.current?.observeLiveSessionIDs(liveSessionIDs);
  }, [liveKey]);

  const loadMore = useCallback(() => controller.current?.loadMore(), []);
  return { ...state, loadMore };
}

function mergeHistoryRows(
  current: SessionHistoryPage["sessions"],
  incoming: SessionHistoryPage["sessions"],
): SessionHistoryPage["sessions"] {
  const rows = new Map(current.map((session) => [session.id, session]));
  for (const session of incoming) rows.set(session.id, session);
  return [...rows.values()];
}

function parseJSON(data: string): unknown {
  try {
    return JSON.parse(data);
  } catch {
    return undefined;
  }
}
