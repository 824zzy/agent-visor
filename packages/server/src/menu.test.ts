import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  nativeHelperRequestSchema,
  TRANSCRIPT_STALE_CEILING_MS,
  type SessionSnapshot,
} from "@agent-visor/protocol";
import { activateMenuPill, menuPresentation, nativeActionFor } from "./menu.js";
import { NavigationDiagnostics } from "./navigation-diagnostics.js";

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date("2026-08-22T22:00:00Z"));
});
afterEach(() => vi.useRealTimers());

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
  it.each(["needs_you", "working", "ready", "history"] as const)(
    "keeps retained %s jobs searchable without pills or default overflow", (section) => {
      const catalog: SessionSnapshot = {
        ...snapshot,
        sessions: [...snapshot.sessions, {
          ...snapshot.sessions[0]!, id: "retained", source: "Claude Code",
          section, ambientEligible: false, updatedAt: "2026-08-22T22:00:00.000Z",
        }],
      };
      const before = structuredClone(catalog);
      const presentation = menuPresentation(catalog, []);
      expect(presentation.pills.map(({ id }) => id)).not.toContain("retained");
      expect(presentation.pills.map(({ id }) => id)).toEqual(
        menuPresentation(snapshot, []).pills.map(({ id }) => id),
      );
      expect(presentation.navigatorPills).toContainEqual(expect.objectContaining({
        id: "retained", phase: section, defaultOverflowEligible: false,
      }));
      expect(catalog).toEqual(before);
    },
  );

  it("reports rejected native pill focus instead of silently consuming the click", async () => {
    const dispatched: unknown[] = [];
    const focused: string[] = [];
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: "history" }, {
      current: () => snapshot,
      focusSession: async (id) => {
        focused.push(id);
        return "This turn is still running in Agent Visor.";
      },
    }, (message) => dispatched.push(message));
    expect(focused).toEqual(["history"]);
    expect(dispatched).toEqual([{
      type: "native_effect", action: "session_focus_failed",
      message: "This turn is still running in Agent Visor.",
    }]);
  });

  it("persists a correlated failed click without session names or arbitrary errors", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "visor-click-"));
    try {
      const diagnostics = new NavigationDiagnostics(root);
      await diagnostics.run("private-session", "standard", () => activateMenuPill({
        version: 1, type: "event", event: "activate_pill", sessionId: "private-session",
      }, { current: () => snapshot, focusSession: async () => "secret-token-in-error" }, () => {}));
      await diagnostics.flush();
      const file = path.join(root, "diagnostics/pill-navigation.jsonl");
      const text = await readFile(file, "utf8");
      const records = text.trim().split("\n").map(line => JSON.parse(line));
      expect(records.map(record => record.stage)).toEqual(["received", "failed"]);
      expect(new Set(records.map(record => record.clickId)).size).toBe(1);
      expect(records[0].sessionHash).toMatch(/^[0-9a-f]{16}$/);
      expect(text).not.toContain("private-session");
      expect(text).not.toContain("secret-token");
      expect((await stat(file)).mode & 0o777).toBe(0o600);
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  it("caps click log retention and continues navigation when diagnostics cannot be written", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "visor-click-"));
    try {
      const directory = path.join(root, "diagnostics");
      const file = path.join(directory, "pill-navigation.jsonl");
      await mkdir(directory);
      await writeFile(file, " ".repeat(262_143), { mode: 0o600 });
      const diagnostics = new NavigationDiagnostics(root);
      const focusSession = vi.fn(async () => undefined);
      const click = () => activateMenuPill({
        version: 1, type: "event", event: "activate_pill", sessionId: "history",
      }, { current: () => snapshot, focusSession }, () => {});
      await diagnostics.run("history", "standard", click);
      await diagnostics.flush();
      expect((await stat(file)).size).toBeLessThanOrEqual(262_144);
      expect((await stat(file + ".previous")).size).toBe(262_143);
      // A path that is a file cannot become a diagnostics directory.
      await writeFile(path.join(root, "unwritable-root"), "fixture");
      const unavailable = new NavigationDiagnostics(path.join(root, "unwritable-root"));
      await unavailable.run("history", "standard", click);
      await unavailable.flush();
      expect(focusSession).toHaveBeenCalledTimes(2);
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  it("keeps explicit Chat activation out of owner focus", async () => {
    const dispatched: unknown[] = [];
    await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: "work", intent: "chat" }, {
      current: () => snapshot,
      focusSession: async () => { throw new Error("Unexpected owner focus"); },
    }, (message) => dispatched.push(message));
    expect(dispatched).toEqual([{ type: "native_action", action: "open_chat", sessionId: "work" }]);
  });

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

  it("moves stale Claude Ready rows behind fresh completed work without changing turn evidence", () => {
    const now = Date.parse("2026-08-22T22:00:00.000Z");
    const sourceSnapshot = {
      ...snapshot,
      sessions: [
        {
          ...snapshot.sessions[4]!,
          id: "fresh-claude",
          source: "Claude Code",
          updatedAt: new Date(now - TRANSCRIPT_STALE_CEILING_MS + 1).toISOString(),
        },
        {
          ...snapshot.sessions[4]!,
          id: "stale-claude",
          source: "Claude Code",
          updatedAt: new Date(now - TRANSCRIPT_STALE_CEILING_MS - 1).toISOString(),
        },
        {
          ...snapshot.sessions[0]!,
          id: "old-working-claude",
          source: "Claude Code",
          updatedAt: new Date(now - 8 * 60 * 60 * 1_000).toISOString(),
        },
      ],
    } satisfies SessionSnapshot;
    const before = structuredClone(sourceSnapshot);
    const presentation = menuPresentation(sourceSnapshot, [], now);

    expect(presentation.pills.map(({ id, phase, attentionTier }) => ({ id, phase, attentionTier }))).toEqual([
      { id: "fresh-claude", phase: "ready", attentionTier: undefined },
      { id: "old-working-claude", phase: "working", attentionTier: undefined },
      { id: "stale-claude", phase: "ready", attentionTier: "history" },
    ]);
    expect(sourceSnapshot).toEqual(before);
    expect(sourceSnapshot.sessions[1]).toMatchObject({
      section: "ready",
      subtitle: "Ready to continue",
    });
  });

  it("lets newer non-Claude History outrank stale acknowledged Claude without rewriting source state", () => {
    const now = Date.parse("2026-08-22T22:00:00.000Z");
    const staleClaude: SessionSnapshot["sessions"][number] = {
      ...snapshot.sessions[4]!,
      id: "stale-claude",
      source: "Claude Code",
      attentionTier: "acknowledged_ready",
      updatedAt: new Date(now - TRANSCRIPT_STALE_CEILING_MS - 1).toISOString(),
      sessionState: {
        conversation: "open",
        turn: "ready",
        route: "available",
      },
    };
    const recentHistory: SessionSnapshot["sessions"][number] = {
      ...snapshot.sessions[1]!,
      id: "newer-history",
      source: "Codex",
      updatedAt: new Date(now - 5 * 60 * 1_000).toISOString(),
    };
    const sourceSnapshot = { ...snapshot, sessions: [staleClaude, recentHistory] };
    const before = structuredClone(sourceSnapshot);
    const presentation = menuPresentation(sourceSnapshot, [], now);

    expect(presentation.pills.map(({ id }) => id)).toEqual([
      "newer-history", "stale-claude",
    ]);
    expect(presentation.pills[1]).toMatchObject({
      id: "stale-claude",
      phase: "ready",
      attentionTier: "history",
      subtitle: "Ready to continue",
    });
    expect(sourceSnapshot).toEqual(before);
    expect(sourceSnapshot.sessions[0]).toMatchObject({
      section: "ready",
      subtitle: "Ready to continue",
      sessionState: { turn: "ready" },
    });
  });

  it("puts unopened completions before running work and opened completions", () => {
    const presentation = menuPresentation({
      ...snapshot,
      sessions: [
        { ...snapshot.sessions[4]!, id: "old-unseen", attentionTier: "ready", updatedAt: "2026-09-06T04:12:00.000Z" },
        { ...snapshot.sessions[4]!, id: "new-unseen", attentionTier: "ready", updatedAt: "2026-09-07T01:08:00.000Z" },
        { ...snapshot.sessions[4]!, id: "seen", attentionTier: "acknowledged_ready", updatedAt: "2026-09-07T02:08:00.000Z" },
        { ...snapshot.sessions[0]!, attentionTier: "working", updatedAt: "2026-09-07T02:04:00.000Z" },
        { ...snapshot.sessions[3]!, attentionTier: "needs_you" },
        snapshot.sessions[1]!,
      ],
    }, []);

    for (const pills of [presentation.pills, presentation.navigatorPills]) {
      expect(pills.map(({ id }) => id)).toEqual(["approval", "new-unseen", "old-unseen", "work", "seen", "history"]);
      expect(pills.map(({ priority }) => priority)).toEqual([0, 1, 2, 3, 4, 5]);
    }
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
    }, snapshot)).toBeUndefined();
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


