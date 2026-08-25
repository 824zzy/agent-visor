import { describe, expect, it } from "vitest";
import { codexUsageGlance } from "./usage.js";

describe("Codex usage glance", () => {
  it("presents five-hour and weekly remaining limits with the strongest tone", () => {
    expect(codexUsageGlance({
      rateLimits: {
        primary: { usedPercent: 18, windowDurationMins: 300 },
        secondary: { usedPercent: 89, windowDurationMins: 10_080 },
      },
    }, new Date("2026-08-24T12:00:00.000Z"))).toEqual({
      id: "codex",
      heading: "Codex Usage",
      width: 114,
      label: "5h 82% | 7d 11%",
      detail: "Codex usage, 5 hour 82 percent remaining, weekly 11 percent remaining",
      tone: "warning",
      priority: 100,
      accessibilityLabel: "Codex usage, 5 hour 82 percent remaining, weekly 11 percent remaining",
      observedAt: "2026-08-24T12:00:00.000Z",
      windows: [
        {
          title: "5 hour limit", remainingPercent: 82, tone: "normal",
        },
        {
          title: "Weekly limit", remainingPercent: 11, tone: "warning",
        },
      ],
    });
  });

  it("retains authoritative reset details for the usage popover", () => {
    expect(codexUsageGlance({
      rateLimits: {
        primary: {
          usedPercent: 18,
          windowDurationMins: 300,
          resetsAt: 1_700_001_800,
        },
        secondary: {
          usedPercent: 39,
          windowDurationMins: 10_080,
          resetsAt: 1_700_604_800,
        },
      },
      rateLimitResetCredits: { availableCount: 3 },
    }, new Date("2026-08-24T12:00:00.000Z"))).toMatchObject({
      heading: "Codex Usage",
      width: 114,
      observedAt: "2026-08-24T12:00:00.000Z",
      windows: [
        {
          title: "5 hour limit",
          remainingPercent: 82,
          tone: "normal",
          resetsAt: "2023-11-14T22:43:20.000Z",
        },
        {
          title: "Weekly limit",
          remainingPercent: 61,
          tone: "normal",
          resetsAt: "2023-11-21T22:13:20.000Z",
        },
      ],
      resetCreditsAvailable: 3,
    });
  });

  it("does not invent a five-hour limit when Codex reports only a weekly window", () => {
    expect(codexUsageGlance({
      rateLimits: {
        primary: { usedPercent: 2, windowDurationMins: 10_080 },
        secondary: null,
      },
    }, new Date("2026-08-24T12:00:00.000Z"))).toEqual({
      id: "codex",
      heading: "Codex Usage",
      width: 64,
      label: "7d 98%",
      detail: "Codex usage, weekly 98 percent remaining",
      tone: "normal",
      priority: 100,
      accessibilityLabel: "Codex usage, weekly 98 percent remaining",
      observedAt: "2026-08-24T12:00:00.000Z",
      windows: [{
        title: "Weekly limit", remainingPercent: 98, tone: "normal",
      }],
    });
  });

  it("omits malformed reset times without losing valid usage", () => {
    expect(codexUsageGlance({
      rateLimits: {
        primary: {
          usedPercent: 18,
          windowDurationMins: 300,
          resetsAt: Number.MAX_VALUE,
        },
      },
    }, new Date("2026-08-24T12:00:00.000Z"))?.windows).toEqual([
      {
        title: "5 hour limit", remainingPercent: 82, tone: "normal",
      },
    ]);
  });

  it("omits unrecognized payloads instead of fabricating usage", () => {
    expect(codexUsageGlance({ rateLimits: {} })).toBeUndefined();
    expect(codexUsageGlance({ rateLimits: { primary: { usedPercent: "18" } } }))
      .toBeUndefined();
    expect(codexUsageGlance({
      rateLimits: {
        primary: { usedPercent: 18, windowDurationMins: 60 },
        secondary: { usedPercent: 39, windowDurationMins: 1_440 },
      },
    })).toBeUndefined();
  });
});
