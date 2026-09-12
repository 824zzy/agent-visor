import { describe, expect, it } from "vitest";
import { TRANSCRIPT_STALE_CEILING_MS, transcriptPhase } from "./transcript-phase.js";

const now = Date.parse("2026-09-12T18:00:00.000Z");
const minutes = (count: number) => count * 60_000;

describe("transcriptPhase", () => {
  it("keeps a started turn Working while the transcript is fresh", () => {
    expect(transcriptPhase({ marker: "started", transcriptModifiedAt: now - minutes(29), now })).toBe("working");
    expect(transcriptPhase({ marker: "started", transcriptModifiedAt: now - TRANSCRIPT_STALE_CEILING_MS, now })).toBe("working");
  });

  it("turns a started turn into Recent once the transcript is quiet past the ceiling", () => {
    expect(transcriptPhase({ marker: "started", transcriptModifiedAt: now - minutes(31), now })).toBe("recent");
    expect(transcriptPhase({ marker: "started", transcriptModifiedAt: now - 65 * 24 * minutes(60), now })).toBe("recent");
  });

  it("keeps a completed turn Ready while fresh and makes it Recent when dormant", () => {
    expect(transcriptPhase({ marker: "completed", transcriptModifiedAt: now - minutes(5), now })).toBe("ready");
    expect(transcriptPhase({ marker: "completed", transcriptModifiedAt: now - minutes(41 * 60), now })).toBe("recent");
  });

  it("makes no claim without a marker or without a known modification time", () => {
    expect(transcriptPhase({ marker: "none", transcriptModifiedAt: now, now })).toBe("recent");
    expect(transcriptPhase({ marker: "started", transcriptModifiedAt: undefined, now })).toBe("recent");
    expect(transcriptPhase({ marker: "started", transcriptModifiedAt: "not a date", now })).toBe("recent");
  });

  it("accepts Date, epoch, and ISO inputs and a custom ceiling", () => {
    const iso = new Date(now - minutes(10)).toISOString();
    expect(transcriptPhase({ marker: "started", transcriptModifiedAt: iso, now: new Date(now) })).toBe("working");
    expect(transcriptPhase({ marker: "started", transcriptModifiedAt: new Date(now - minutes(10)), now, staleCeilingMs: minutes(5) })).toBe("recent");
  });

  it("treats a modification time in the future as fresh", () => {
    expect(transcriptPhase({ marker: "started", transcriptModifiedAt: now + minutes(2), now })).toBe("working");
  });
});
