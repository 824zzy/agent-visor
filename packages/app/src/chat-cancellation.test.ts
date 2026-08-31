import { describe, expect, it } from "vitest";
import { chatCancellationView } from "./chat-cancellation.js";

describe("chat cancellation presentation", () => {
  it("only exposes Stop for an active working cancellable session", () => {
    expect(chatCancellationView("ready", true, undefined).visible).toBe(false);
    expect(chatCancellationView("working", false, undefined)).toEqual({
      visible: false,
      enabled: false,
      label: "Stop",
      accessibilityLabel: "Stop agent",
    });
    expect(chatCancellationView("working", true, undefined)).toEqual({
      visible: true,
      enabled: true,
      label: "Stop",
      accessibilityLabel: "Stop agent",
    });
  });

  it("disables repeated clicks while canceling and keeps outcomes accessible", () => {
    expect(chatCancellationView("working", true, "canceling")).toMatchObject({
      visible: true, enabled: false, label: "Canceling…", accessibilityLabel: "Canceling agent",
    });
    expect(chatCancellationView("history", false, "confirmed")).toMatchObject({
      visible: true, enabled: false, label: "Stopped", accessibilityLabel: "Agent stopped",
    });
    expect(chatCancellationView("working", true, "failed")).toMatchObject({
      visible: true, enabled: true, label: "Retry stop",
    });
    expect(chatCancellationView("ready", false, "failed")).toMatchObject({
      visible: true, enabled: false, label: "Unable to stop",
    });
  });
});
