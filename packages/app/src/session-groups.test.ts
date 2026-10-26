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
  it("shows a searchable pill explanation separately from a Claude job's working status", () => {
    const working = {
      ...session("ccx-plg-manifest", "working", "2026-08-22T09:59:00.000Z"),
      source: "Claude Code", subtitle: "Claude Code is working", ambientEligible: false,
      claudePresence: "unrecognized_title" as const,
    };
    expect(sessionPresentation(working)).toEqual({
      section: "working", title: "In progress", subtitle: "Claude Code is working",
      pillNotice: "Pill hidden: terminal title cannot identify the displayed conversation.",
    });
    expect(selectSessions([working], "terminal title").orderedSessions).toEqual([working]);
    expect(sessionAction(working)).toBe("owner");
    for (const claudePresence of ["interactive", "conversation", "overview", "not_displayed"] as const) {
      expect(sessionPresentation({ ...working, claudePresence })).not.toHaveProperty("pillNotice");
    }
  });

  it("explains ambiguity and observation failures without changing a pending approval or its action", () => {
    const approval = { ...session("approval", "needs_you", "2026-08-22T09:59:00.000Z"),
      source: "Claude Code", subtitle: "Claude Code needs your input", ambientEligible: false };
    const cases = [
      ["ambiguous_title", "Pill hidden: duplicate Claude names in this folder. Rename one session."],
      ["read_failed", "Pill hidden: terminal could not be checked. Agent Visor will retry."],
      ["reader_unavailable", "Pill hidden: terminal detection is unavailable."],
      ["inventory_unavailable", "Pill hidden: Claude sessions could not be checked. Agent Visor will retry."],
      ["process_changed", "Pill hidden: terminal changed. Agent Visor will check again."],
    ] as const;
    for (const [claudePresence, pillNotice] of cases) {
      const row = { ...approval, claudePresence };
      expect(sessionPresentation(row)).toEqual({
        section: "needs_you", title: "Needs you", subtitle: "Claude Code needs your input", pillNotice,
      });
      expect(sessionAction(row)).toBe("owner");
    }
  });

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

  it("keeps a known open Ready conversation visibly Ready in History placement", () => {
    const old = {
      ...session("old-ready", "ready", "2026-08-14T10:00:00.000Z"),
      subtitle: "Ready to continue",
      attentionTier: "acknowledged_ready" as const,
      sessionState: { conversation: "open", turn: "ready", route: "available" } as const,
    };

    expect(sessionPresentation(old)).toEqual({
      section: "history", title: "History", subtitle: "Ready",
    });
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

  it("keeps one Ready group ordered by recent activity across seen and unseen completions", () => {
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
      { id: "ready", sessions: ["acknowledged-ready", "older-seen", "fresh-ready", "older-unseen"] },
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

  it("searches explicit presence rows by their user-facing state label", () => {
    const closed = {
      ...session("closed-result", "history", "2026-08-22T09:00:00.000Z"),
      title: "Release report",
      subtitle: "Transcript available",
      presence: {
        state: "closed" as const,
        evidence: "authoritative_inventory" as const,
        observedAt: "2026-08-22T10:00:00.000Z",
      },
      sessionState: {
        conversation: "archived" as const,
        turn: "ready" as const,
        route: "unavailable" as const,
      },
    };

    expect(selectSessions([closed], "closed").orderedSessions.map(({ id }) => id))
      .toEqual(["closed-result"]);
  });

  it("uses explicit presence for placement instead of age or retained lifecycle labels", () => {
    const open = {
      ...session("open-old", "history", "2026-08-12T10:00:00.000Z"),
      lifecycleStatus: "closed" as const,
      presence: {
        state: "open" as const,
        evidence: "frontend" as const,
        observedAt: "2026-08-22T10:00:00.000Z",
      },
      sessionState: { conversation: "archived" as const, turn: "ready" as const, route: "available" as const },
    };
    const closed = {
      ...session("closed-now", "working", "2026-08-22T09:59:00.000Z"),
      lifecycleStatus: "working" as const,
      presence: {
        state: "closed" as const,
        evidence: "authoritative_inventory" as const,
        observedAt: "2026-08-22T10:00:00.000Z",
      },
      sessionState: { conversation: "open" as const, turn: "working" as const, route: "waiting" as const },
    };
    const unavailable = {
      ...session("unknown", "history", "2026-08-22T09:58:00.000Z"),
      presence: {
        state: "unknown" as const,
        evidence: "unavailable" as const,
        observedAt: "2026-08-22T10:00:00.000Z",
      },
      sessionState: { conversation: "unknown" as const, turn: "ready" as const, route: "unavailable" as const },
    };

    expect(sessionPresentation(open)).toEqual({
      section: "ready", title: "Ready", subtitle: "",
    });
    expect(sessionPresentation(closed)).toEqual({
      section: "history", title: "History", subtitle: "",
    });
    expect(sessionPresentation(unavailable)).toEqual({
      section: "unavailable", title: "Status unavailable", subtitle: "",
      pillNotice: "Status unavailable: Agent Visor could not verify whether this conversation is open.",
    });
    expect(groupSessions([closed, open, unavailable]).map(({ id, title }) => ({ id, title }))).toEqual([
      { id: "ready", title: "Ready" },
      { id: "unavailable", title: "Status unavailable" },
      { id: "history", title: "History" },
    ]);
  });

  it("keeps a confirmed-open row under Current when its turn is unknown", () => {
    const openUnknownTurn = {
      ...session("open-unknown-turn", "history", "2026-08-22T09:58:00.000Z"),
      presence: {
        state: "open" as const,
        evidence: "runtime" as const,
        observedAt: "2026-08-22T10:00:00.000Z",
      },
      sessionState: {
        conversation: "open" as const,
        turn: "unknown" as const,
        route: "available" as const,
      },
    };

    expect(sessionPresentation(openUnknownTurn)).toEqual({
      section: "current_unknown", title: "", subtitle: "",
    });
    expect(sessionPresentation(openUnknownTurn)).not.toHaveProperty("pillNotice");
    expect(groupSessions([openUnknownTurn])).toEqual([{
      id: "current_unknown",
      title: "",
      sessions: [openUnknownTurn],
      parent: "current",
    }]);
  });

  it("keeps unconverted rows readable but unavailable in a mixed snapshot", () => {
    const open = {
      ...session("open", "working", "2026-08-22T10:00:00.000Z"),
      presence: {
        state: "open" as const,
        evidence: "frontend" as const,
        observedAt: "2026-08-22T10:00:00.000Z",
      },
      sessionState: { conversation: "open" as const, turn: "working" as const, route: "waiting" as const },
    };
    const legacy = session("legacy", "ready", "2026-08-22T09:00:00.000Z");
    const groups = groupSessions([legacy, open]);

    expect(groups.map(({ id, title }) => ({ id, title }))).toEqual([
      { id: "working", title: "In progress" },
      { id: "unavailable", title: "Status unavailable" },
    ]);
    expect(groups[1]?.sessions[0]).toMatchObject({
      id: "legacy",
      presence: { state: "unknown", evidence: "unavailable" },
    });
    expect(sessionPresentation(groups[1]!.sessions[0]!)).toMatchObject({
      section: "unavailable",
      pillNotice: "Status unavailable: Agent Visor could not verify whether this conversation is open.",
    });
    const searched = selectSessions([legacy, open], "legacy");
    expect(searched.groups[0]?.sessions[0]).toMatchObject({
      id: "legacy",
      presence: { state: "unknown", evidence: "unavailable" },
    });
  });
});
