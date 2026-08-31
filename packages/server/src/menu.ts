import os from "node:os";
import type { NativeHelperUsageGlance, SessionSnapshot } from "@agent-visor/protocol";
import type { NativeHelperEvent } from "./native-helper.js";

const phaseOrder = { needs_you: 0, ready: 1, working: 2, history: 3 } as const;
const attentionOrder = {
  needs_you: 0,
  ready: 1,
  working: 2,
  acknowledged_ready: 3,
  history: 4,
} as const;

const phaseLabel = {
  needs_you: "needs you",
  ready: "ready to continue",
  working: "in progress",
  history: "recent session",
} as const;

export function nativeActionFor(event: NativeHelperEvent, snapshot: SessionSnapshot) {
  if (event.event === "notification_permission") return undefined;
  if (event.event === "notification_action") {
    if (event.action !== "activate") return undefined;
    const session = snapshot.sessions.find((candidate) => candidate.id === event.sessionId);
    return session?.canEnterChat
      ? { type: "native_action", action: "open_chat", sessionId: session.id } as const
      : undefined;
  }
  if (!("sessionId" in event)) {
    return { type: "native_action", action: event.event } as const;
  }
  const session = snapshot.sessions.find((candidate) => candidate.id === event.sessionId);
  if (!session) return undefined;
  return event.intent === "chat" && session.canEnterChat
    ? { type: "native_action", action: "open_chat", sessionId: session.id } as const
    : undefined;
}

export function menuPresentation(
  snapshot: SessionSnapshot,
  usageGlances: NativeHelperUsageGlance[],
) {
  const ordered = snapshot.sessions
    .filter((session) => session.canOpenOwner || session.canEnterChat)
    .sort((left, right) => attentionOrder[left.attentionTier ?? left.section]
      - attentionOrder[right.attentionTier ?? right.section]
      || right.updatedAt.localeCompare(left.updatedAt)
      || left.id.localeCompare(right.id));
  const navigatorPills = ordered.slice(0, 512).map(presentationPill);
  const pills = ordered
    // Headless Codex exec records are useful in the navigator, but they are
    // machine-owned work and must not compete with user-facing sessions for
    // ambient menu-bar space or Ready attention.
    .filter((session) => session.sessionClass !== "automation")
    .filter((session) => session.source !== "Codex" || session.section !== "history")
    .filter((session) => session.canOpenOwner
      || (session.section !== "history" && session.canEnterChat))
    .slice(0, 64)
    .map(presentationPill);

  return { pills, navigatorPills, usageGlances };
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
  return {
    id: session.id,
    title,
    subtitle: session.subtitle,
    source: session.source,
    project: session.project,
    ...(session.canOpenOwner ? { owner: session.owner } : {}),
    ...(session.attentionTier ? { attentionTier: session.attentionTier } : {}),
    inspector: {
      status: inspectorStatus(session.section, session.subtitle),
      runtimeItems: [runtimeSource(session.source, session.owner)],
      detailRows: [],
      projectPath: displayPath(session.cwd),
      activityAt: session.updatedAt,
    },
    phase: session.section,
    priority,
    accessibilityLabel: [
      title,
      phaseLabel[session.section],
      session.source,
      session.project,
    ].join(", "),
  };
}

function inspectorStatus(section: keyof typeof phaseOrder, subtitle: string): string {
  switch (section) {
    case "needs_you": return "Needs attention";
    case "ready": return "Ready";
    case "working": return "Working";
    case "history": return subtitle.toLowerCase().includes("ended") ? "Ended" : "Recent";
  }
}

function runtimeSource(source: string, owner: string): string {
  if (source === "Codex" && owner === "Codex") return "Codex Desktop";
  return source.localeCompare(owner, undefined, { sensitivity: "accent" }) === 0
    ? source
    : `${source} · ${owner}`;
}

function displayPath(cwd: string): string {
  const home = os.homedir();
  if (cwd === home) return "~";
  return cwd.startsWith(`${home}/`) ? `~${cwd.slice(home.length)}` : cwd;
}
