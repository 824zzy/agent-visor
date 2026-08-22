import { describe, expect, it } from "vitest";
import {
  PROTOCOL_VERSION,
  serverMessageSchema,
  sessionSnapshotSchema,
} from "./index.js";

describe("session snapshot protocol", () => {
  it("accepts one complete macOS session summary", () => {
    const snapshot = {
      type: "session_snapshot",
      revision: 7,
      sessions: [
        {
          id: "pi-123",
          title: "Fix provider timeout",
          subtitle: "Waiting for review",
          source: "Pi",
          project: "agent-visor",
          owner: "Ghostty",
          cwd: "/Users/me/Codes/agent-visor",
          section: "ready",
          updatedAt: "2026-08-22T08:00:00.000Z",
          canOpenOwner: true,
          canEnterChat: true,
        },
      ],
    };

    expect(sessionSnapshotSchema.parse(snapshot)).toEqual(snapshot);
  });

  it("rejects unknown sections instead of inventing UI state", () => {
    expect(() =>
      sessionSnapshotSchema.parse({
        type: "session_snapshot",
        revision: 1,
        sessions: [{ section: "almost_done" }],
      }),
    ).toThrow();
  });

  it("validates the versioned hello message", () => {
    expect(
      serverMessageSchema.parse({
        type: "hello",
        protocolVersion: PROTOCOL_VERSION,
      }),
    ).toEqual({ type: "hello", protocolVersion: 1 });
  });
});
