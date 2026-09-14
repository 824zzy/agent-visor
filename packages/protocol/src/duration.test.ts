import { describe, expect, it } from "vitest";
import { formatDuration, parseDuration } from "./duration.js";

describe("duration", () => {
  it("formats with the unit a reader expects", () => {
    expect(formatDuration(850)).toBe("850ms");
    expect(formatDuration(4_500)).toBe("4.5s");
    expect(formatDuration(42_000)).toBe("42s");
    expect(formatDuration(91_000)).toBe("1m 31s");
    expect(formatDuration(6 * 60_000)).toBe("6m");
    expect(formatDuration(65 * 60_000 + 30_000)).toBe("1h 5m");
    expect(formatDuration(2 * 3_600_000)).toBe("2h");
    expect(formatDuration(-5)).toBe("0ms");
  });

  it("parses what it formats, inside a labelled row", () => {
    for (const ms of [850, 4_500, 42_000, 91_000, 6 * 60_000, 65 * 60_000, 2 * 3_600_000]) {
      expect(parseDuration(`Turn duration: ${formatDuration(ms)}`)).toBe(ms);
    }
    expect(parseDuration("Turn duration: 396s")).toBe(396_000);
    expect(parseDuration("no duration here")).toBeUndefined();
  });
});
