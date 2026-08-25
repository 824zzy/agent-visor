import type { ClientMessage } from "@agent-visor/protocol";

export type DesktopNotificationAction = {
  action: "allow" | "deny";
  sessionId: string;
  toolUseId: string;
};

export function notificationActionFromDesktopMessage(
  value: unknown,
): DesktopNotificationAction | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const message = value as Record<string, unknown>;
  if (Object.keys(message).length !== 4
    || message.type !== "notification_action"
    || (message.action !== "allow" && message.action !== "deny")
    || typeof message.sessionId !== "string"
    || !message.sessionId
    || message.sessionId.length > 512
    || typeof message.toolUseId !== "string"
    || !message.toolUseId
    || message.toolUseId.length > 512) return undefined;
  return {
    action: message.action,
    sessionId: message.sessionId,
    toolUseId: message.toolUseId,
  };
}

export async function handleNotificationAction(
  value: unknown,
  source: {
    chatAction(message: Extract<ClientMessage, { type: "respond_chat" }>): Promise<string | undefined>;
  },
): Promise<string | undefined> {
  const action = notificationActionFromDesktopMessage(value);
  if (!action) return "Invalid notification action.";
  return source.chatAction({
    type: "respond_chat",
    id: "notification-action",
    sessionId: action.sessionId,
    toolUseId: action.toolUseId,
    decision: action.action,
  });
}
