import { describe, expect, it } from "vitest";
import { chatCancellationView } from "./chat-cancellation.js";

describe("chat cancellation presentation", () => {
  it("only exposes Stop when the daemon confirms an exact cancellable turn", () => {
    expect(chatCancellationView(true, undefined)).toEqual({
      visible: true,
      enabled: true,
      label: "Stop",
      accessibilityLabel: "Stop agent",
    });
    expect(chatCancellationView(false, undefined)).toEqual({
      visible: false,
      enabled: false,
      label: "Stop",
      accessibilityLabel: "Stop agent",
    });
    expect(chatCancellationView(true, undefined)).toEqual({
      visible: true,
      enabled: true,
      label: "Stop",
      accessibilityLabel: "Stop agent",
    });
  });

  it("disables repeated clicks while canceling and keeps outcomes accessible", () => {
    expect(chatCancellationView(true, "canceling")).toMatchObject({
      visible: true, enabled: false, label: "Canceling…", accessibilityLabel: "Canceling agent",
    });
    expect(chatCancellationView(false, "confirmed")).toMatchObject({
      visible: true, enabled: false, label: "Stopped", accessibilityLabel: "Agent stopped",
    });
    expect(chatCancellationView(true, "failed")).toMatchObject({
      visible: true, enabled: true, label: "Retry stop",
    });
    expect(chatCancellationView(false, "failed")).toMatchObject({
      visible: true, enabled: false, label: "Unable to stop",
    });
  });
});
