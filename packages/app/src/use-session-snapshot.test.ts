import { describe, expect, it } from "vitest";
import {
  mergeSessionHistory,
  observeSessionSnapshots,
  sessionHistoryPageFromServerData,
  sessionSnapshotFromServerData,
  type ConnectionState,
} from "./use-session-snapshot.js";
import type { DaemonConnectionHandlers } from "./daemon-connection.js";

const snapshot = {
  type: "session_snapshot",
  revision: 1,
  sessions: [],
};

const historyPage = {
  type: "session_history_page",
  sessions: [{
    id: "closed-1",
    title: "Closed Claude conversation",
    subtitle: "Closed terminal conversation",
    source: "Claude Code",
    project: "agent-visor",
    owner: "Ghostty",
    cwd: "/Users/me/Codes/agent-visor",
    section: "history",
    sessionClass: "terminal",
    ambientEligible: false,
    updatedAt: "2026-10-21T18:00:00.000Z",
    canOpenOwner: false,
    canEnterChat: false,
  }],
  total: 1,
} as const;

describe("sessionSnapshotFromServerData", () => {
  it("returns only a validated session snapshot", () => {
    expect(sessionSnapshotFromServerData(JSON.stringify(snapshot))).toEqual(snapshot);
    expect(
      sessionSnapshotFromServerData(JSON.stringify({ type: "health", status: "ok" })),
    ).toBeUndefined();
  });

  it("ignores malformed daemon data", () => {
    expect(sessionSnapshotFromServerData("not-json")).toBeUndefined();
    expect(
      sessionSnapshotFromServerData(JSON.stringify({ ...snapshot, revision: -1 })),
    ).toBeUndefined();
  });

  it("parses a retained History page separately from the ambient snapshot", () => {
    expect(sessionHistoryPageFromServerData(JSON.stringify(historyPage))).toEqual(historyPage);
    expect(sessionHistoryPageFromServerData(JSON.stringify(snapshot))).toBeUndefined();
  });

  it("merges fetched History into the browser without replacing live rows", () => {
    const live = [{
      ...historyPage.sessions[0],
      id: "shared",
      title: "Live conversation",
      section: "ready" as const,
      ambientEligible: true,
    }];
    const history = {
      ...historyPage,
      sessions: [historyPage.sessions[0], { ...historyPage.sessions[0], id: "shared", title: "Stale copy" }],
      total: 2,
    };
    expect(mergeSessionHistory(live, history).map(({ id, title }) => [id, title]))
      .toEqual([["shared", "Live conversation"], ["closed-1", "Closed Claude conversation"]]);
  });

  it("stops presenting the cached snapshot as live while the daemon reconnects", () => {
    const states: ConnectionState[] = [];
    const sent: string[] = [];
    let handlers: DaemonConnectionHandlers | undefined;
    let closed = false;
    const stop = observeSessionSnapshots((state) => states.push(state), (next) => {
      handlers = next;
      return {
        close: () => { closed = true; },
        send: (data) => { sent.push(data); return true; },
      };
    });

    handlers?.onOpen?.({
      close: () => { closed = true; },
      send: (data) => { sent.push(data); return true; },
    });
    handlers?.onMessage?.(JSON.stringify(snapshot));
    expect(states.at(-1)).toEqual({ status: "connected", snapshot });

    handlers?.onDisconnect?.();
    expect(states.at(-1)).toEqual({ status: "connecting" });

    handlers?.onOpen?.({
      close: () => { closed = true; },
      send: (data) => { sent.push(data); return true; },
    });
    handlers?.onMessage?.(JSON.stringify({ ...snapshot, revision: 2 }));
    expect(states.at(-1)).toMatchObject({ status: "connected", snapshot: { revision: 2 } });
    expect(sent).toEqual([
      JSON.stringify({ type: "subscribe_sessions" }),
      JSON.stringify({ type: "subscribe_sessions" }),
    ]);

    stop();
    expect(closed).toBe(true);
  });
});
