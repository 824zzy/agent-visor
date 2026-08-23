import {
  sessionSnapshotSchema,
  type SessionSection,
  type SessionSnapshot,
  type SessionSummary,
} from "@agent-visor/protocol";
import path from "node:path";

export type ProviderID = "claude_code" | "codex" | "pi" | "cursor" | "zed" | "auggie";

export type DiscoveredProviderSession = {
  id: string;
  provider: ProviderID;
  title?: string;
  subtitle?: string;
  project?: string;
  cwd: string;
  owner: string;
  section: SessionSection;
  updatedAt: string;
  canOpenOwner: boolean;
  canEnterChat: boolean;
  authority?: number;
};

export interface SessionSnapshotSource {
  current(): SessionSnapshot;
  subscribe(listener: (snapshot: SessionSnapshot) => void): () => void;
}

export interface ProviderAdapter {
  readonly id: ProviderID;
  discover(): Promise<DiscoveredProviderSession[]>;
}

export type HookSessionEvent = {
  sessionId: string;
  cwd: string;
  provider: Exclude<ProviderID, "zed">;
  event: string;
  status: string;
  receivedAt: string;
  pid?: number;
  tty?: string;
  expectsResponse?: boolean;
  isIdle?: boolean;
};

const providerNames: Record<ProviderID, string> = {
  claude_code: "Claude Code",
  codex: "Codex",
  pi: "Pi",
  cursor: "Cursor",
  zed: "Zed",
  auggie: "Auggie",
};

export class SessionRepository {
  private revision = 0;
  private fingerprint: string | undefined;
  private snapshotValue: SessionSnapshot = {
    type: "session_snapshot",
    revision: 0,
    sessions: [],
  };
  private readonly lastByProvider = new Map<ProviderID, DiscoveredProviderSession[]>();
  private readonly hookBySession = new Map<string, HookSessionEvent>();
  private readonly listeners = new Set<(snapshot: SessionSnapshot) => void>();

  constructor(private readonly providers: ProviderAdapter[]) {}

  current(): SessionSnapshot {
    return structuredClone(this.snapshotValue);
  }

  subscribe(listener: (snapshot: SessionSnapshot) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async refresh(): Promise<SessionSnapshot> {
    const discovered = await Promise.all(this.providers.map(async (provider) => {
      try {
        const sessions = await provider.discover();
        this.lastByProvider.set(provider.id, structuredClone(sessions));
        return sessions;
      } catch {
        return this.lastByProvider.get(provider.id) ?? [];
      }
    }));
    return this.publish(discovered.flat());
  }

  applyHook(event: HookSessionEvent): SessionSnapshot {
    const previous = this.hookBySession.get(event.sessionId);
    if (!previous || previous.receivedAt <= event.receivedAt) {
      this.hookBySession.set(event.sessionId, structuredClone(event));
    }
    return this.publish([...this.lastByProvider.values()].flat());
  }

  private publish(discovered: DiscoveredProviderSession[]): SessionSnapshot {
    const sessions = normalize(applyHooks(discovered, this.hookBySession));
    const fingerprint = JSON.stringify(sessions);
    if (fingerprint !== this.fingerprint) {
      this.fingerprint = fingerprint;
      this.revision += 1;
      this.snapshotValue = sessionSnapshotSchema.parse({
        type: "session_snapshot",
        revision: this.revision,
        sessions,
      });
      for (const listener of this.listeners) listener(this.current());
    }
    return this.current();
  }
}

function applyHooks(
  discovered: DiscoveredProviderSession[],
  hookBySession: Map<string, HookSessionEvent>,
): DiscoveredProviderSession[] {
  const sessions = discovered.map((session) => ({ ...session }));
  for (const hook of hookBySession.values()) {
    const phase = hookPhase(hook);
    const existing = sessions.find((session) => session.id === hook.sessionId);
    if (existing) {
      existing.section = phase.section;
      existing.subtitle = phase.subtitle;
      existing.updatedAt = hook.receivedAt;
      continue;
    }
    sessions.push({
      id: hook.sessionId,
      provider: hook.provider,
      cwd: hook.cwd,
      owner: hookOwner(hook),
      section: phase.section,
      subtitle: phase.subtitle,
      updatedAt: hook.receivedAt,
      canOpenOwner: Boolean(hook.pid || hook.tty),
      canEnterChat: hook.provider !== "auggie",
    });
  }
  return sessions;
}

function hookPhase(event: HookSessionEvent): { section: SessionSection; subtitle: string } {
  const status = event.status.trim().toLowerCase();
  if (event.expectsResponse || event.event === "PermissionRequest"
    || status.includes("approval") || status === "waiting_for_input") {
    return { section: "needs_you", subtitle: "Approval required" };
  }
  if (event.event === "SessionEnd"
    || ["ended", "exited", "closed", "inactive", "stopped", "terminated"].includes(status)) {
    return { section: "history", subtitle: "Session ended" };
  }
  if (event.event === "Stop" || event.isIdle === true || status === "idle") {
    return { section: "ready", subtitle: "Ready to continue" };
  }
  return { section: "working", subtitle: "Agent is working" };
}

function hookOwner(event: HookSessionEvent): string {
  if (event.tty) return "Terminal";
  if (event.provider === "cursor") return "Cursor";
  if (event.provider === "codex") return "Codex";
  if (event.provider === "claude_code") return "Claude";
  return providerNames[event.provider];
}

function normalize(discovered: DiscoveredProviderSession[]): SessionSummary[] {
  const byID = new Map<string, DiscoveredProviderSession>();
  for (const session of discovered) {
    const existing = byID.get(session.id);
    if (!existing || (session.authority ?? 1) > (existing.authority ?? 1)) {
      byID.set(session.id, session);
    }
  }

  return [...byID.values()]
    .map((session): SessionSummary => ({
      id: session.id,
      title: session.title?.trim() || `${providerNames[session.provider]} session`,
      subtitle: session.subtitle?.trim() ?? "",
      source: providerNames[session.provider],
      project: session.project?.trim() || path.basename(session.cwd) || session.cwd,
      owner: session.owner,
      cwd: session.cwd,
      section: session.section,
      updatedAt: session.updatedAt,
      canOpenOwner: session.canOpenOwner,
      canEnterChat: session.canEnterChat,
    }))
    .sort((left, right) =>
      right.updatedAt.localeCompare(left.updatedAt) || left.id.localeCompare(right.id));
}
