import {
  sessionLifecyclePresentation,
  sessionPresencePresentation,
  type SessionSection,
  type SessionSummary,
} from "@agent-visor/protocol";

type BrowserSection = SessionSection | "current_unknown" | "unavailable";

const legacySections: ReadonlyArray<{
  id: SessionSection;
  title: string;
}> = [
  { id: "needs_you", title: "Needs you" },
  { id: "ready", title: "Ready to continue" },
  { id: "working", title: "In progress" },
  { id: "history", title: "History" },
];

const presenceSections: ReadonlyArray<{
  id: BrowserSection;
  title: string;
}> = [
  { id: "needs_you", title: "Needs you" },
  { id: "working", title: "In progress" },
  { id: "ready", title: "Ready" },
  // A confirmed-open row with no current turn evidence still belongs under
  // Current. Keep this subgroup headingless so Status unavailable remains
  // reserved for unknown open/closed presence rather than unknown turn.
  { id: "current_unknown", title: "" },
  { id: "unavailable", title: "Status unavailable" },
  { id: "history", title: "History" },
];

export type SessionGroup = {
  id: BrowserSection | "results";
  title: string;
  sessions: SessionSummary[];
  parent?: "current";
};

export type SessionSelection = {
  groups: SessionGroup[];
  orderedSessions: SessionSummary[];
};

const pillNotices: Partial<Record<NonNullable<SessionSummary["claudePresence"]>, string>> = {
  unrecognized_title: "Pill hidden: terminal title cannot identify the displayed conversation.",
  ambiguous_title: "Pill hidden: duplicate Claude names in this folder. Rename one session.",
  read_failed: "Pill hidden: terminal could not be checked. Agent Visor will retry.",
  reader_unavailable: "Pill hidden: terminal detection is unavailable.",
  inventory_unavailable: "Pill hidden: Claude sessions could not be checked. Agent Visor will retry.",
  process_changed: "Pill hidden: terminal changed. Agent Visor will check again.",
};

/** Browser presentation never changes the provider state or action capabilities. */
export function sessionPresentation(session: SessionSummary, now = new Date()) {
  if (session.presence) {
    const resolved = sessionPresencePresentation(session);
    const section: BrowserSection = resolved.group === "current"
      ? resolved.subgroup ?? "current_unknown"
      : resolved.group;
    const title = presenceSections.find(({ id }) => id === section)!.title;
    const pillNotice = resolved.group === "unavailable"
      ? "Status unavailable: Agent Visor could not verify whether this conversation is open."
      : undefined;
    return {
      section,
      title,
      subtitle: session.subtitle,
      ...(pillNotice ? { pillNotice } : {}),
    };
  }

  const tier = session.attentionTier ?? session.section;
  let section: SessionSection = tier === "acknowledged_ready" ? "ready" : tier;
  const lifecycle = sessionLifecyclePresentation(session);
  // History is a placement group. Preserve a provider-confirmed open Ready
  // label when the seven-day boundary moves the row out of Ready to continue.
  const knownOpenReady = session.sessionState?.conversation === "open"
    && lifecycle.status === "ready";
  const turn = session.sessionState?.turn;
  const completed = session.section === "ready" && (turn === undefined || turn === "ready");
  if (section === "ready" && completed
    && Date.parse(session.updatedAt) < now.valueOf() - 7 * 24 * 60 * 60 * 1_000) {
    section = "history";
  }
  const subtitle = section === "history" && (completed || knownOpenReady)
    ? `${session.managedBy ? `Managed by ${session.managedBy} · ` : ""}${knownOpenReady ? "Ready" : "Completed"}`
    : session.subtitle;
  const pillNotice = session.claudePresence ? pillNotices[session.claudePresence] : undefined;
  return { section, title: legacySections.find(({ id }) => id === section)!.title, subtitle,
    ...(pillNotice ? { pillNotice } : {}) };
}

export function groupSessions(sessions: SessionSummary[], now = new Date()): SessionGroup[] {
  const hasPresence = sessions.some(({ presence }) => presence !== undefined);
  const presentedSessions = hasPresence ? sessions.map((session) => compatibilityPresence(session)) : sessions;
  const sections = hasPresence
    ? presenceSections : legacySections;
  return sections.flatMap((section) => {
    const matching = presentedSessions
      .filter((session) => sessionPresentation(session, now).section === section.id)
      .sort(compareSessions);

    if (!matching.length) return [];
    return [{
      ...section,
      sessions: matching,
      ...(section.id === "needs_you" || section.id === "working" || section.id === "ready"
        || section.id === "current_unknown"
        ? { parent: "current" as const } : {}),
    }];
  });
}

export function selectSessions(sessions: SessionSummary[], query: string, now = new Date()): SessionSelection {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) {
    const groups = groupSessions(sessions, now);
    return { groups, orderedSessions: groups.flatMap(({ sessions }) => sessions) };
  }

  const hasPresence = sessions.some(({ presence }) => presence !== undefined);
  const presentedSessions = hasPresence ? sessions.map((session) => compatibilityPresence(session)) : sessions;
  const matches = presentedSessions
    .map((session) => ({ session, rank: searchRank(session, needle, now) }))
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

function searchRank(session: SessionSummary, needle: string, now: Date): number {
  if (session.title.toLocaleLowerCase().includes(needle)) return 0;
  const presentation = sessionPresentation(session, now);
  const lifecycle = sessionLifecyclePresentation(session);
  return [
    session.subtitle,
    presentation.subtitle,
    presentation.pillNotice ?? "",
    lifecycle.label,
    session.source,
    session.sourceProfile ?? "",
    session.project,
    session.owner,
    session.cwd,
  ]
    .some((value) => value.toLocaleLowerCase().includes(needle)) ? 1 : 2;
}

function compareSessions(left: SessionSummary, right: SessionSummary): number {
  return right.updatedAt.localeCompare(left.updatedAt) || left.id.localeCompare(right.id);
}

/**
 * During incremental adapter adoption, a mixed snapshot must not make an
 * unconverted row look Current or Closed merely because its legacy section
 * says so. Keep it readable while projecting the explicit unavailable state
 * only at this presentation boundary; the repository snapshot stays intact.
 */
function compatibilityPresence(session: SessionSummary): SessionSummary {
  if (session.presence) return session;
  return {
    ...session,
    presence: {
      state: "unknown",
      evidence: "unavailable",
      observedAt: session.updatedAt,
    },
  };
}
