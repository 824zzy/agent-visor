import type { SessionSummary } from "@agent-visor/protocol";

/**
 * The selected Chat identity is independent from the current Sessions page.
 * `lastKnownSession` is a display snapshot only; current rows remain the
 * source of action capabilities.
 */
export type ChatSelection = {
  sessionId?: string;
  lastKnownSession?: SessionSummary;
};

export type ChatSelectionAction =
  | { type: "open"; session: SessionSummary }
  | { type: "navigate"; sessionId: string; sessions: readonly SessionSummary[] }
  | { type: "refresh"; sessions: readonly SessionSummary[] }
  | { type: "back" };

export function reduceChatSelection(
  selection: ChatSelection,
  action: ChatSelectionAction,
): ChatSelection {
  if (action.type === "back") return emptySelection(selection);

  if (action.type === "open") {
    return selection.sessionId === action.session.id
      && selection.lastKnownSession === action.session
      ? selection
      : { sessionId: action.session.id, lastKnownSession: action.session };
  }

  if (action.type === "navigate") {
    const current = action.sessions.find(({ id }) => id === action.sessionId);
    if (current) {
      return selection.sessionId === current.id && selection.lastKnownSession === current
        ? selection
        : { sessionId: current.id, lastKnownSession: current };
    }
    // Keep the existing behavior for explicit navigation to an unknown ID:
    // return to Sessions instead of hiding the browser behind an empty Chat.
    return emptySelection(selection);
  }

  const current = selection.sessionId
    ? action.sessions.find(({ id }) => id === selection.sessionId)
    : undefined;
  if (current) {
    return selection.lastKnownSession === current
      ? selection
      : { sessionId: current.id, lastKnownSession: current };
  }
  if (selection.sessionId && selection.lastKnownSession?.id === selection.sessionId) return selection;
  return emptySelection(selection);
}

/**
 * Resolve the display summary for the selected Chat. A cached row can keep a
 * transcript visible after pagination refreshes, but its capabilities are
 * explicitly disabled until an exact current summary is available.
 */
export function chatSessionFor(
  selection: ChatSelection,
  sessions: readonly SessionSummary[],
): SessionSummary | undefined {
  if (!selection.sessionId) return undefined;
  const current = sessions.find(({ id }) => id === selection.sessionId);
  if (current) return current;
  const cached = selection.lastKnownSession;
  if (!cached || cached.id !== selection.sessionId) return undefined;
  return {
    ...cached,
    ambientEligible: false,
    canOpenOwner: false,
    canEnterChat: false,
  };
}

function emptySelection(selection: ChatSelection): ChatSelection {
  return selection.sessionId === undefined && selection.lastKnownSession === undefined
    ? selection
    : {};
}
