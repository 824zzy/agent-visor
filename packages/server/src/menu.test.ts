import { describe, expect, it } from "vitest";
import { nativeHelperRequestSchema, type SessionSnapshot } from "@agent-visor/protocol";
import { menuPresentation, nativeActionFor } from "./menu.js";

const snapshot: SessionSnapshot = {
  type: "session_snapshot",
  revision: 4,
  sessions: [
    {
      id: "work",
      title: "Build menu",
      subtitle: "Agent is working",
      source: "Pi",
      project: "agent-visor",
      owner: "Ghostty",
      cwd: "/repo",
      section: "working",
      updatedAt: "2026-08-22T21:00:00.000Z",
      canOpenOwner: true,
      canEnterChat: true,
    },
    {
      id: "history",
      title: "Old session",
      subtitle: "Session ended",
      source: "Codex",
      project: "agent-visor",
      owner: "Codex",
      cwd: "/repo",
      section: "history",
      updatedAt: "2026-08-22T20:00:00.000Z",
      canOpenOwner: true,
      canEnterChat: false,
    },
    {
      id: "history-chat-only",
      title: "Old Pi transcript",
      subtitle: "From Pi history",
      source: "Pi",
      project: "agent-visor",
      owner: "Pi",
      cwd: "/repo",
      section: "history",
      updatedAt: "2026-08-22T19:00:00.000Z",
      canOpenOwner: false,
      canEnterChat: true,
    },
    {
      id: "approval",
      title: "Approve release",
      subtitle: "Approval required",
      source: "Claude Code",
      project: "agent-visor",
      owner: "Ghostty",
      cwd: "/repo",
      section: "needs_you",
      updatedAt: "2026-08-22T21:01:00.000Z",
      canOpenOwner: true,
      canEnterChat: true,
    },
    {
      id: "ready",
      title: "Review result",
      subtitle: "Ready to continue",
      source: "Cursor",
      project: "agent-visor",
      owner: "Cursor",
      cwd: "/repo",
      section: "ready",
      updatedAt: "2026-08-22T21:02:00.000Z",
      canOpenOwner: true,
      canEnterChat: true,
    },
  ],
};

