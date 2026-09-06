import { describe, expect, it } from "vitest";
import { chatCapabilitiesForState, resolveSessionState } from "./session-state.js";
import type { DiscoveredProviderSession } from "./sessions.js";
import { processInstanceToken } from "./providers/shared.js";

const terminalTarget = {
  application: "Ghostty" as const,
  pid: 42,
  processStartToken: processInstanceToken(42, "2026-09-05T00:00:00.000Z"),
  tty: "ttys001",
  cwd: "/tmp/project",
};

function codex(overrides: Partial<DiscoveredProviderSession> = {}): DiscoveredProviderSession {
  return {
    id: "thread-1",
    provider: "codex",
    owner: "Codex",
    cwd: "/tmp/project",
    chatPath: "/tmp/thread-1.jsonl",
    controlTarget: { kind: "url", url: "codex://threads/thread-1" },
    messageTransport: "codex_app_server",
    conversationState: "open",
    turnState: "ready",
    routeState: "available",
    section: "ready",
    updatedAt: "2026-09-04T00:00:00.000Z",
    canOpenOwner: true,
    canEnterChat: true,
    ...overrides,
  };
}

describe("session state policy", () => {
  it("keeps an old open Codex conversation continuable regardless of list section", () => {
    const state = resolveSessionState(codex({ section: "history" }));
    expect(state).toEqual({
      conversation: "open", turn: "ready", route: "available", routeOwnership: "unverified",
    });
    expect(chatCapabilitiesForState(codex({ section: "history" }))).toMatchObject({
      canSendText: true,
      canSendImages: true,
    });
  });

  it("waits for an externally busy Codex turn and retains independent cancel capability", () => {
    const state = resolveSessionState(codex({ section: "working", turnState: "working" }));
    expect(state).toEqual({
      conversation: "open",
      turn: "working",
      route: "waiting",
      routeOwnership: "unverified",
      unavailableReason: "turn_in_progress",
    });
    expect(chatCapabilitiesForState(codex({ turnState: "working" }))).toMatchObject({
      canSendText: false,
      canCancel: true,
      unavailableReason: "turn_in_progress",
    });
  });

  it("prefers a lost Codex route over stale Working transcript evidence", () => {
    const state = resolveSessionState(codex({
      turnState: "working",
      routeState: "unavailable",
      routeUnavailableReason: "provider_unavailable",
    }));
    expect(state).toEqual({
      conversation: "open",
      turn: "working",
      route: "unavailable",
      unavailableReason: "provider_unavailable",
    });
    expect(chatCapabilitiesForState(codex({
      turnState: "working",
      routeState: "unavailable",
      routeUnavailableReason: "provider_unavailable",
    }))).toMatchObject({
      canSendText: false,
      canCancel: false,
      unavailableReason: "provider_unavailable",
    });
  });

  it("does not infer an owned Codex route from a ready transcript", () => {
    const state = resolveSessionState(codex({ routeState: undefined }));
    expect(state).toEqual({
      conversation: "open",
      turn: "ready",
      route: "unavailable",
      unavailableReason: "provider_unavailable",
    });
    expect(chatCapabilitiesForState(codex({ routeState: undefined }))).toMatchObject({
      canSendText: false,
      unavailableReason: "provider_unavailable",
    });
  });

  it("treats provider archival as different from an old or unavailable route", () => {
    const capabilities = chatCapabilitiesForState(codex({
      conversationState: "archived",
      section: "history",
    }));
    expect(capabilities).toMatchObject({
      canSendText: false,
      unavailableReason: "archived",
      readOnlyReason: "This conversation is archived. Open it in the source app to restore it.",
    });
  });

  it("does not infer a writable terminal turn from a live process alone", () => {
    const session: DiscoveredProviderSession = {
      id: "terminal-1",
      provider: "pi",
      owner: "Ghostty",
      cwd: "/tmp/project",
      controlTarget: { kind: "terminal", target: terminalTarget },
      messageTransport: "terminal",
      conversationState: "open",
      section: "working",
      updatedAt: "2026-09-05T00:00:00.000Z",
      canOpenOwner: true,
      canEnterChat: true,
    };
    expect(resolveSessionState(session)).toMatchObject({
      conversation: "open",
      turn: "unknown",
      route: "unavailable",
      unavailableReason: "provider_unavailable",
    });
  });
});
