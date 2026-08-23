import { describe, expect, it } from "vitest";
import type { SessionSnapshot } from "@agent-visor/protocol";
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
  it("orders active pills by attention and keeps history off the menu bar", () => {
    expect(menuPresentation(snapshot, [])).toEqual({
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
          accessibilityLabel: "Build menu, in progress, Pi, agent-visor",
        },
      ],
      usageGlances: [],
    });
  });

  it("routes helper actions through the daemon using the current owner", () => {
    expect(nativeActionFor({
      version: 1,
      type: "event",
      event: "activate_pill",
      sessionId: "approval",
    }, snapshot)).toEqual({
      type: "native_action",
      action: "open_owner",
      owner: "Ghostty",
      sessionId: "approval",
    });
    expect(nativeActionFor({
      version: 1,
      type: "event",
      event: "open_sessions",
    }, snapshot)).toEqual({
      type: "native_action",
      action: "open_sessions",
    });
  });
});