describe("menu presentation", () => {
  it("orders active pills by attention", () => {
    const { navigatorPills: _, ...presentation } = menuPresentation(snapshot, []);
    expect({
      ...presentation,
      pills: presentation.pills.map(({ inspector: _, ...pill }) => pill),
    }).toEqual({
      pills: [
        {
          id: "approval",
          title: "Approve release",
          subtitle: "Approval required",
          source: "Claude Code",
          project: "agent-visor",
          owner: "Ghostty",
          phase: "needs_you",
          priority: 0,
          defaultOverflowEligible: true,
          accessibilityLabel: "Approve release, needs you, Claude Code, agent-visor",
        },
        {
          id: "ready",
          title: "Review result",
          subtitle: "Ready to continue",
          source: "Cursor",
          project: "agent-visor",
          owner: "Cursor",
          phase: "ready",
          priority: 1,
          defaultOverflowEligible: true,
          accessibilityLabel: "Review result, ready to continue, Cursor, agent-visor",
        },
        {
          id: "work",
          title: "Build menu",
          subtitle: "Agent is working",
          source: "Pi",
          project: "agent-visor",
          owner: "Ghostty",
          phase: "working",
          priority: 2,
          defaultOverflowEligible: true,
          accessibilityLabel: "Build menu, in progress, Pi, agent-visor",
        },
        {
          id: "history",
          title: "Old session",
          subtitle: "Session ended",
          source: "Codex",
          project: "agent-visor",
          owner: "Codex",
          phase: "history",
          priority: 3,
          defaultOverflowEligible: true,
          accessibilityLabel: "Old session, recent session, Codex, agent-visor",
        },
      ],
      usageGlances: [],
    });
  });

  it("keeps acknowledged Ready behind Working in the shared attention order", () => {
    const presentation = menuPresentation({
      ...snapshot,
      sessions: [
        { ...snapshot.sessions[4]!, attentionTier: "acknowledged_ready" },
        { ...snapshot.sessions[0]!, attentionTier: "working" },
      ],
    }, []);

    expect(presentation.pills.map(({ id, attentionTier }) => ({ id, attentionTier }))).toEqual([
      { id: "work", attentionTier: "working" },
      { id: "ready", attentionTier: "acknowledged_ready" },
    ]);
    expect(nativeHelperRequestSchema.safeParse({
      version: 1,
      id: "shared-attention",
      method: "present_pills",
      params: presentation,
    }).success).toBe(true);
  });

  it("bounds titles at the native helper boundary", () => {
    const presentation = menuPresentation({
      ...snapshot,
      sessions: [{ ...snapshot.sessions[0]!, title: "x".repeat(500) }],
    }, []);

    expect(nativeHelperRequestSchema.safeParse({
      version: 1,
      id: "menu",
      method: "present_pills",
      params: presentation,
    }).success).toBe(true);
    expect(presentation.pills[0]?.title).toHaveLength(256);
  });

  it("keeps source-backed recent Codex history as a physical recent pill", () => {
    const presentation = menuPresentation(snapshot, []);

    expect(presentation.pills.map(({ id }) => id)).toContain("history");
    expect(presentation.navigatorPills.map(({ id }) => id)).toContain("history");
    expect(presentation.pills.find(({ id }) => id === "history")).toMatchObject({
      phase: "history",
      priority: 3,
      accessibilityLabel: "Old session, recent session, Codex, agent-visor",
      defaultOverflowEligible: true,
    });
  });

  it("keeps Codex automation searchable without a physical pill or raw prompt title", () => {
    const prompt = "Current message from an automation run: " + "secret prompt";
    const presentation = menuPresentation({
      ...snapshot,
      sessions: [{
        ...snapshot.sessions[1]!,
        id: "codex-exec",
        title: prompt,
        project: "agent-visor",
        sessionClass: "automation",
        section: "ready",
        canEnterChat: true,
        updatedAt: "2026-08-22T22:00:00.000Z",
      }],
    }, []);

    expect(presentation.pills).toEqual([]);
    expect(presentation.navigatorPills).toMatchObject([{
      id: "codex-exec",
      title: "Codex automation · agent-visor",
      defaultOverflowEligible: false,
    }]);
    expect(presentation.navigatorPills[0]?.title).not.toContain(prompt);
  });

  it("uses the project to distinguish untitled Codex pills", () => {
    const codexSessions: SessionSnapshot = {
      type: "session_snapshot",
      revision: 1,
      sessions: [
        {
          ...snapshot.sessions[1]!,
          id: "codex-root",
          title: "Codex session",
          project: "/",
          cwd: "/",
          section: "ready",
          updatedAt: "2026-08-25T16:19:50.877Z",
        },
        {
          ...snapshot.sessions[1]!,
          id: "codex-codes",
          title: "Codex session",
          project: "Codes",
          cwd: "/Users/me/Codes",
          section: "ready",
          updatedAt: "2026-08-25T16:19:45.919Z",
        },
      ],
    };

    const pills = menuPresentation(codexSessions, []).pills;

    expect(pills.map(({ title }) => title)).toEqual(["Codex · /", "Codex · Codes"]);
    expect(pills.map(({ accessibilityLabel }) => accessibilityLabel)).toEqual([
      "Codex · /, ready to continue, Codex, /",
      "Codex · Codes, ready to continue, Codex, Codes",
    ]);
  });

  it("keeps Chat-only history searchable without packing it into the menu", () => {
    const presentation = menuPresentation(snapshot, []);

    expect(presentation.pills.map(({ id }) => id)).not.toContain("history-chat-only");
    expect(presentation.navigatorPills).toContainEqual(expect.objectContaining({
      id: "history-chat-only",
      defaultOverflowEligible: true,
    }));
  });

  it("builds the Swift inspector content from authoritative session fields", () => {
    const presentation = menuPresentation(snapshot, []);

    expect(presentation.pills.find((pill) => pill.id === "work")?.inspector).toEqual({
      status: "Working",
      runtimeItems: ["Pi · Ghostty"],
      detailRows: [],
      projectPath: "/repo",
      activityAt: "2026-08-22T21:00:00.000Z",
    });
  });

  it("routes owner actions first and falls back to Chat when no owner exists", () => {
    expect(nativeActionFor({
      version: 1,
      type: "event",
      event: "activate_pill",
      sessionId: "approval",
    }, snapshot)).toBeUndefined();
    expect(nativeActionFor({
      version: 1,
      type: "event",
      event: "activate_pill",
      sessionId: "approval",
      intent: "chat",
    }, snapshot)).toEqual({
      type: "native_action",
      action: "open_chat",
      sessionId: "approval",
    });
    expect(nativeActionFor({
      version: 1,
      type: "event",
      event: "notification_action",
      action: "activate",
      sessionId: "approval",
    }, snapshot)).toEqual({
      type: "native_action",
      action: "open_chat",
      sessionId: "approval",
    });
    const chatOnly = {
      ...snapshot,
      sessions: [{ ...snapshot.sessions[0], id: "chat-only", canOpenOwner: false }],
    };
    expect(nativeActionFor({
      version: 1,
      type: "event",
      event: "activate_pill",
      sessionId: "chat-only",
    }, chatOnly)).toEqual({
      type: "native_action",
      action: "open_chat",
      sessionId: "chat-only",
    });
    expect(nativeActionFor({
      version: 1,
      type: "event",
      event: "open_sessions",
    }, snapshot)).toEqual({ type: "native_action", action: "open_sessions" });
    expect(nativeActionFor({
      version: 1,
      type: "event",
      event: "toggle_sessions",
    }, snapshot)).toEqual({ type: "native_action", action: "toggle_sessions" });
    expect(nativeActionFor({
      version: 1,
      type: "event",
      event: "open_settings",
    }, snapshot)).toEqual({ type: "native_action", action: "open_settings" });
  });

  it("opens Chat on a normal click when the session has no owner route", () => {
    const chatOnly = {
      ...snapshot,
      sessions: [{
        ...snapshot.sessions[2]!,
        id: "chat-only-normal-click",
        canOpenOwner: false,
        canEnterChat: true,
      }],
    };

    expect(nativeActionFor({
      version: 1,
      type: "event",
      event: "activate_pill",
      sessionId: "chat-only-normal-click",
    }, chatOnly)).toEqual({
      type: "native_action",
      action: "open_chat",
      sessionId: "chat-only-normal-click",
    });
  });
});
