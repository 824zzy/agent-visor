import { describe, expect, it } from "vitest";
import type { SessionSummary } from "@agent-visor/protocol";
import { groupSessions } from "./session-groups.js";

const session = (
  id: string,
  section: SessionSummary["section"],
  updatedAt: string,
): SessionSummary => ({
  id,
  title: id,
  subtitle: "",
  source: "Pi",
  project: "agent-visor",
  owner: "Ghostty",
  cwd: "/tmp/agent-visor",
  section,
  updatedAt,
  canOpenOwner: true,
  canEnterChat: true,
});

describe("groupSessions", () => {
  it("uses the product section order and sorts recent work first", () => {
    const groups = groupSessions([
      session("older-history", "history", "2026-08-20T10:00:00.000Z"),
      session("working", "working", "2026-08-22T09:00:00.000Z"),
      session("needs-you", "needs_you", "2026-08-22T08:00:00.000Z"),
      session("newer-history", "history", "2026-08-21T10:00:00.000Z"),
      session("ready", "ready", "2026-08-22T07:00:00.000Z"),
    ]);

    expect(groups.map((group) => group.title)).toEqual([
      "Needs you",
      "Ready to continue",
      "In progress",
      "History",
    ]);
    expect(groups[3]?.sessions.map(({ id }) => id)).toEqual([
      "newer-history",
      "older-history",
    ]);
  });

  it("omits empty sections", () => {
    expect(
      groupSessions([
        session("working", "working", "2026-08-22T09:00:00.000Z"),
      ]).map(({ title }) => title),
    ).toEqual(["In progress"]);
  });
});
