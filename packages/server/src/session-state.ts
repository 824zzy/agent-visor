import type {
  ChatCapabilities,
  SessionConversationState,
  SessionState,
  SessionRouteOwnership,
  SessionTurnState,
  SessionUnavailableReason,
} from "@agent-visor/protocol";
import { NATIVE_HELPER_MAX_TEXT_BYTES } from "@agent-visor/protocol";
import type { DiscoveredProviderSession } from "./sessions.js";
import { isVerifiableProcessInstanceToken } from "./providers/shared.js";

export type SessionStateOptions = {
  /** Native helper availability is a route fact, not a conversation fact. */
  nativeHelperAvailable?: boolean;
};

/**
 * Resolve provider evidence into the one action projection shared by Chat,
 * controls, and session presentation. `section` is intentionally absent: it
 * is an attention/list grouping and must not decide whether a conversation is
 * writable.
 */
export function resolveSessionState(
  session: DiscoveredProviderSession,
  options: SessionStateOptions = {},
): SessionState {
  const conversation = conversationState(session);
  const turn = sessionTurnState(session);
  const nativeHelperAvailable = options.nativeHelperAvailable !== false;

  if (session.sessionClass === "automation") {
    return unavailable(conversation, turn, "automation");
  }
  if (conversation === "archived") {
    return unavailable(conversation, turn, "archived");
  }
  if (conversation !== "open") {
    return unavailable(conversation, turn, "conversation_unavailable");
  }
  if (session.resolutionUnavailable) {
    // The transcript route may still be readable from a cached record, but a
    // failed exact provider lookup cannot prove that the native write route is
    // still owned by this session.
    return unavailable(conversation, turn, "provider_unavailable");
  }

  if (session.provider === "codex" && session.messageTransport === "codex_app_server") {
    const routeOwnership = session.routeOwnership
      ?? (session.routeState === "available" ? "unverified" : undefined);
    if (session.releasePending) {
      return unavailable(conversation, turn, "provider_unavailable", "unavailable", routeOwnership);
    }
    // A lost route is a retryable provider outage even when the transcript
    // still carries the last known Working turn. Do not leave the composer in
    // a permanent WAIT state after the acquired child has exited.
    if (session.routeState !== "available") {
      return unavailable(
        conversation,
        turn,
        session.routeUnavailableReason ?? "provider_unavailable",
        "unavailable",
        routeOwnership,
      );
    }
    if (turn === "working" || turn === "needs_you") {
      // The app-server route can resume a thread, but we have no verified
      // steering/queue protocol for an already running owner turn. Keep the
      // draft waiting instead of starting a competing turn.
      return unavailable(conversation, turn, "turn_in_progress", "waiting", routeOwnership);
    }
    if (turn === "ready") return available(conversation, turn, routeOwnership);
    return unavailable(conversation, turn, "provider_unavailable", "unavailable", routeOwnership);
  }

  if (isTerminalRoute(session)) {
    if (!nativeHelperAvailable) {
      return unavailable(conversation, turn, "native_helper_unavailable");
    }
    if (!verifiedTerminalRoute(session)) {
      return unavailable(conversation, turn, "provider_unavailable");
    }
    if (turn === "working") {
      // A terminal process being alive does not mean it is ready for another
      // prompt. Keep the composer waiting while preserving exact Stop via the
      // independent cancellation capability.
      return unavailable(conversation, turn, "turn_in_progress", "waiting");
    }
    if (turn === "ready") return available(conversation, turn);
    // Unknown lifecycle evidence is an unavailable provider fact, not proof
    // that the terminal is idle. Reserve turn_not_active for an explicit
    // terminal state that cannot receive another prompt.
    return unavailable(conversation, turn, "provider_unavailable");
  }

  if (session.owner === "Zed" || session.provider === "cursor") {
    return unavailable(conversation, turn, "owner_only");
  }
  if (session.canOpenOwner) return unavailable(conversation, turn, "owner_only");
  return unavailable(conversation, turn, "unsupported");
}

export function sessionTurnState(session: DiscoveredProviderSession): SessionTurnState {
  if (session.turnState) return session.turnState;
  if (session.codexLifecycle?.phase === "working") return "working";
  if (session.codexLifecycle?.phase === "ready") return "ready";
  // A live process or a list row alone does not prove the turn phase. Native
  // providers must supply explicit metadata/hooks before terminal input is
  // enabled; this is deliberately fail-closed for legacy records.
  if (session.messageTransport === "terminal"
    || (session.provider === "codex" && session.messageTransport === "codex_app_server")) {
    return "unknown";
  }
  // Section is an attention/list grouping, not provider turn evidence. Older
  // records without an explicit lifecycle fact stay unknown and fail closed.
  return "unknown";
}

