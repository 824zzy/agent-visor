import { describe, expect, it } from "vitest";
import { sessionSnapshotFromServerData } from "./use-session-snapshot.js";

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
});
