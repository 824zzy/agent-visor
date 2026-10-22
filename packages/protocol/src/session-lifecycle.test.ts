import { describe, expect, it } from "vitest";
import type { SessionSummary } from "./index.js";
import { sessionLifecyclePresentation } from "./index.js";

const session = (overrides: Partial<SessionSummary> = {}): SessionSummary => ({
  id: "ready-session",
  title: "Review result",
  subtitle: "Ready to continue",
  source: "Claude Code",
  project: "agent-visor",
  owner: "Ghostty",
  cwd: "/Users/me/Codes/agent-visor",
  section: "ready",
  updatedAt: "2026-08-15T10:00:00.000Z",
  canOpenOwner: true,
  canEnterChat: true,
  ...overrides,
});

describe("session lifecycle presentation", () => {
  it.each([
    ["working during compaction", "ready", "working", "Working", "working"],
    ["unanswered async question", "working", "needs_you", "Needs you", "attention"],
    ["pending permission", "working", "needs_you", "Needs you", "attention"],
    ["new busy turn after an answer", "needs_you", "working", "Working", "working"],
    ["normal idle prompt", "needs_you", "ready", "Ready", "ready"],
  ] as const)(
    "keeps %s status independent from the prior placement",
    (_name, section, turn, label, tone) => {
      expect(sessionLifecyclePresentation(session({
        section,
        sessionState: { conversation: "open", turn, route: turn === "ready" ? "available" : "waiting" },
      }))).toEqual({
        status: turn === "needs_you" ? "needs_you" : turn,
        label,
        tone,
      });
    },
  );

  it("keeps an acknowledged Ready conversation green when recency moves it to History", () => {
    expect(sessionLifecyclePresentation(session({
      attentionTier: "history",
      sessionState: { conversation: "open", turn: "ready", route: "available" },
    }))).toEqual({ status: "ready", label: "Ready", tone: "ready" });
  });

  it("keeps known Ready status when browser placement crosses its History boundary", () => {
    expect(sessionLifecyclePresentation(session({
      section: "history",
      sessionState: { conversation: "open", turn: "ready", route: "available" },
    }))).toEqual({ status: "ready", label: "Ready", tone: "ready" });
  });

  it("keeps a section-only Ready snapshot compatible with the shared contract", () => {
    expect(sessionLifecyclePresentation(session())).toEqual({
      status: "ready", label: "Ready", tone: "ready",
    });
  });

  it.each([
    ["closed", "Closed", "neutral"],
    ["unavailable", "Status unavailable", "neutral"],
    ["historical", "Historical", "neutral"],
  ] as const)("uses explicit %s lifecycle evidence over retained placement facts", (status, label, tone) => {
    const retained = Object.assign(session({
      section: "history",
      sessionState: {
        conversation: "open",
        turn: "unknown",
        route: "unavailable",
        unavailableReason: "unknown",
      },
    }), { lifecycleStatus: status });

    expect(sessionLifecyclePresentation(retained)).toEqual({ status, label, tone });
  });

  it("keeps a known Ready lifecycle green when its placement is History", () => {
    const retained = Object.assign(session({
      section: "history",
      sessionState: { conversation: "open", turn: "ready", route: "available" },
    }), { lifecycleStatus: "ready" as const });

    expect(sessionLifecyclePresentation(retained)).toEqual({
      status: "ready", label: "Ready", tone: "ready",
    });
  });
});