describe("native menu activity window", () => {
  it("caps both surfaces at seven days across phases and leaves the full catalog intact", () => {
    const now = Date.parse("2026-09-08T12:00:00Z");
    const cutoff = now - 7 * 24 * 60 * 60 * 1_000;
    const sessions = (["needs_you", "working", "ready", "history"] as const).flatMap((section) =>
      [cutoff - 1, cutoff, cutoff + 1].map((time, index) => ({
        ...snapshot.sessions[0]!, id: `${section}-${index}`, section,
        updatedAt: new Date(time).toISOString(),
      })));
    sessions.push({ ...sessions[0]!, id: "invalid", updatedAt: "invalid" });
    const catalog = { ...snapshot, sessions };
    const before = structuredClone(catalog);
    const menu = menuPresentation(catalog, [], now);
    for (const rows of [menu.pills, menu.navigatorPills]) {
      expect(rows).toHaveLength(8);
      expect(rows.every(({ id }) => id.endsWith("-1") || id.endsWith("-2"))).toBe(true);
    }
    expect(catalog).toEqual(before);
    // Time alone expires the boundary rows; fresh activity returns an older row.
    expect(menuPresentation(catalog, [], now + 1).navigatorPills).toHaveLength(4);
    sessions[0]!.updatedAt = new Date(now).toISOString();
    expect(menuPresentation(catalog, [], now).pills.some(({ id }) => id === "needs_you-0")).toBe(true);
  });
});
