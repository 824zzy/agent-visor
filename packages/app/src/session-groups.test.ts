import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SessionSummary } from "@agent-visor/protocol";
import {
  groupSessions,
  moveSessionCursor,
  reconcileSessionCursor,
  relativeSessionAge,
  sessionAction,
  sessionPresentation,
  selectSessions,
} from "./session-groups.js";

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-08-22T10:00:00.000Z"));
});
afterEach(() => vi.useRealTimers());

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
  it("reclassifies the same snapshot as time passes without changing its completion acknowledgment", () => {
    const row = {
      ...session("seen", "ready", "2026-08-15T10:00:00.000Z"),
      attentionTier: "acknowledged_ready" as const,
    };
    const rows = [row];
    expect(groupSessions(rows, new Date("2026-08-22T09:59:59.999Z"))[0]?.id).toBe("ready");
    expect(groupSessions(rows, new Date("2026-08-22T10:00:00.000Z"))[0]?.id).toBe("ready");
    expect(groupSessions(rows, new Date("2026-08-22T10:00:00.001Z"))[0]?.id).toBe("history");
    expect(row.attentionTier).toBe("acknowledged_ready");
  });

  it("keeps working turns and approvals actionable regardless of age", () => {
    const working = session("working", "working", "2026-06-01T10:00:00.000Z");
    const approval = session("approval", "needs_you", "2026-06-01T10:00:00.000Z");
    expect(groupSessions([working, approval]).map(({ id }) => id)).toEqual(["needs_you", "working"]);
    for (const turn of ["working", "needs_you"] as const) {
      const row = { ...working, section: "ready" as const, sessionState: { conversation: "open", turn, route: "waiting" } as const };
      expect(sessionPresentation(row).section).toBe("ready");
    }
  });

  it("does not expire future or unreadable activity timestamps", () => {
    for (const updatedAt of ["2026-08-23T10:00:00.000Z", "invalid"]) {
      expect(sessionPresentation(session("clock", "ready", updatedAt)).section).toBe("ready");
    }
  });

  it("uses the same completed status in history rows and search while retaining managed origin", () => {
    const old = {
      ...session("managed", "ready", "2026-08-14T10:00:00.000Z"),
      managedBy: "Agent Room" as const,
      subtitle: "Managed by Agent Room · Ready to continue",
      attentionTier: "acknowledged_ready" as const,
    };
    expect(sessionPresentation(old)).toEqual({
      section: "history", title: "History", subtitle: "Managed by Agent Room · Completed",
    });
    expect(selectSessions([old], "completed").orderedSessions).toEqual([old]);
    expect(selectSessions([old], "ready to continue").orderedSessions).toEqual([old]);
    expect(selectSessions([old], "managed by agent room").orderedSessions).toEqual([old]);
  });

  it("retains original provider previews in search after their completed row ages into History", () => {
    const old = { ...session("old-build", "ready", "2026-08-14T10:00:00.000Z"), subtitle: "Build output is in the release folder" };
    expect(sessionPresentation(old).subtitle).toBe("Completed");
    expect(selectSessions([old], "build output").orderedSessions).toEqual([old]);
  });

  it("does not label a History-tier automation completed when its explicit turn is busy or unknown", () => {
    for (const turn of ["working", "needs_you", "unknown"] as const) {
      const automation = {
        ...session("automation", "ready", "2026-08-14T10:00:00.000Z"),
        subtitle: "Provider status pending",
        attentionTier: "history" as const,
        sessionClass: "automation" as const,
        sessionState: { conversation: "open", turn, route: "waiting" } as const,
      };
      expect(sessionPresentation(automation).subtitle).toBe("Provider status pending");
    }
  });

  it("moves completed conversations older than seven days to History without hiding them or changing actions", () => {
    const old = {
      ...session("old-conversation", "ready", "2026-08-15T09:59:59.999Z"),
      subtitle: "Ready to continue",
      attentionTier: "ready" as const,
      sessionState: { conversation: "open", turn: "ready", route: "available" } as const,
    };
    const boundary = session("boundary", "ready", "2026-08-15T10:00:00.000Z");
    const selection = selectSessions([old, boundary], "");
    expect(selection.groups.map(({ id, sessions }) => [id, sessions.map(({ id }) => id)]))
      .toEqual([["ready", ["boundary"]], ["history", ["old-conversation"]]]);
    expect(selection.orderedSessions[1]).toBe(old);
    expect(selectSessions([old], "old-conversation").orderedSessions).toEqual([old]);
    expect(sessionAction(old)).toBe("owner");
    expect(sessionAction(old, true)).toBe("chat");
    expect(old.sessionState).toEqual({ conversation: "open", turn: "ready", route: "available" });
    expect(old.section).toBe("ready");
  });

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

  it("keeps one Ready group with unseen completions first and newest first within each tier", () => {
    const freshReady = {
      ...session("fresh-ready", "ready", "2026-08-22T10:00:00.000Z"),
      attentionTier: "ready" as const,
    };
    const acknowledgedReady = {
      ...session("acknowledged-ready", "ready", "2026-08-22T12:00:00.000Z"),
      attentionTier: "acknowledged_ready" as const,
    };

    const groups = groupSessions([
      acknowledgedReady,
      session("working", "working", "2026-08-22T08:00:00.000Z"),
      { ...freshReady, id: "older-unseen", updatedAt: "2026-08-22T09:00:00.000Z" },
      { ...acknowledgedReady, id: "older-seen", updatedAt: "2026-08-22T11:00:00.000Z" },
      freshReady,
    ]);

    expect(groups.map(({ id, sessions: rows }) => ({
      id,
      sessions: rows.map(({ id }) => id),
    }))).toEqual([
      { id: "ready", sessions: ["fresh-ready", "older-unseen", "acknowledged-ready", "older-seen"] },
      { id: "working", sessions: ["working"] },
    ]);
    expect(groups.map(({ title }) => title)).toEqual(["Ready to continue", "In progress"]);
  });

  it("keeps acknowledged completions in Ready when there are no unseen completions", () => {
    const groups = groupSessions([{
      ...session("seen", "ready", "2026-08-22T12:00:00.000Z"),
      attentionTier: "acknowledged_ready",
    }]);
    expect(groups.map(({ id, title }) => ({ id, title })))
      .toEqual([{ id: "ready", title: "Ready to continue" }]);
  });

  it("preserves a Ready automation's History attention placement", () => {
    const automation = {
      ...session("scheduled", "ready", "2026-08-22T12:00:00.000Z"),
      attentionTier: "history" as const,
    };
    const groups = groupSessions([automation]);
    expect(groups.map(({ id }) => id)).toEqual(["history"]);
    expect(sessionPresentation(automation)).toEqual({ section: "history", title: "History", subtitle: "Completed" });
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
