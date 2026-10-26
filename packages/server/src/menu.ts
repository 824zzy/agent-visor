import os from "node:os";
import {
  sessionLifecyclePresentation,
  sessionIsInactive,
  sessionPresenceProjection,
  sessionPresencePresentation,
  type NativeHelperUsageGlance,
  type SessionSnapshot,
} from "@agent-visor/protocol";
import type { NativeHelperEvent } from "./native-helper.js";
import type { SessionSnapshotSource } from "./sessions.js";
import { navigationStep } from "./navigation-diagnostics.js";

const attentionOrder = {
  needs_you: 0,
  ready: 1,
  working: 2,
  acknowledged_ready: 3,
  history: 4,
} as const;

const unavailablePresenceNotice = "Status unavailable: Agent Visor could not verify whether this conversation is open.";

type MenuSession = SessionSnapshot["sessions"][number] & { inactive?: boolean };

/** Native clicks must report a rejected focus instead of silently dropping it. */
export async function activateMenuPill(
  event: Extract<NativeHelperEvent, { event: "activate_pill" }>,
  source: Pick<SessionSnapshotSource, "current" | "focusSession" | "acknowledgeFailure">,
  dispatch: (message: NonNullable<ReturnType<typeof nativeActionFor>> | {
    type: "native_effect"; action: "session_focus_failed"; message: string; chatSessionId?: string;
  }) => void,
): Promise<void> {
  if (event.intent === "dismiss") {
    const session = source.current().sessions.find((candidate) => candidate.id === event.sessionId);
    if (session?.failureAlert === true) source.acknowledgeFailure?.(session.id);
    navigationStep("dismissed");
    return;
  }
  const action = nativeActionFor(event, source.current());
  if (action) {
    navigationStep(action.action === "open_chat" ? "chat" : "completed");
    dispatch(action);
    return;
  }
  const error = source.focusSession
    ? await source.focusSession(event.sessionId)
    : "Opening this session is unavailable.";
  navigationStep(error ? "failed" : "completed");
  if (error) dispatch({
    type: "native_effect", action: "session_focus_failed", message: error.slice(0, 1_000),
  });
}

/** Banner activation uses the same exact owner route as a normal pill click. */
export async function activateSessionNotification(
  event: Extract<NativeHelperEvent, { event: "notification_action" }>,
  source: Parameters<typeof activateMenuPill>[1],
  dispatch: Parameters<typeof activateMenuPill>[2],
): Promise<void> {
  if (event.action !== "activate") return;
  const action = nativeActionFor(event, source.current());
  if (action) {
    navigationStep("chat");
    dispatch(action);
    return;
  }
  await activateMenuPill({ version: 1, type: "event", event: "activate_pill", sessionId: event.sessionId }, source, message => {
    const session = source.current().sessions.find(({ id }) => id === event.sessionId);
    dispatch(message.type === "native_effect" && session?.canEnterChat
      ? { ...message, chatSessionId: session.id } : message);
  });
}

export function nativeActionFor(event: NativeHelperEvent, snapshot: SessionSnapshot) {
  if (event.event === "notification_permission") return undefined;
  if (event.event === "notification_action") {
    if (event.action !== "activate") return undefined;
    const session = snapshot.sessions.find((candidate) => candidate.id === event.sessionId);
    return session?.owner !== "Herdr" && session?.canEnterChat
      && (!session.canOpenOwner || session.sessionState?.routeOwnership === "owned")
      ? { type: "native_action", action: "open_chat", sessionId: session.id } as const
      : undefined;
  }
  if (!("sessionId" in event)) {
    return { type: "native_action", action: event.event } as const;
  }
  const session = snapshot.sessions.find((candidate) => candidate.id === event.sessionId);
  if (!session) return undefined;
  if (event.intent === "dismiss") return undefined;
  if (event.intent === "chat") {
    return session.canEnterChat
      ? { type: "native_action", action: "open_chat", sessionId: session.id } as const
      : undefined;
  }
  // An unavailable row without an exact owner route must stay on the safe
  // Sessions surface, where the user can explicitly retry detection. Never
  // turn a cached owner label into a focus request or guessed destination.
  if (session.presence?.state === "unknown" && !session.canOpenOwner) {
    return { type: "native_action", action: "open_sessions" } as const;
  }
  // Owner-first remains the normal path for source-backed sessions: bin.ts
  // resolves focus asynchronously when an owner route exists. A Chat-capable
  // row without that route needs an authoritative primary action instead of
  // silently dropping a normal click/Return.
  return session.owner !== "Herdr" && !session.canOpenOwner && session.canEnterChat
    ? { type: "native_action", action: "open_chat", sessionId: session.id } as const
    : undefined;
}

