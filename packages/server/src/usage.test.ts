import { describe, expect, it } from "vitest";
import { codexUsageGlance } from "./usage.js";

describe("Codex usage glance", () => {
  it("presents five-hour and weekly remaining limits with the strongest tone", () => {
    expect(codexUsageGlance({
      rateLimits: {
        primary: { usedPercent: 18, windowDurationMins: 300 },
        secondary: { usedPercent: 89, windowDurationMins: 10_080 },
      },
    })).toEqual({
      id: "codex",
      label: "5h 82% | 7d 11%",
      detail: "Codex usage, 5 hour 82 percent remaining, weekly 11 percent remaining",
      tone: "warning",
      priority: 100,
      accessibilityLabel: "Codex usage, 5 hour 82 percent remaining, weekly 11 percent remaining",
    });
  });

  it("omits unrecognized payloads instead of fabricating usage", () => {
    expect(codexUsageGlance({ rateLimits: {} })).toBeUndefined();
    expect(codexUsageGlance({ rateLimits: { primary: { usedPercent: "18" } } }))
      .toBeUndefined();
  });
});