export function conversationState(
  session: DiscoveredProviderSession,
): SessionConversationState {
  if (session.conversationState) return session.conversationState;
  // A stable native terminal route is provider evidence that the conversation
  // still exists. Other legacy history rows remain unknown and fail closed.
  if (session.messageTransport === "terminal" && session.controlTarget?.kind === "terminal") {
    return "open";
  }
  // Codex app-server records are provider-owned conversations. New adapter
  // records carry this field explicitly; retain the safe legacy default for
  // synthetic/older records that still have a concrete transcript route.
  if (session.provider === "codex"
    && session.messageTransport === "codex_app_server"
    && session.chatPath) {
    return "open";
  }
  return "unknown";
}

export function verifiedTerminalRoute(session: DiscoveredProviderSession): boolean {
  return isTerminalRoute(session)
    && session.controlTarget?.kind === "terminal"
    && isVerifiableProcessInstanceToken(
      session.controlTarget.target.pid,
      session.controlTarget.target.processStartToken,
    );
}

export function isTerminalRoute(session: DiscoveredProviderSession): boolean {
  return session.messageTransport === "terminal"
    && session.controlTarget?.kind === "terminal"
    && (session.provider === "claude_code" || session.provider === "pi");
}

export function chatCapabilitiesForState(
  session: DiscoveredProviderSession,
  options: SessionStateOptions = {},
): ChatCapabilities {
  const state = resolveSessionState(session, options);
  const canSendText = state.route === "available";
  const terminal = verifiedTerminalRoute(session);
  // Cancellation is independent from next-turn sendability. A known busy
  // Codex turn is intentionally waiting for input, but its exact owned turn
  // may still be cancellable once controls confirm the delivery identity.
  const codexWorking = session.provider === "codex"
    && session.messageTransport === "codex_app_server"
    && session.routeState === "available"
    && state.turn === "working";
  const canCancel = (codexWorking || (
    terminal && state.route !== "unavailable" && state.turn === "working"
  ));
  return {
    canSendText,
    canSendImages: canSendText && (
      (session.provider === "codex" && session.messageTransport === "codex_app_server")
      || (session.provider === "pi" && terminal)
      || (session.provider === "claude_code"
        && terminal
        && session.controlTarget?.kind === "terminal"
        && session.controlTarget.target.application !== "Terminal")
    ),
    canCancel,
    canApprove: false,
    canAnswer: false,
    ...(session.provider === "claude_code" && terminal
      ? { canCyclePermissionMode: canSendText } : {}),
    ...(terminal ? { maxTextBytes: NATIVE_HELPER_MAX_TEXT_BYTES } : {}),
    ...(state.unavailableReason ? { unavailableReason: state.unavailableReason } : {}),
    ...(canSendText ? {} : { readOnlyReason: unavailableMessage(state.unavailableReason) }),
  };
}

export function unavailableMessage(reason: SessionUnavailableReason | undefined): string {
  switch (reason) {
    case "automation": return "Automation sessions are read only.";
    case "archived": return "This conversation is archived. Open it in the source app to restore it.";
    case "conversation_unavailable": return "This conversation is not currently available.";
    case "native_helper_unavailable": return "The native helper is unavailable. Chat is read only until it recovers.";
    case "owner_only": return "Continue in the source app. Chat is read only here.";
    case "provider_unavailable": return "The provider route is temporarily unavailable.";
    case "turn_in_progress": return "Wait for this turn to finish before sending.";
    case "turn_not_active": return "This terminal is not actively receiving messages.";
    case "unsupported": return "This provider does not support Chat in Agent Visor.";
    default: return "Chat is read only until the conversation route is available.";
  }
}

function available(
  conversation: SessionConversationState,
  turn: SessionTurnState,
  routeOwnership?: SessionRouteOwnership,
): SessionState {
  return {
    conversation,
    turn,
    route: "available",
    ...(routeOwnership ? { routeOwnership } : {}),
  };
}

function unavailable(
  conversation: SessionConversationState,
  turn: SessionTurnState,
  reason: SessionUnavailableReason,
  route: SessionState["route"] = "unavailable",
  routeOwnership?: SessionRouteOwnership,
): SessionState {
  return {
    conversation,
    turn,
    route,
    ...(routeOwnership ? { routeOwnership } : {}),
    unavailableReason: reason,
  };
}
