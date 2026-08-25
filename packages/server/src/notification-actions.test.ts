import { describe, expect, it, vi } from "vitest";
import {
  handleNotificationAction,
  notificationActionFromDesktopMessage,
} from "./notification-actions.js";

describe("desktop notification actions", () => {
  it("accepts only an exact bounded approval response", () => {
    expect(notificationActionFromDesktopMessage({
      type: "notification_action", action: "allow",
      sessionId: "session-1", toolUseId: "tool-7",
    })).toEqual({ action: "allow", sessionId: "session-1", toolUseId: "tool-7" });
    expect(notificationActionFromDesktopMessage({
      type: "notification_action", action: "allow",
      sessionId: "", toolUseId: "tool-7",
    })).toBeUndefined();
    expect(notificationActionFromDesktopMessage({
      type: "notification_action", action: "allow_always",
      sessionId: "session-1", toolUseId: "tool-7",
    })).toBeUndefined();
  });

  it("delivers the decision to the exact session and tool request", async () => {
    const chatAction = vi.fn(async () => undefined);

    await expect(handleNotificationAction({
      type: "notification_action", action: "deny",
      sessionId: "session-1", toolUseId: "tool-7",
    }, { chatAction })).resolves.toBeUndefined();

    expect(chatAction).toHaveBeenCalledWith({
      type: "respond_chat",
      id: "notification-action",
      sessionId: "session-1",
      toolUseId: "tool-7",
      decision: "deny",
    });
  });
});
