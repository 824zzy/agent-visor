import os from "node:os";
import {
  TRANSCRIPT_STALE_CEILING_MS,
  sessionLifecyclePresentation,
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
  if (action?.action === "open_chat") {
    navigationStep("chat");
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
  const ordered = snapshot.sessions
    .map((session) => menuSession(session, now))
    .filter((session) => Date.parse(session.updatedAt) >= cutoff)
    .filter((session) => session.canOpenOwner || session.canEnterChat)
    .sort((left, right) => attentionOrder[left.attentionTier ?? left.section]
      - attentionOrder[right.attentionTier ?? right.section]
      || right.updatedAt.localeCompare(left.updatedAt)
      || left.id.localeCompare(right.id));
  const navigatorPills = ordered.slice(0, 512).map(presentationPill);
  const pills = ordered
    // Automation and app-managed conversations stay in the navigator, while
    // direct conversations receive ambient menu-bar space and Ready attention.
    .filter(isAmbientSession)
    // Historical Claude failures stay searchable in the navigator, but only
    // a newly observed failure may occupy ambient menu-bar attention.
    .filter((session) => session.failureAlert !== false)
    .filter((session) => session.canOpenOwner
      || (session.section !== "history" && session.canEnterChat))
    .slice(0, 64)
    .map(presentationPill);

  return { pills, navigatorPills, usageGlances };
}

/**
 * A completed Claude turn is still openable after it goes quiet, but it is no
 * longer a fresh Ready shortcut. Keep the source snapshot's phase, subtitle,
 * turn, and route evidence unchanged; this projection only moves dormant rows
 * behind recent work on the native menu surfaces. The helper uses the tier for
 * Recent grouping without changing the resolved lifecycle status.
 */
function menuSession(
  session: SessionSnapshot["sessions"][number],
  now: number,
): SessionSnapshot["sessions"][number] {
  if (session.completionUnseen || session.source !== "Claude Code" || session.section !== "ready"
    || (session.attentionTier !== undefined
      && session.attentionTier !== "ready"
      && session.attentionTier !== "acknowledged_ready")) return session;
  const updatedAt = Date.parse(session.updatedAt);
  if (!Number.isFinite(updatedAt) || now - updatedAt <= TRANSCRIPT_STALE_CEILING_MS) return session;
  return {
    ...session,
    attentionTier: "history",
  };
}

function isAmbientSession(session: SessionSnapshot["sessions"][number]): boolean {
  return session.sessionClass !== "automation" && !session.managedBy
    && session.ambientEligible !== false;
}

function presentationPill(
  session: SessionSnapshot["sessions"][number],
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
  return {
    id: session.id,
    title,
    subtitle: session.subtitle,
    source: sourceLabel,
    project: session.project,
    ...(session.canOpenOwner ? { owner: session.owner } : {}),
    ...(session.attentionTier ? { attentionTier: session.attentionTier } : {}),
    ...(session.completionUnseen ? { completionUnseen: true } : {}),
    ...(session.failureAlert !== undefined ? { failureAlert: session.failureAlert } : {}),
    lifecycleStatus: lifecycle.status,
    inspector: {
      status: lifecycle.label,
      runtimeItems: [runtimeSource(session.source, session.owner)],
      detailRows: session.sourceProfile ? [{ label: "Profile", value: session.sourceProfile }] : [],
      projectPath: displayPath(session.cwd),
      activityAt: session.updatedAt,
    },
    phase: session.section,
    priority,
    defaultOverflowEligible: isAmbientSession(session),
    accessibilityLabel: [
      title,
      lifecycle.label,
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
