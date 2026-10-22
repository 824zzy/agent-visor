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
});