export function menuPresentation(
  snapshot: SessionSnapshot,
  usageGlances: NativeHelperUsageGlance[],
  now = Date.now(),
) {
  // Bound both native surfaces without truncating the full Sessions catalog.
  const cutoff = now - 7 * 24 * 60 * 60 * 1_000;
  const { sessions: presentedSessions } = sessionPresenceProjection(snapshot.sessions);
  const ordered = presentedSessions
    .map((session) => menuSession(session, now))
    .filter((session) => Date.parse(session.updatedAt) >= cutoff)
    .filter((session) => session.canOpenOwner || session.canEnterChat
      || (session.presence?.state === "unknown" && session.ambientEligible === true))
    .sort((left, right) => {
      const leftTier = left.attentionTier ?? left.section;
      const rightTier = right.attentionTier ?? right.section;
      const attentionDifference = attentionOrder[leftTier] - attentionOrder[rightTier];
      if (attentionDifference !== 0) return attentionDifference;
      const lifecycleDifference = historyLifecycleOrder(left, leftTier)
        - historyLifecycleOrder(right, rightTier);
      if (lifecycleDifference !== 0) return lifecycleDifference;
      return right.updatedAt.localeCompare(left.updatedAt)
        || left.id.localeCompare(right.id);
    });
  const navigatorPills = ordered.slice(0, 512).map(presentationPill);
  const pills = ordered
    // Automation and app-managed conversations stay in the navigator, while
    // direct conversations receive ambient menu-bar space and Ready attention.
    .filter(isAmbientSession)
    // Historical Claude failures stay searchable in the navigator, but only
    // a newly observed failure may occupy ambient menu-bar attention.
    .filter((session) => session.failureAlert !== false)
    .filter((session) => session.canOpenOwner
      || (session.section !== "history" && session.canEnterChat)
      || (session.presence?.state === "unknown" && session.ambientEligible === true))
    .slice(0, 64)
    .map(presentationPill);

  return { pills, navigatorPills, usageGlances };
}

/**
 * Inactivity changes native presentation, never source lifecycle or routing.
 * Unopened completions retain attention regardless of age.
 */
function menuSession(
  session: SessionSnapshot["sessions"][number],
  now: number,
): MenuSession {
  const lifecycle = sessionLifecyclePresentation(session);
  const currentAttention = session.attention?.evidence === "current"
    && lifecycle.status !== "closed";
  const retainedReady = session.presence?.state === "closed"
    && session.sessionState?.turn === "ready";
  if (currentAttention && session.attentionTier !== "needs_you") {
    return { ...session, attentionTier: "needs_you" };
  }
  if (session.completionUnseen || (lifecycle.status !== "ready" && !retainedReady)) return session;
  if (!sessionIsInactive(session, now)) return session;
  return {
    ...session,
    attentionTier: "history",
    inactive: true,
  };
}

function historyLifecycleOrder(
  session: MenuSession,
  attentionTier: keyof typeof attentionOrder,
): number {
  if (attentionTier !== "history") return 0;
  return sessionLifecyclePresentation(session).tone === "ready" && !session.inactive ? 0 : 1;
}

function isAmbientSession(session: SessionSnapshot["sessions"][number]): boolean {
  if (session.presence?.state === "unknown" && session.ambientEligible !== true) return false;
  return session.sessionClass !== "automation" && !session.managedBy
    && session.presence?.state !== "closed"
    && session.ambientEligible !== false;
}

function presentationPill(
  session: MenuSession,
  priority: number,
) {
  const title = (session.sessionClass === "automation"
    ? `Codex automation · ${session.project}`
    : session.source === "Codex" && session.title === "Codex session"
    ? `Codex · ${session.project}`
    : session.title).slice(0, 256);
  const sourceLabel = session.source === "Codex" && session.owner.startsWith("Codex ·")
    ? session.owner : session.source;
  const lifecycle = sessionLifecyclePresentation(session);
  const presence = sessionPresencePresentation(session);
  const detailRows = [
    ...(session.sourceProfile ? [{ label: "Profile", value: session.sourceProfile }] : []),
    ...(presence.group === "unavailable"
      ? [{ label: "Presence", value: unavailablePresenceNotice }]
      : []),
    ...(presence.attention?.evidence === "last_known"
      ? [{ label: "Attention", value: presence.attention.label }]
      : []),
  ];
  const subtitle = session.completionUnseen && session.section === "history"
    ? "Unopened" : session.subtitle;
  return {
    id: session.id,
    title,
    subtitle,
    source: sourceLabel,
    project: session.project,
    ...(session.canOpenOwner ? { owner: session.owner } : {}),
    ...(session.attentionTier ? { attentionTier: session.attentionTier } : {}),
    ...(session.completionUnseen ? { completionUnseen: true } : {}),
    ...(session.failureAlert !== undefined ? { failureAlert: session.failureAlert } : {}),
    lifecycleStatus: lifecycle.status,
    ...(session.inactive ? { inactive: true } : {}),
    inspector: {
      status: lifecycle.label,
      runtimeItems: [runtimeSource(session.source, session.owner)],
      detailRows,
      projectPath: displayPath(session.cwd),
      activityAt: session.updatedAt,
    },
    phase: session.section,
    priority,
    defaultOverflowEligible: isAmbientSession(session),
    accessibilityLabel: [
      title,
      lifecycle.label,
      ...(session.inactive ? ["Inactive"] : []),
      ...(presence.group === "unavailable" ? [unavailablePresenceNotice] : []),
      ...(presence.attention?.evidence === "last_known" ? [presence.attention.label] : []),
      ...(session.completionUnseen && session.section === "history" ? ["Unopened"] : []),
      sourceLabel,
      session.project,
      ...(session.managedBy ? [`Managed by ${session.managedBy}`] : []),
    ].join(", "),
  };
}

function runtimeSource(source: string, owner: string): string {
  if (source === "Paseo") return "Claude Code · Paseo";
  if (source === "Codex" && (owner === "Codex" || owner.startsWith("Codex ·"))) return "Codex Desktop";
  return source.localeCompare(owner, undefined, { sensitivity: "accent" }) === 0
    ? source
    : `${source} · ${owner}`;
}

function displayPath(cwd: string): string {
  const home = os.homedir();
  if (cwd === home) return "~";
  return cwd.startsWith(`${home}/`) ? `~${cwd.slice(home.length)}` : cwd;
}
