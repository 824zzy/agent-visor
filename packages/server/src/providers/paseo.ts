import type { DiscoveredProviderSession, ProviderAdapter } from "../sessions.js";

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
  constructor(private readonly source: PaseoSource) {}
  async discover(fresh = false): Promise<DiscoveredProviderSession[]> {
    const snapshot = await this.source.read(fresh);
    if (!snapshot) return [];
    return snapshot.agents.filter(agent => !agent.archivedAt && !agent.internal && !agent.parentAgentId)
      .filter(agent => agent.provider === "claude" || snapshot.providers[agent.provider] === "claude")
      .map<DiscoveredProviderSession>(agent => {
      const waiting = Boolean(agent.pendingPermissions?.length) || agent.attentionReason === "permission";
      const failed = agent.status === "error" && agent.requiresAttention === true;
      const working = agent.status === "running" || agent.status === "initializing";
      const completionAt = agent.status === "idle" && agent.attentionReason === "finished"
        && agent.attentionTimestamp && Number.isFinite(Date.parse(agent.attentionTimestamp))
        ? new Date(agent.attentionTimestamp).toISOString() : undefined;
      const section = waiting || failed ? "needs_you" : working ? "working"
        : completionAt ? "ready" : "history";
      const nativeId = agent.runtimeInfo?.sessionId ?? agent.persistence?.sessionId;
      return {
        id: `paseo:${snapshot.serverId}:${agent.id}`, provider: this.id,
        title: agent.title || "Claude Code session", cwd: agent.cwd, owner: "Paseo",
        subtitle: waiting ? "Answer or approval required in Paseo" : failed ? "Check the error in Paseo"
          : working ? "Claude Code is working" : "Ready to continue in Paseo",
        section, turnState: section === "history" ? agent.status === "idle" ? "ready" : "unknown" : section,
        conversationState: "open", updatedAt: completionAt ?? agent.updatedAt,
        ...(completionAt ? { completionAt } : {}),
        ...(agent.status === "idle" && agent.requiresAttention === false ? { completionAcknowledged: true } : {}),
        canOpenOwner: true, canEnterChat: false, sessionClass: "interactive",
        ...(nativeId && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(nativeId)
          ? { nativeSessionAlias: { provider: "claude_code" as const, id: nativeId } } : {}),
        controlTarget: { kind: "url", url: `paseo://h/${snapshot.serverId}/agent/${agent.id}` },
      };
      });
  }
  async resolveForFocus(id: string): Promise<DiscoveredProviderSession | undefined> {
    return (await this.discover(true)).find(session => session.id === id);
  }
}
