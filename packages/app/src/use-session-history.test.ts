import { describe, expect, it } from "vitest";
import type { DaemonConnection, DaemonConnectionHandlers } from "./daemon-connection.js";
import { createSessionHistoryController } from "./use-session-history.js";

const page = (ids: string[], nextCursor?: string) => ({
  type: "session_history_page" as const,
  sessions: ids.map((id) => ({
    id,
    title: id,
    subtitle: "Closed terminal conversation",
    source: "Claude Code",
    project: "agent-visor",
    owner: "Ghostty",
    cwd: "/Users/me/Codes/agent-visor",
    section: "history" as const,
    sessionClass: "terminal" as const,
    ambientEligible: false,
    updatedAt: "2026-10-21T18:00:00.000Z",
    canOpenOwner: false,
    canEnterChat: false,
    canRemoveHistory: true,
  })),
  total: ids.length,
  ...(nextCursor ? { nextCursor } : {}),
});

function fakeConnection() {
  let handlers!: DaemonConnectionHandlers;
  const sent: string[] = [];
  const connection: DaemonConnection = {
    close: () => undefined,
    send: (data) => { sent.push(data); return true; },
  };
  return {
    sent,
    connection,
    connect: (next: DaemonConnectionHandlers) => {
      handlers = next;
      return connection;
    },
    open: () => handlers.onOpen?.(connection),
    message: (value: unknown) => handlers.onMessage?.(JSON.stringify(value)),
    disconnect: () => handlers.onDisconnect?.(),
  };
}

describe("session history controller", () => {
  it("keeps a durable storage warning alongside live History rows", () => {
    const fake = fakeConnection();
    const states: ReturnType<typeof page>[] = [];
    const controller = createSessionHistoryController((state) => {
      if (state.page) states.push(state.page as ReturnType<typeof page>);
    }, fake.connect);
    fake.open();
    fake.message({
      ...page(["live-row"]),
      historyWarning: "Retained history storage is unavailable.",
    });

    expect(states.at(-1)).toMatchObject({
      sessions: [expect.objectContaining({ id: "live-row" })],
      historyWarning: "Retained history storage is unavailable.",
    });
    controller.close();
  });

  it("searches at the History boundary and joins paginated rows", () => {
    const fake = fakeConnection();
    const states: ReturnType<typeof page>[] = [];
    const controller = createSessionHistoryController((state) => {
      if (state.page) states.push(state.page as ReturnType<typeof page>);
    }, fake.connect);
    fake.open();
    expect(JSON.parse(fake.sent[0]!)).toMatchObject({ type: "get_session_history", limit: 100 });

    fake.message(page(["first"], "1"));
    controller.loadMore();
    expect(JSON.parse(fake.sent[1]!)).toMatchObject({ type: "get_session_history", cursor: "1", limit: 100 });
    fake.message(page(["needle"], undefined));
    expect(states.at(-1)?.sessions.map(({ id }) => id)).toEqual(["first", "needle"]);

    controller.setQuery("needle");
    expect(JSON.parse(fake.sent[2]!)).toMatchObject({ type: "get_session_history", query: "needle", limit: 100 });
    fake.message(page(["needle"], undefined));
    expect(states.at(-1)?.sessions.map(({ id }) => id)).toEqual(["needle"]);
    controller.close();
  });

  it("refreshes the current query when a live conversation closes", () => {
    const fake = fakeConnection();
    const controller = createSessionHistoryController(() => undefined, fake.connect);
    fake.open();
    fake.message(page(["closed"], undefined));
    controller.observeLiveSessionIDs(["live"]);
    controller.observeLiveSessionIDs([]);
    expect(fake.sent).toHaveLength(2);
    expect(JSON.parse(fake.sent[1]!)).toMatchObject({ type: "get_session_history", limit: 100 });
    controller.close();
  });

  it("refreshes retained History after a successful detection retry", () => {
    const fake = fakeConnection();
    const controller = createSessionHistoryController(() => undefined, fake.connect);
    fake.open();
    fake.message(page(["unavailable"]));

    controller.refresh();

    expect(fake.sent).toHaveLength(2);
    expect(JSON.parse(fake.sent[1]!)).toMatchObject({
      type: "get_session_history",
      limit: 100,
    });
    controller.close();
  });

  it("removes a retained row and refreshes only after the daemon confirms success", () => {
    const fake = fakeConnection();
    const states: Array<{ removingSessionID?: string; removeError?: string }> = [];
    const controller = createSessionHistoryController((state) => {
      states.push({ removingSessionID: state.removingSessionID, removeError: state.removeError });
    }, fake.connect);
    fake.open();
    fake.message(page(["closed"]));
    controller.remove("closed");

    expect(JSON.parse(fake.sent[1]!)).toMatchObject({
      type: "remove_history_session",
      sessionId: "closed",
    });
    expect(states.at(-1)).toMatchObject({ removingSessionID: "closed" });
    fake.message({
      type: "history_action_result",
      id: JSON.parse(fake.sent[1]!).id,
      action: "remove",
      sessionId: "closed",
      ok: true,
    });
    expect(JSON.parse(fake.sent[2]!)).toMatchObject({ type: "get_session_history", limit: 100 });
    expect(states.at(-1)).toMatchObject({ removingSessionID: undefined, removeError: undefined });
    controller.close();
  });

  it("keeps the retained row and exposes a daemon removal error", () => {
    const fake = fakeConnection();
    const states: Array<{ removingSessionID?: string; removeError?: string }> = [];
    const controller = createSessionHistoryController((state) => {
      states.push({ removingSessionID: state.removingSessionID, removeError: state.removeError });
    }, fake.connect);
    fake.open();
    fake.message(page(["closed"]));
    controller.remove("closed");
    fake.message({
      type: "history_action_result",
      id: JSON.parse(fake.sent[1]!).id,
      action: "remove",
      sessionId: "closed",
      ok: false,
      error: "Retained history storage is unavailable.",
    });

    expect(fake.sent).toHaveLength(2);
    expect(states.at(-1)).toEqual({
      removingSessionID: undefined,
      removeError: "Retained history storage is unavailable.",
    });
    controller.close();
  });

  it("cancels a repair without refreshing and refreshes after acceptance", () => {
    const fake = fakeConnection();
    const states: Array<{ repairingSessionID?: string; repairError?: string }> = [];
    const controller = createSessionHistoryController((state) => {
      states.push({ repairingSessionID: state.repairingSessionID, repairError: state.repairError });
    }, fake.connect);
    fake.open();
    fake.message(page(["closed"]));

    controller.repair("closed", null);
    const cancelled = JSON.parse(fake.sent[1]!);
    expect(cancelled).toMatchObject({ type: "repair_history_session", sessionId: "closed", selection: null });
    fake.message({
      type: "history_action_result",
      id: cancelled.id,
      action: "repair",
      sessionId: "closed",
      state: "cancelled",
      ok: true,
    });
    expect(fake.sent).toHaveLength(2);
    expect(states.at(-1)).toEqual({ repairingSessionID: undefined, repairError: undefined });

    controller.repair("closed", { kind: "provider", executableRef: "/tmp/claude" });
    const accepted = JSON.parse(fake.sent[2]!);
    fake.message({
      type: "history_action_result",
      id: accepted.id,
      action: "repair",
      sessionId: "closed",
      state: "accepted",
      ok: true,
    });
    expect(JSON.parse(fake.sent[3]!)).toMatchObject({ type: "get_session_history", limit: 100 });
    expect(states.at(-1)).toEqual({ repairingSessionID: undefined, repairError: undefined });
    controller.close();
  });
});
