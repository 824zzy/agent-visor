export type ChatCancellationViewStatus = "canceling" | "confirmed" | "failed" | undefined;

export type ChatCancellationView = {
  visible: boolean;
  enabled: boolean;
  label: string;
  accessibilityLabel: string;
};

/** Keep the stop affordance honest when a page or session snapshot is stale. */
export function chatCancellationView(
  canCancel: boolean,
  status: ChatCancellationViewStatus,
): ChatCancellationView {
  // The daemon's exact cancellation capability is the authority for whether
  // Stop targets a live turn. List ordering is not a lifecycle signal.
  const active = canCancel;
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
