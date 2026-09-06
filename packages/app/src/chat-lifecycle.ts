import type { ChatPage, SessionState, SessionSummary } from "@agent-visor/protocol";

export type ChatLifecycleView = {
  conversation: SessionState["conversation"];
  turn: SessionState["turn"];
  route: SessionState["route"];
  unavailableReason?: SessionState["unavailableReason"];
  statusLabel: string;
  statusTone: "attention" | "ready" | "working" | "unavailable" | "archived";
  notice?: string;
  /** Keep the draft usable while the provider waits or reconnects. */
  canEditDraft: boolean;
  /** A retry refreshes the exact opened conversation's capabilities. */
  canRetry: boolean;
};

const transientReasons = new Set<NonNullable<SessionState["unavailableReason"]>>([
  "conversation_unavailable",
  "native_helper_unavailable",
  "provider_unavailable",
  "unknown",
]);

/**
 * Project provider state into the small renderer contract used by Chat.
 *
 * `section` and `attentionTier` deliberately do not participate here. They
 * order the Sessions list; they do not describe whether the opened
 * conversation can be continued or whether a current turn can be stopped.
 */
export function chatLifecycleView(
  session: Pick<SessionSummary, "sessionState" | "owner">,
  page?: Pick<ChatPage, "sessionState" | "capabilities">,
): ChatLifecycleView {
  const state = page?.sessionState ?? session.sessionState ?? unknownSessionState();
  const routeUnavailable = state.route !== "available";
  // Capability reasons are meaningful only while the advertised route is
  // unavailable. Do not let an older outage reason make a fresh ready page
  // look archived or owner-only.
  const unavailableReason = routeUnavailable
    ? page?.capabilities.unavailableReason ?? state.unavailableReason
    : state.conversation === "archived"
      ? "archived"
      : state.turn === "working" ? "turn_in_progress" : undefined;
  const archived = state.conversation === "archived" || unavailableReason === "archived";
  const permanentlyUnavailable = archived
    || unavailableReason === "automation"
    || unavailableReason === "unsupported";
  const canEditDraft = !permanentlyUnavailable;
  const canRetry = routeUnavailable
    && unavailableReason !== undefined
    && transientReasons.has(unavailableReason);
  // Keep the renderer's copy explicit for every known lifecycle reason. A
  // stale page can carry a legacy `readOnlyReason`; reusing it here would
  // make a temporary route loss look like a permanent read-only session.
  const notice = unavailableMessage(unavailableReason, session.owner);

  return {
    conversation: state.conversation,
    turn: state.turn,
    route: state.route,
    ...(unavailableReason ? { unavailableReason } : {}),
    statusLabel: unavailableReason === "owner_only"
      ? `Open in ${session.owner}`
      : statusLabel(state, unavailableReason),
    statusTone: statusTone(state, unavailableReason),
    ...((routeUnavailable || archived || state.turn === "working") ? { notice } : {}),
    canEditDraft,
    canRetry,
  };
}

function unknownSessionState(): SessionState {
  return { conversation: "unknown", turn: "unknown", route: "unavailable", unavailableReason: "unknown" };
}

function statusLabel(
  state: SessionState,
  reason: SessionState["unavailableReason"],
): string {
  if (state.conversation === "archived" || reason === "archived") return "Archived";
  if (state.turn === "needs_you") return "Needs you";
  if (state.turn === "working") return "In progress";
  if (state.turn === "ready" && state.route === "available") return "Ready";
  if (state.route === "waiting") return "Waiting";
  if (state.route === "unavailable") return "Unavailable";
  return "Checking availability";
}

function statusTone(
  state: SessionState,
  reason: SessionState["unavailableReason"],
): ChatLifecycleView["statusTone"] {
  if (state.conversation === "archived" || reason === "archived") return "archived";
  if (state.turn === "needs_you") return "attention";
  if (state.turn === "working") return "working";
  if (state.turn === "ready" && state.route === "available") return "ready";
  return "unavailable";
}

function unavailableMessage(reason: SessionState["unavailableReason"], owner: string): string {
  switch (reason) {
    case "automation": return `Automation sessions are read only. Continue in ${owner}.`;
    case "archived": return `This conversation is archived. Open it in ${owner} to restore it.`;
    case "conversation_unavailable": return "This conversation is temporarily unavailable. Your draft stays here.";
    case "native_helper_unavailable": return "The native helper is reconnecting. Your draft stays here.";
    case "owner_only": return `This session is currently owned by ${owner}. Continue there to send messages.`;
    case "provider_unavailable": return "The provider route is temporarily unavailable. Your draft stays here.";
    case "turn_in_progress": return "The current turn is still running. Send your message after it finishes.";
    case "turn_not_active": return "This terminal is not actively receiving messages. Your draft stays here.";
    case "unsupported": return `This provider does not support Chat in Agent Visor. Continue in ${owner}.`;
    default: return "Chat availability is being checked. Your draft stays here.";
  }
}

export function isTransientChatUnavailable(view: ChatLifecycleView): boolean {
  return view.unavailableReason !== undefined && transientReasons.has(view.unavailableReason);
}
