import { describe, expect, it } from "vitest";
import type { ChatPage, SessionSummary } from "@agent-visor/protocol";
import { chatLifecycleView } from "./chat-lifecycle.js";

const session = (state: NonNullable<SessionSummary["sessionState"]>): SessionSummary => ({
  id: "session",
  title: "Conversation",
  subtitle: "Ready to continue",
  source: "Codex",
  project: "fixture",
  owner: "Codex",
  cwd: "/fixture",
  section: "history",
  attentionTier: "history",
  updatedAt: "2026-09-05T00:00:00.000Z",
  canOpenOwner: true,
  canEnterChat: true,
  sessionState: state,
});

const page = (
  state: NonNullable<ChatPage["sessionState"]>,
  reason?: NonNullable<ChatPage["capabilities"]["unavailableReason"]>,
): Pick<ChatPage, "sessionState" | "capabilities"> => ({
  sessionState: state,
  capabilities: {
    canSendText: state.route === "available",
    canSendImages: false,
    canCancel: state.turn === "working" && state.route === "available",
    canApprove: false,
    canAnswer: false,
    ...(reason ? { unavailableReason: reason } : {}),
    ...(reason ? { readOnlyReason: `fixture: ${reason}` } : {}),
  },
});

describe("chat lifecycle presentation", () => {
  it("keeps an older ready conversation continuable", () => {
    const state = { conversation: "open" as const, turn: "ready" as const, route: "available" as const };
    const view = chatLifecycleView(session(state), page(state));
    expect(view).toMatchObject({
      statusLabel: "Ready",
      statusTone: "ready",
      canEditDraft: true,
      canRetry: false,
    });
    expect(view.notice).toBeUndefined();
  });

  it("keeps a draft editable while an external turn is still running", () => {
    const state = {
      conversation: "open" as const,
      turn: "working" as const,
      route: "waiting" as const,
      unavailableReason: "turn_in_progress" as const,
    };
    expect(chatLifecycleView(session(state), page(state, "turn_in_progress"))).toMatchObject({
      statusLabel: "In progress",
      statusTone: "working",
      canEditDraft: true,
      canRetry: false,
      notice: "The current turn is still running. Send your message after it finishes.",
    });
  });

  it("explains the wait even when a terminal route is still connected", () => {
    const state = {
      conversation: "open" as const,
      turn: "working" as const,
      route: "available" as const,
    };
    expect(chatLifecycleView(session(state), page(state))).toMatchObject({
      statusLabel: "In progress",
      canEditDraft: true,
      canRetry: false,
      notice: "The current turn is still running. Send your message after it finishes.",
    });
  });

  it("does not present an archived conversation as a transient outage", () => {
    const state = {
      conversation: "archived" as const,
      turn: "unknown" as const,
      route: "unavailable" as const,
      unavailableReason: "archived" as const,
    };
    expect(chatLifecycleView(session(state), page(state, "archived"))).toMatchObject({
      statusLabel: "Archived",
      statusTone: "archived",
      canEditDraft: false,
      canRetry: false,
      notice: "This conversation is archived. Open it in Codex to restore it.",
    });
  });

  it("keeps a provider outage recoverable and draft editable", () => {
    const state = {
      conversation: "open" as const,
      turn: "ready" as const,
      route: "unavailable" as const,
      unavailableReason: "provider_unavailable" as const,
    };
    expect(chatLifecycleView(session(state), page(state, "provider_unavailable"))).toMatchObject({
      statusLabel: "Unavailable",
      statusTone: "unavailable",
      canEditDraft: true,
      canRetry: true,
    });
  });

  it("keeps an owner-held draft staged without offering a retry", () => {
    const state = {
      conversation: "open" as const,
      turn: "ready" as const,
      route: "unavailable" as const,
      unavailableReason: "owner_only" as const,
    };
    expect(chatLifecycleView(session(state), page(state, "owner_only"))).toMatchObject({
      statusLabel: "Open in Codex",
      canEditDraft: true,
      canRetry: false,
      notice: "This session is currently owned by Codex. Continue there to send messages.",
    });
  });

  it("treats an inactive terminal route as a non-retryable owner action", () => {
    const state = {
      conversation: "open" as const,
      turn: "unknown" as const,
      route: "unavailable" as const,
      unavailableReason: "turn_not_active" as const,
    };
    expect(chatLifecycleView(session(state), page(state, "turn_not_active"))).toMatchObject({
      statusLabel: "Unavailable",
      canEditDraft: true,
      canRetry: false,
      notice: "This terminal is not actively receiving messages. Your draft stays here.",
    });
  });
});
