import type { SessionSection } from "@agent-visor/protocol";

export type ChatCancellationViewStatus = "canceling" | "confirmed" | "failed" | undefined;

export type ChatCancellationView = {
  visible: boolean;
  enabled: boolean;
  label: string;
  accessibilityLabel: string;
};

/** Keep the stop affordance honest when a page or session snapshot is stale. */
export function chatCancellationView(
  section: SessionSection,
  canCancel: boolean,
  status: ChatCancellationViewStatus,
): ChatCancellationView {
  const active = section === "working" && canCancel;
  if (status === "canceling") {
    return {
      visible: true,
      enabled: false,
      label: "Canceling…",
      accessibilityLabel: "Canceling agent",
    };
  }
  if (status === "confirmed") {
    return {
      visible: true,
      enabled: false,
      label: "Stopped",
      accessibilityLabel: "Agent stopped",
    };
  }
  if (status === "failed") {
    return {
      visible: true,
      enabled: active,
      label: active ? "Retry stop" : "Unable to stop",
      accessibilityLabel: active ? "Retry stopping agent" : "Unable to stop agent",
    };
  }
  return {
    visible: active,
    enabled: active,
    label: "Stop",
    accessibilityLabel: "Stop agent",
  };
}
