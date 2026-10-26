import type {
  DiscoveredProviderSession,
  ProviderAdapter,
  ProviderDiscoveryAuthority,
} from "../sessions.js";

export type PaseoAgent = {
  id: string; provider: string; cwd: string; status: string; updatedAt: string;
  title?: string | null; archivedAt?: string | null; internal?: boolean;
  parentAgentId?: string | null; pendingPermissions?: unknown[];
  requiresAttention?: boolean; attentionReason?: string | null; attentionTimestamp?: string | null;
  runtimeInfo?: { sessionId?: string | null };
  persistence?: { sessionId?: string };
};
export type PaseoSnapshot = {
  serverId: string; providers: Record<string, string>; agents: PaseoAgent[];
};
export interface PaseoSource { read(fresh?: boolean): Promise<PaseoSnapshot | undefined>; }

export class PaseoProvider implements ProviderAdapter {
  readonly id = "paseo" as const;
  private lastDiscoveryAuthority: ProviderDiscoveryAuthority = "authoritative";
  private lastGoodSessions: DiscoveredProviderSession[] = [];

  constructor(
    private readonly source: PaseoSource,
    private readonly now: () => Date = () => new Date(),
  ) {}

  discoveryAuthority(): ProviderDiscoveryAuthority {
    return this.lastDiscoveryAuthority;
  }

  async discover(fresh = false): Promise<DiscoveredProviderSession[]> {
    let snapshot: PaseoSnapshot | undefined;
    try {
      snapshot = await this.source.read(fresh);
    } catch {
      snapshot = undefined;
    }
    if (!snapshot) {
      this.lastDiscoveryAuthority = "unavailable";
      return this.lastGoodSessions.map(session => unavailablePresence(session, this.now().toISOString()));
    }

    this.lastDiscoveryAuthority = "authoritative";
    const sessions = snapshot.agents.filter(agent => !agent.internal && !agent.parentAgentId)
      .filter(agent => agent.provider === "claude" || snapshot.providers[agent.provider] === "claude")
      .map<DiscoveredProviderSession>(agent => {
        const archived = Boolean(agent.archivedAt);
        const waiting = Boolean(agent.pendingPermissions?.length) || agent.attentionReason === "permission";
        const failed = agent.status === "error" && agent.requiresAttention === true;
        const working = agent.status === "running" || agent.status === "initializing";
        const runtimeWaiting = agent.status === "waiting_for_approval"
          || agent.status === "waiting_for_input" || agent.status === "permission";
        // Attention metadata is independent from liveness. A saved row can
        // retain a pending question or failure after its runtime stopped;
        // only an explicit live status establishes runtime presence here.
        const runtimePresence = working || runtimeWaiting;
        const confirmedClosed = archived && !runtimePresence;
        const completionAt = agent.status === "idle" && agent.attentionReason === "finished"
          && agent.attentionTimestamp && Number.isFinite(Date.parse(agent.attentionTimestamp))
          ? new Date(agent.attentionTimestamp).toISOString() : undefined;
        const section = confirmedClosed ? "history" : waiting || failed ? "needs_you" : working ? "working"
          : completionAt ? "ready" : "history";
        const presenceState = runtimePresence ? "open" as const
          : confirmedClosed ? "closed" as const : "unknown" as const;
        const presenceEvidence = runtimePresence ? "runtime" as const
          : confirmedClosed ? "authoritative_inventory" as const : "catalog" as const;
        const nativeId = agent.runtimeInfo?.sessionId ?? agent.persistence?.sessionId;
        return {
          id: `paseo:${snapshot.serverId}:${agent.id}`, provider: this.id,
          title: agent.title || "Claude Code session", cwd: agent.cwd, owner: "Paseo",
          ...(snapshot.providers[agent.provider] === "claude" ? { sourceProfile: agent.provider } : {}),
          subtitle: waiting ? "Answer or approval required in Paseo" : failed ? "Check the error in Paseo"
            : working ? "Claude Code is working" : "Ready to continue in Paseo",
          section, turnState: section === "history" ? agent.status === "idle" ? "ready" : "unknown" : section,
          conversationState: runtimePresence ? "open" as const : confirmedClosed ? "archived" as const : "open" as const,
          updatedAt: completionAt ?? agent.updatedAt,
          ...(completionAt ? { completionAt } : {}),
          ...(agent.status === "idle" && agent.requiresAttention === false ? { completionAcknowledged: true } : {}),
          canOpenOwner: !confirmedClosed, canEnterChat: false, sessionClass: "interactive",
          ...(runtimePresence ? {} : { ambientEligible: false }),
          presence: {
            state: presenceState,
            evidence: presenceEvidence,
            observedAt: this.now().toISOString(),
          },
          ...(nativeId && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(nativeId)
            ? { nativeSessionAlias: { provider: "claude_code" as const, id: nativeId } } : {}),
          controlTarget: { kind: "url", url: `paseo://h/${snapshot.serverId}/agent/${agent.id}` },
        };
      });
    this.lastGoodSessions = structuredClone(sessions);
    return sessions;
  }
  async resolveForFocus(id: string): Promise<DiscoveredProviderSession | undefined> {
    const session = (await this.discover(true)).find(session => session.id === id);
    return session?.presence?.state === "closed" ? undefined : session;
  }
}

function unavailablePresence(
  session: DiscoveredProviderSession,
  observedAt: string,
): DiscoveredProviderSession {
  return {
    ...session,
    presence: {
      state: "unknown",
      evidence: "unavailable",
      observedAt,
    },
  };
}
