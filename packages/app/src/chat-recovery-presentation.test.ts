import { describe, expect, it } from "vitest";
import { chatRecoveryView } from "./chat-recovery-presentation.js";

const record = (overrides: Partial<Parameters<typeof chatRecoveryView>[0]> = {}) => ({
  id: "session:1:delivery-1",
  sessionId: "session",
  generation: 1,
  requestId: "request-1",
  deliveryId: "delivery-1",
  draft: { text: "hello", images: [] },
  cause: "send-failed" as const,
  status: "failed" as const,
  error: "Provider rejected this message.",
  createdAt: 1,
  updatedAt: 1,
  ...overrides,
});

describe("Chat recovery card presentation", () => {
  it("exposes an accessible failed reason and attachment summary", () => {
    const view = chatRecoveryView(record({
      draft: {
        text: "hello",
        images: [{ name: "diagram.png", mimeType: "image/png", data: "iVBORw0KGgo=", byteLength: 8 }],
      },
    }));

    expect(view).toMatchObject({
      recoveryId: "session:1:delivery-1",
      title: "Message failed",
      reason: "Provider rejected this message.",
      retryLabel: "Retry failed message",
      dismissLabel: "Dismiss failed message",
      retryEnabled: true,
      dismissEnabled: true,
      syntheticRowVisible: true,
      accessibilityLabel: "Message failed: Provider rejected this message.",
      attachmentsLabel: "Submitted attachments: diagram.png",
    });
  });

  it("hides canceled synthetic rows while keeping retry and dismiss available", () => {
    const view = chatRecoveryView(record({
      id: "session:1:delivery-2",
      deliveryId: "delivery-2",
      cause: "canceled",
      status: "canceled",
      error: "The message was canceled before the provider confirmed it.",
    }));

    expect(view).toMatchObject({
      recoveryId: "session:1:delivery-2",
      title: "Message canceled",
      retryLabel: "Retry canceled message",
      dismissLabel: "Dismiss canceled message",
      retryEnabled: true,
      dismissEnabled: true,
      syntheticRowVisible: false,
    });
  });

  it("disables both actions while a retry is active and preserves target identity", () => {
    const first = chatRecoveryView(record({ status: "retrying" }));
    const second = chatRecoveryView(record({ id: "session:1:delivery-2", deliveryId: "delivery-2" }));

    expect(first).toMatchObject({
      recoveryId: "session:1:delivery-1",
      title: "Retrying message",
      retryLabel: "Retrying message",
      retryEnabled: false,
      dismissEnabled: false,
    });
    expect(second.recoveryId).toBe("session:1:delivery-2");
    expect(second.retryLabel).not.toBe(first.retryLabel);
  });
});
