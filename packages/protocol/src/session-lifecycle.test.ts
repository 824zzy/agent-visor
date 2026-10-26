import { describe, expect, it } from "vitest";
import type { SessionSummary } from "./index.js";
import { sessionLifecyclePresentation, sessionPresencePresentation } from "./index.js";

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
  it("uses explicit runtime presence and independent turn evidence for grouping", () => {
    expect(sessionPresencePresentation(session({
      section: "history",
      lifecycleStatus: "closed",
      presence: {
        state: "open",
        evidence: "frontend",
        observedAt: "2026-08-22T10:00:00.000Z",
      },
      sessionState: { conversation: "archived", turn: "ready", route: "available" },
    }))).toEqual({
      group: "current",
      subgroup: "ready",
      status: "ready",
      label: "Ready",
      tone: "ready",
    });
  });

  it("keeps confirmed open location separate from unknown turn status", () => {
    expect(sessionPresencePresentation(session({
      presence: {
        state: "open",
        evidence: "runtime",
        observedAt: "2026-08-22T10:00:00.000Z",
      },
      sessionState: { conversation: "open", turn: "unknown", route: "available" },
    }))).toEqual({
      group: "current",
      status: "unavailable",
      label: "Status unavailable",
      tone: "neutral",
    });
  });

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

  it("keeps verified attention yellow through unavailable location but labels last-known attention", () => {
    const current = Object.assign(session({
      presence: {
        state: "unknown" as const,
        evidence: "unavailable" as const,
        observedAt: "2026-08-22T10:00:00.000Z",
      },
      sessionState: {
        conversation: "open" as const,
        turn: "working" as const,
        route: "unavailable" as const,
      },
    }), {
      attention: {
        kind: "question" as const,
        evidence: "current" as const,
        observedAt: "2026-08-22T09:59:00.000Z",
      },
    });
    expect(sessionLifecyclePresentation(current)).toMatchObject({
      status: "needs_you", label: "Needs you", tone: "attention",
      attention: { kind: "question", evidence: "current", label: "Needs you", tone: "attention" },
    });
    expect(sessionPresencePresentation(current)).toMatchObject({
      group: "unavailable", subgroup: "needs_you", status: "needs_you", tone: "attention",
      attention: { kind: "question", evidence: "current", label: "Needs you", tone: "attention" },
    });

    const lastKnown = Object.assign(current, {
      attention: {
        kind: "question" as const,
        evidence: "last_known" as const,
        observedAt: "2026-08-22T09:59:00.000Z",
      },
    });
    expect(sessionLifecyclePresentation(lastKnown)).toMatchObject({
      status: "unavailable", label: "Status unavailable", tone: "neutral",
    });
    expect(sessionPresencePresentation(lastKnown)).toMatchObject({
      group: "unavailable", subgroup: "working", status: "unavailable", tone: "neutral",
      attention: {
        kind: "question", evidence: "last_known", label: "Last known: Needs you", tone: "neutral",
      },
    });
  });

  it("does not promote stale needs-you turn evidence after an open question becomes last-known", () => {
    const lastKnown = session({
      section: "needs_you",
      presence: {
        state: "open",
        evidence: "frontend",
        observedAt: "2026-08-22T10:00:00.000Z",
      },
      sessionState: {
        conversation: "open",
        turn: "needs_you",
        route: "unavailable",
      },
      attention: {
        kind: "question",
        evidence: "last_known",
        observedAt: "2026-08-22T09:59:00.000Z",
      },
    });

    expect(sessionLifecyclePresentation(lastKnown)).toMatchObject({
      status: "unavailable", label: "Status unavailable", tone: "neutral",
      attention: { evidence: "last_known", label: "Last known: Needs you", tone: "neutral" },
    });
    expect(sessionPresencePresentation(lastKnown)).toMatchObject({
      group: "current", status: "unavailable", tone: "neutral",
      attention: { evidence: "last_known", label: "Last known: Needs you", tone: "neutral" },
    });
    expect(sessionPresencePresentation(lastKnown)).not.toHaveProperty("subgroup");
  });
});
