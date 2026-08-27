import type { SessionAttentionTier, SessionSummary } from "@agent-visor/protocol";

const sections: ReadonlyArray<{
  id: SessionAttentionTier;
  title: string;
}> = [
  { id: "needs_you", title: "Needs you" },
  { id: "ready", title: "Ready to continue" },
  { id: "working", title: "In progress" },
  { id: "acknowledged_ready", title: "Ready to continue" },
  { id: "history", title: "History" },
];

export type SessionGroup = {
  id: SessionAttentionTier | "results";
  title: string;
  sessions: SessionSummary[];
};

export type SessionSelection = {
  groups: SessionGroup[];
  orderedSessions: SessionSummary[];
};

export function groupSessions(sessions: SessionSummary[]): SessionGroup[] {
  return sections.flatMap((section) => {
    const matching = sessions
      .filter((session) => (session.attentionTier ?? session.section) === section.id)
      .sort(compareSessions);

    return matching.length === 0 ? [] : [{ ...section, sessions: matching }];
  });
}

export function selectSessions(sessions: SessionSummary[], query: string): SessionSelection {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) {
    const groups = groupSessions(sessions);
    return { groups, orderedSessions: groups.flatMap(({ sessions }) => sessions) };
  }

  const matches = sessions
    .map((session) => ({ session, rank: searchRank(session, needle) }))
    .filter(({ rank }) => rank < 2)
    .sort((left, right) => left.rank - right.rank || compareSessions(left.session, right.session))
    .map(({ session }) => session);
  return {
    groups: matches.length ? [{ id: "results", title: "Results", sessions: matches }] : [],
    orderedSessions: matches,
  };
}

export type CursorDecision = { cursorId?: string; revealId?: string };

export function reconcileSessionCursor(
  currentId: string | undefined,
  previousIds: string[],
  visibleIds: string[],
  reason: "background" | "query",
): CursorDecision {
  if (reason === "query") {
    const cursorId = visibleIds[0];
    return cursorId ? { cursorId, revealId: cursorId } : {};
  }
  if (currentId && visibleIds.includes(currentId)) return { cursorId: currentId };
  if (!visibleIds.length) return {};
  const priorIndex = currentId ? previousIds.indexOf(currentId) : -1;
  if (priorIndex >= 0) {
    for (let distance = 1; distance < previousIds.length; distance += 1) {
      const next = previousIds[priorIndex + distance];
      if (next && visibleIds.includes(next)) return { cursorId: next };
      const previous = previousIds[priorIndex - distance];
      if (previous && visibleIds.includes(previous)) return { cursorId: previous };
    }
  }
  return { cursorId: visibleIds[0] };
}

export function moveSessionCursor(
  currentId: string | undefined,
  visibleIds: string[],
  offset: number,
): CursorDecision {
  if (!visibleIds.length) return {};
  const foundIndex = visibleIds.indexOf(currentId ?? "");
  const currentIndex = foundIndex >= 0 ? foundIndex : (offset > 0 ? -1 : 0);
  const index = Math.max(0, Math.min(visibleIds.length - 1, currentIndex + offset));
  const cursorId = visibleIds[index]!;
  return { cursorId, revealId: cursorId };
}

export function sessionAction(
  session: SessionSummary,
  alternate = false,
): "owner" | "chat" | undefined {
  if (alternate) {
    if (session.canEnterChat) return "chat";
    return session.canOpenOwner ? "owner" : undefined;
  }
  if (session.canOpenOwner) return "owner";
  return session.canEnterChat ? "chat" : undefined;
}

export function relativeSessionAge(updatedAt: string, now = new Date()): string {
  const minutes = Math.max(0, Math.floor((now.valueOf() - Date.parse(updatedAt)) / 60_000));
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

function searchRank(session: SessionSummary, needle: string): number {
  if (session.title.toLocaleLowerCase().includes(needle)) return 0;
  return [session.subtitle, session.source, session.project, session.owner, session.cwd]
    .some((value) => value.toLocaleLowerCase().includes(needle)) ? 1 : 2;
}

function compareSessions(left: SessionSummary, right: SessionSummary): number {
  return right.updatedAt.localeCompare(left.updatedAt) || left.id.localeCompare(right.id);
}
