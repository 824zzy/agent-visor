import type { SessionSnapshot, SessionSummary } from "@agent-visor/protocol";

const base = {
  cwd: "/Users/me/Codes/agent-visor",
  project: "agent-visor",
  canOpenOwner: true,
} as const;

const sessions: SessionSummary[] = [
  {
    ...base,
    id: "codex-permission",
    title: "Review release permission",
    subtitle: "Approval required before publishing the release",
    source: "Codex",
    owner: "Codex",
    section: "needs_you",
    updatedAt: "2026-08-22T09:12:00.000Z",
    canEnterChat: true,
  },
  {
    ...base,
    id: "pi-ready",
    title: "React Native migration plan",
    subtitle: "The first stack slice is ready for review",
    source: "Pi",
    owner: "Ghostty",
    section: "ready",
    updatedAt: "2026-08-22T09:08:00.000Z",
    canEnterChat: true,
  },
  {
    ...base,
    id: "codex-working",
    title: "Port session discovery",
    subtitle: "Reading provider lifecycle evidence",
    source: "Codex",
    owner: "Codex",
    section: "working",
    updatedAt: "2026-08-22T09:10:00.000Z",
    canEnterChat: true,
  },
  {
    ...base,
    id: "pi-working",
    title: "Verify Electron shell",
    subtitle: "Building the local desktop application",
    source: "Pi",
    owner: "Ghostty",
    section: "working",
    updatedAt: "2026-08-22T09:06:00.000Z",
    canEnterChat: true,
  },
  {
    ...base,
    id: "codex-history",
    title: "Agent Visor 2.6.1",
    subtitle: "From Codex history",
    source: "Codex",
    owner: "Codex",
    section: "history",
    updatedAt: "2026-08-21T20:00:00.000Z",
    canEnterChat: false,
  },
];

export const fixtureSnapshot: SessionSnapshot = {
  type: "session_snapshot",
  revision: 1,
  sessions,
};
