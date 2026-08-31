import type { ChatDeliveryRecoveryRecord } from "./chat-delivery-recovery";

export type ChatRecoveryView = {
  recoveryId: string;
  title: string;
  reason: string;
  retryLabel: string;
  dismissLabel: string;
  retryEnabled: boolean;
  dismissEnabled: boolean;
  /** Canceled deliveries must not reintroduce their synthetic transcript row. */
  syntheticRowVisible: boolean;
  accessibilityLabel: string;
  attachmentsLabel?: string;
};

/** Keep recovery copy and affordance state consistent across all Chat cards. */
export function chatRecoveryView(record: ChatDeliveryRecoveryRecord): ChatRecoveryView {
  const canceled = record.status === "canceled";
  const retrying = record.status === "retrying";
  const uncertain = record.status === "uncertain" || record.status === "awaiting-canonical";
  const title = retrying
    ? "Retrying message"
    : uncertain ? "Delivery uncertain" : canceled ? "Message canceled" : "Message failed";
  const retryLabel = retrying
    ? "Retrying message"
    : canceled ? "Retry canceled message" : "Retry failed message";
  const dismissLabel = canceled ? "Dismiss canceled message" : "Dismiss failed message";
  return {
    recoveryId: record.id,
    title,
    reason: record.error,
    retryLabel,
    dismissLabel,
    // An acknowledged action without canonical transcript proof is not safe
    // for an ordinary one-click retry. A future risk-confirmed action can use
    // the same recovery identity explicitly.
    retryEnabled: !retrying && !uncertain,
    dismissEnabled: !retrying,
    syntheticRowVisible: !canceled,
    accessibilityLabel: `${title}: ${record.error}`,
    ...(record.draft.images.length
      ? { attachmentsLabel: `Submitted attachments: ${record.draft.images.map(({ name }) => name).join(", ")}` }
      : {}),
  };
}
