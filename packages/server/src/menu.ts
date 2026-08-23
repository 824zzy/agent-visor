import type { NativeHelperUsageGlance, SessionSnapshot } from "@agent-visor/protocol";
import type { NativeHelperEvent } from "./native-helper.js";

const phaseOrder = { needs_you: 0, ready: 1, working: 2 } as const;
type ActiveSection = keyof typeof phaseOrder;
type ActiveSession = SessionSnapshot["sessions"][number] & { section: ActiveSection };

const phaseLabel = {
  needs_you: "needs you",
  ready: "ready to continue",
  working: "in progress",
} as const;

export function nativeActionFor(event: NativeHelperEvent, snapshot: SessionSnapshot) {
  if (event.event === "open_sessions") {
    return { type: "native_action", action: "open_sessions" } as const;
  }
  const session = snapshot.sessions.find((candidate) => candidate.id === event.sessionId);
  if (!session?.canOpenOwner) return undefined;
  return {
    type: "native_action",
    action: "open_owner",
    owner: session.owner,
    sessionId: session.id,
  } as const;
}

export function menuPresentation(
  snapshot: SessionSnapshot,
  usageGlances: NativeHelperUsageGlance[],
) {
  const pills = snapshot.sessions
    .filter((session): session is ActiveSession => session.section !== "history")
    .sort((left, right) => phaseOrder[left.section] - phaseOrder[right.section]
      || right.updatedAt.localeCompare(left.updatedAt)
      || left.id.localeCompare(right.id))
    .slice(0, 64)
    .map((session, priority) => ({
      id: session.id,
      title: session.title,
      subtitle: session.subtitle,
      source: session.source,
      project: session.project,
      owner: session.owner,
      phase: session.section,
      priority,
      accessibilityLabel: [
        session.title,
        phaseLabel[session.section],
        session.source,
        session.project,
      ].join(", "),
    }));

  return { pills, usageGlances };
}
