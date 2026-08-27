import { describe, expect, it } from "vitest";
import {
  observeSessionSnapshots,
  sessionSnapshotFromServerData,
  type ConnectionState,
} from "./use-session-snapshot.js";
import type { DaemonConnectionHandlers } from "./daemon-connection.js";

const snapshot = {
  type: "session_snapshot",
  revision: 1,
  sessions: [],
};

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
