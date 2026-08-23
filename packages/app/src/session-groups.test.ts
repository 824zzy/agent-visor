import { describe, expect, it } from "vitest";
import type { SessionSummary } from "@agent-visor/protocol";
import {
  groupSessions,
  moveSessionCursor,
  reconcileSessionCursor,
  relativeSessionAge,
  sessionAction,
  selectSessions,
} from "./session-groups.js";

const session = (
  id: string,
  section: SessionSummary["section"],
  updatedAt: string,
): SessionSummary => ({
  id,
  title: id,
  subtitle: "",
  source: "Pi",
  project: "agent-visor",
  owner: "Ghostty",
  cwd: "/tmp/agent-visor",
  section,
  updatedAt,
  canOpenOwner: true,
  canEnterChat: true,
});

describe("groupSessions", () => {
  it("uses the product section order and sorts recent work first", () => {
    const groups = groupSessions([
      session("older-history", "history", "2026-08-20T10:00:00.000Z"),
      session("working", "working", "2026-08-22T09:00:00.000Z"),
      session("needs-you", "needs_you", "2026-08-22T08:00:00.000Z"),
      session("newer-history", "history", "2026-08-21T10:00:00.000Z"),
      session("ready", "ready", "2026-08-22T07:00:00.000Z"),
    ]);

    expect(groups.map((group) => group.title)).toEqual([
      "Needs you",
      "Ready to continue",
      "In progress",
      "History",
    ]);
    expect(groups[3]?.sessions.map(({ id }) => id)).toEqual([
      "newer-history",
      "older-history",
    ]);
  });

  it("omits empty sections", () => {
    expect(
      groupSessions([
        session("working", "working", "2026-08-22T09:00:00.000Z"),
      ]).map(({ title }) => title),
    ).toEqual(["In progress"]);
  });

  it("uses source-first actions with capability-safe fallbacks", () => {
    const both = session("both", "working", "2026-08-22T10:00:00.000Z");
    const chatOnly = { ...both, canOpenOwner: false };
    const ownerOnly = { ...both, canEnterChat: false };
    const neither = { ...ownerOnly, canOpenOwner: false };

    expect(sessionAction(both)).toBe("owner");
    expect(sessionAction(both, true)).toBe("chat");
    expect(sessionAction(chatOnly)).toBe("chat");
    expect(sessionAction(ownerOnly, true)).toBe("owner");
    expect(sessionAction(neither)).toBeUndefined();
  });

  it("reveals only explicit cursor and query moves", () => {
    expect(reconcileSessionCursor("second", ["first", "second"], ["first", "second"], "background"))
      .toEqual({ cursorId: "second" });
    expect(reconcileSessionCursor("second", ["first", "second"], ["first"], "background"))
      .toEqual({ cursorId: "first" });
    expect(reconcileSessionCursor("second", ["first", "second"], ["third", "first"], "query"))
      .toEqual({ cursorId: "third", revealId: "third" });
    expect(moveSessionCursor("first", ["first", "second"], 1))
      .toEqual({ cursorId: "second", revealId: "second" });
    expect(moveSessionCursor(undefined, ["first", "second"], 1))
      .toEqual({ cursorId: "first", revealId: "first" });
  });

  it("formats compact relative ages", () => {
    const now = new Date("2026-08-22T10:00:00.000Z");
    expect(relativeSessionAge("2026-08-22T09:58:00.000Z", now)).toBe("2m");
    expect(relativeSessionAge("2026-08-22T07:00:00.000Z", now)).toBe("3h");
    expect(relativeSessionAge("2026-08-20T10:00:00.000Z", now)).toBe("2d");
  });

  it("ranks title search matches before newer metadata matches", () => {
    const titleMatch = { ...session("title", "history", "2026-08-20T10:00:00.000Z"), title: "Fix daemon" };
    const metadataMatch = { ...session("metadata", "working", "2026-08-22T10:00:00.000Z"), project: "daemon" };

    const selection = selectSessions([metadataMatch, titleMatch], "daemon");

    expect(selection.groups.map(({ title }) => title)).toEqual(["Results"]);
    expect(selection.orderedSessions.map(({ id }) => id)).toEqual(["title", "metadata"]);
  });
});
