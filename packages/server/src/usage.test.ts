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

  it("does not invent a five-hour limit when Codex reports only a weekly window", () => {
    expect(codexUsageGlance({
      rateLimits: {
        primary: { usedPercent: 2, windowDurationMins: 10_080 },
        secondary: null,
      },
    })).toEqual({
      id: "codex",
      label: "7d 98%",
      detail: "Codex usage, weekly 98 percent remaining",
      tone: "normal",
      priority: 100,
      accessibilityLabel: "Codex usage, weekly 98 percent remaining",
    });
  });

  it("omits unrecognized payloads instead of fabricating usage", () => {
    expect(codexUsageGlance({ rateLimits: {} })).toBeUndefined();
    expect(codexUsageGlance({ rateLimits: { primary: { usedPercent: "18" } } }))
      .toBeUndefined();
  });
});
