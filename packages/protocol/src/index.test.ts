import { describe, expect, it } from "vitest";
import {
  PROTOCOL_VERSION,
  chatPageSchema,
  clientMessageSchema,
  nativeServicesStateSchema,
  serverMessageSchema,
  sessionSnapshotSchema,
} from "./index.js";

describe("session snapshot protocol", () => {
  it("accepts one complete macOS session summary", () => {
    const snapshot = {
      type: "session_snapshot",
      revision: 7,
      sessions: [
        {
          id: "pi-123",
          title: "Fix provider timeout",
          subtitle: "Waiting for review",
          source: "Pi",
          project: "agent-visor",
          owner: "Ghostty",
          cwd: "/Users/me/Codes/agent-visor",
          section: "ready",
          updatedAt: "2026-08-22T08:00:00.000Z",
          canOpenOwner: true,
          canEnterChat: true,
        },
      ],
    };

    expect(sessionSnapshotSchema.parse(snapshot)).toEqual(snapshot);
  });

  it("rejects unknown sections instead of inventing UI state", () => {
    expect(() =>
      sessionSnapshotSchema.parse({
        type: "session_snapshot",
        revision: 1,
        sessions: [{ section: "almost_done" }],
      }),
    ).toThrow();
  });

  it("validates the versioned hello message", () => {
    expect(
      serverMessageSchema.parse({
        type: "hello",
        protocolVersion: PROTOCOL_VERSION,
      }),
    ).toEqual({ type: "hello", protocolVersion: 1 });
  });

  it("validates paged Chat content and capability-aware actions", () => {
    const page = {
      type: "chat_page",
      sessionId: "session-1",
      items: [
        { id: "user-1", kind: "user", text: "Fix it", images: [], timestamp: "2026-08-22T10:00:00.000Z" },
        { id: "tool-1", kind: "tool", name: "Bash", input: { command: "npm test" }, status: "success", result: "45 passed", timestamp: "2026-08-22T10:00:01.000Z" },
      ],
      hasMoreBefore: true,
      nextBefore: 2048,
      capabilities: {
        canSendText: true,
        canSendImages: false,
        canApprove: true,
        canAnswer: true,
      },
      pendingAction: null,
    };
    expect(chatPageSchema.parse(page)).toEqual(page);
    expect(chatPageSchema.safeParse({ ...page, unexpected: true }).success).toBe(false);
  });

  it("validates settings, permission, and update messages", () => {
    const state = {
      type: "native_services_state",
      revision: 3,
      settings: {
        appearance: "dark",
        contentScale: 1.2,
        pillsEnabled: true,
        codexUsageGlanceEnabled: true,
        claudeUsageGlanceEnabled: false,
        notificationSound: "Pop",
        sessionShortcutModifierFamily: "optionCommand",
        editorPreference: "auto",
        observedWindowHours: 42,
        launchAtLogin: false,
      },
      permissions: { accessibility: "granted", notifications: "authorized" },
      update: { status: "up_to_date", currentVersion: "2.6.2" },
    };
    expect(nativeServicesStateSchema.parse(state)).toEqual(state);
    expect(clientMessageSchema.safeParse({ type: "get_native_services" }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "update_settings", id: "settings-1", patch: { appearance: "system" },
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "native_service_action", id: "native-1", action: "request_accessibility",
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "native_service_action", id: "native-2", action: "invented",
    }).success).toBe(false);
  });

  it("validates Chat page, send, and response client messages", () => {
    expect(clientMessageSchema.safeParse({
      type: "open_chat", sessionId: "session-1", before: 2048, limit: 500,
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "send_chat", id: "request-1", sessionId: "session-1", text: "Continue", images: [],
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "respond_chat", id: "request-2", sessionId: "session-1", toolUseId: "tool-1", decision: "allow",
    }).success).toBe(true);
    expect(clientMessageSchema.safeParse({
      type: "respond_chat", id: "request-2", sessionId: "session-1", toolUseId: "tool-1", decision: "invented",
    }).success).toBe(false);
  });
});
