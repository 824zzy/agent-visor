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

  it("preserves retained Codex CLI provenance over a Desktop catalog copy with the same id", () => {
    const id = "codex:native:shared-cli-desktop";
    const live = {
      ...historyPage.sessions[0],
      id,
      title: "Desktop catalog copy",
      source: "Codex",
      owner: "Codex",
      sessionClass: "interactive" as const,
      section: "history" as const,
      canOpenOwner: true,
      canEnterChat: true,
      ambientEligible: undefined,
    };
    const history = {
      ...historyPage,
      sessions: [{
        ...historyPage.sessions[0],
        id,
        title: "CLI conversation",
        source: "Codex",
        owner: "Codex CLI",
        sessionClass: "terminal" as const,
        ambientEligible: false,
        canOpenOwner: false,
        canEnterChat: true,
      }],
    };

    expect(mergeSessionHistory([live], history)[0]).toMatchObject({
      id,
      title: "CLI conversation",
      owner: "Codex CLI",
    });
  });

  it("keeps an exact live terminal route ahead of retained Codex CLI provenance", () => {
    const id = "codex:native:shared-cli-live";
    const retained = {
      ...historyPage.sessions[0],
      id,
      source: "Codex",
      owner: "Codex CLI",
      sessionClass: "terminal" as const,
      ambientEligible: false,
      canOpenOwner: false,
      canEnterChat: true,
    };
    const live = {
      ...retained,
      title: "Exact Ghostty route",
      owner: "Ghostty",
      section: "ready" as const,
      ambientEligible: true,
      canOpenOwner: true,
    };

    expect(mergeSessionHistory([live], { ...historyPage, sessions: [retained] })[0]).toMatchObject({
      id,
      title: "Exact Ghostty route",
      owner: "Ghostty",
    });
  });

  it("preserves retained CLI provenance for a configured Codex home label", () => {
    const id = "codex:copilot:shared-cli-custom-home";
    const live = {
      ...historyPage.sessions[0],
      id,
      title: "Custom home catalog copy",
      source: "Codex",
      sourceProfile: "Copilot",
      owner: "Codex · Copilot",
      sessionClass: "interactive" as const,
      canOpenOwner: true,
      canEnterChat: true,
      ambientEligible: undefined,
    };
    const retained = {
      ...historyPage.sessions[0],
      id,
      title: "CLI conversation",
      source: "Codex",
      owner: "Codex CLI",
      sessionClass: "terminal" as const,
      ambientEligible: false,
      canOpenOwner: false,
      canEnterChat: true,
    };

    expect(mergeSessionHistory([live], { ...historyPage, sessions: [retained] })[0]).toMatchObject({
      id,
      owner: "Codex CLI",
      title: "CLI conversation",
    });
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
