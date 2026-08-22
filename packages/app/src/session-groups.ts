import type { SessionSection, SessionSummary } from "@agent-visor/protocol";

const sections: ReadonlyArray<{
  id: SessionSection;
  title: string;
}> = [
  { id: "needs_you", title: "Needs you" },
  { id: "ready", title: "Ready to continue" },
  { id: "working", title: "In progress" },
  { id: "history", title: "History" },
];

export type SessionGroup = {
  id: SessionSection;
  title: string;
  sessions: SessionSummary[];
};

export function groupSessions(sessions: SessionSummary[]): SessionGroup[] {
  return sections.flatMap((section) => {
    const matching = sessions
      .filter((session) => session.section === section.id)
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));

    return matching.length === 0 ? [] : [{ ...section, sessions: matching }];
  });
}
