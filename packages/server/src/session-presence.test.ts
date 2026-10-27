import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  sessionPresencePresentation,
  type SessionSnapshot,
} from "@agent-visor/protocol";
import { menuPresentation } from "./menu.js";
import { SessionRepository, type DiscoveredProviderSession } from "./sessions.js";
import { selectSessions } from "../../app/src/session-groups.js";

const discovered = (
  id: string,
  presence: NonNullable<DiscoveredProviderSession["presence"]>,
  turn: "ready" | "working",
): DiscoveredProviderSession => ({
  id,
  provider: "claude_code",
  title: id,
  subtitle: turn === "ready" ? "Ready to continue" : "Claude Code is working",
  cwd: "/tmp/agent-visor",
  owner: "Ghostty",
  section: turn,
  updatedAt: "2026-10-26T10:00:00.000Z",
  canOpenOwner: true,
  canEnterChat: true,
  sessionClass: "terminal",
  ambientEligible: true,
  presence,
  conversationState: "open",
  turnState: turn,
  controlTarget: {
    kind: "terminal",
    target: {
      pid: 123,
      application: "Ghostty",
      cwd: "/tmp/agent-visor",
      tty: "/dev/ttys001",
    },
  },
});

describe("SessionRepository presence contract", () => {
  it("feeds one exact identity through open, unavailable, and closed search placement", async () => {
    let phase: "open" | "unknown" | "closed" = "open";
    const provider = {
      id: "claude_code" as const,
      discover: async () => [
        {
          ...discovered("stable-fixture", {
            state: phase,
            evidence: phase === "open" ? "frontend"
              : phase === "closed" ? "authoritative_inventory" : "unavailable",
            observedAt: "2026-10-26T10:00:00.000Z",
          }, "ready"),
          title: "Stable fixture conversation",
          sourceProfile: "fixture-profile",
          subtitle: "Stable fixture result",
          conversationState: phase === "closed" ? "archived" : phase === "unknown" ? "unknown" : "open",
          canOpenOwner: phase !== "closed",
          canEnterChat: true,
        },
        {
          ...discovered("unknown-fixture", {
            state: "unknown",
            evidence: "unavailable",
            observedAt: "2026-10-26T10:00:00.000Z",
          }, "ready"),
          title: "Unknown fixture conversation",
          subtitle: "Unavailable fixture result",
        },
        {
          ...discovered("closed-fixture", {
            state: "closed",
            evidence: "authoritative_inventory",
            observedAt: "2026-10-26T10:00:00.000Z",
          }, "ready"),
          title: "Closed fixture conversation",
          subtitle: "Closed fixture result",
          conversationState: "archived",
          canOpenOwner: false,
        },
      ] as DiscoveredProviderSession[],
    };
    const repository = new SessionRepository([provider]);

    const open = await repository.refresh();
    expect(selectSessions(open.sessions, "fixture").orderedSessions.map(({ id }) => id).sort())
      .toEqual(["closed-fixture", "stable-fixture", "unknown-fixture"]);
    expect(selectSessions(open.sessions, "").groups.map(({ id }) => id))
      .toEqual(["ready", "unavailable", "history"]);

    phase = "unknown";
    const unknown = await repository.refresh();
    expect(selectSessions(unknown.sessions, "stable fixture").orderedSessions.map(({ id }) => id))
      .toEqual(["stable-fixture"]);
    expect(selectSessions(unknown.sessions, "").groups.flatMap(({ sessions }) => sessions)
      .filter(({ id }) => id === "stable-fixture").map(({ presence }) => presence?.state))
      .toEqual(["unknown"]);

    phase = "closed";
    const closed = await repository.refresh();
    expect(selectSessions(closed.sessions, "stable fixture").orderedSessions.map(({ id }) => id))
      .toEqual(["stable-fixture"]);
    expect(selectSessions(closed.sessions, "").groups.flatMap(({ sessions }) => sessions)
      .filter(({ id }) => id === "stable-fixture").map(({ presence }) => presence?.state))
      .toEqual(["closed"]);
  });

  it("keeps a successful catalog observation in Saved through the real repository and menu", async () => {
    const catalog = discovered("catalog-only", {
      state: "unknown",
      evidence: "catalog",
      observedAt: "2026-10-26T10:00:00.000Z",
    }, "ready");
    catalog.subtitle = "Catalog transcript preview";
    catalog.canOpenOwner = false;
    catalog.canEnterChat = true;
    catalog.ambientEligible = false;
    catalog.conversationState = "unknown";
    const repository = new SessionRepository([{
      id: "claude_code" as const,
      discover: async () => [catalog],
    }]);

    const snapshot = await repository.refresh();
    expect(selectSessions(snapshot.sessions, "").groups).toEqual([expect.objectContaining({
      id: "history",
      title: "Saved",
      sessions: [expect.objectContaining({ id: "catalog-only" })],
    })]);
    expect(sessionPresencePresentation(snapshot.sessions[0]!)).toEqual({
      group: "history",
      status: "saved",
      label: "Saved",
      tone: "neutral",
    });
    expect(menuPresentation(snapshot, []).navigatorPills[0]).toMatchObject({
      id: "catalog-only",
      lifecycleStatus: "saved",
      inspector: { status: "Saved", detailRows: [] },
    });
  });

  it("keeps a live-to-Saved downgrade out of ambient pills while preserving failure recovery", async () => {
    let phase: "live" | "saved" | "unavailable" = "live";
    const observedAt = "2026-10-26T10:00:00.000Z";
    const provider = {
      id: "claude_code" as const,
      discover: async () => {
        const live = phase === "live";
        const unavailable = phase === "unavailable";
        return [{
          ...discovered("downgrade-fixture", {
            state: live ? "open" : "unknown",
            evidence: live ? "frontend" : unavailable ? "unavailable" : "catalog",
            observedAt,
          }, "ready"),
          section: live ? "ready" as const : "history" as const,
          subtitle: live ? "Ready to continue" : "Saved transcript preview",
          canOpenOwner: live,
          ambientEligible: live,
          conversationState: live ? "open" as const : "unknown" as const,
          turnState: live ? "ready" as const : "unknown" as const,
          completionUnseen: true,
        } satisfies DiscoveredProviderSession];
      },
      discoveryAuthority: () => "authoritative" as const,
    };
    const repository = new SessionRepository([provider]);
    const atObserved = new Date(observedAt).valueOf();

    const live = await repository.refresh();
    expect(menuPresentation(live, [], atObserved).pills.map(({ id }) => id))
      .toContain("downgrade-fixture");

    phase = "saved";
    const saved = await repository.refresh();
    expect(saved.sessions[0]).toMatchObject({
      presence: { state: "unknown", evidence: "catalog" },
      ambientEligible: false,
      completionUnseen: true,
    });
    expect(selectSessions(saved.sessions, "").groups).toEqual([expect.objectContaining({
      id: "history",
      sessions: [expect.objectContaining({ id: "downgrade-fixture" })],
    })]);
    expect(menuPresentation(saved, [], atObserved).pills.map(({ id }) => id))
      .not.toContain("downgrade-fixture");

    phase = "unavailable";
    const unavailable = await repository.refresh();
    expect(unavailable.sessions[0]).toMatchObject({
      presence: { state: "unknown", evidence: "unavailable" },
      ambientEligible: true,
      completionUnseen: true,
    });
    expect(menuPresentation(unavailable, [], atObserved).pills.map(({ id }) => id))
      .toContain("downgrade-fixture");

    phase = "live";
    const recovered = await repository.refresh();
    expect(recovered.sessions[0]).toMatchObject({
      presence: { state: "open", evidence: "frontend" },
      ambientEligible: true,
      completionUnseen: true,
    });
    expect(menuPresentation(recovered, [], atObserved).pills.map(({ id }) => id))
      .toContain("downgrade-fixture");
  });

  it("reopens isolated retained state without reviving live proof or completion attention", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-visor-saved-reopen-"));
    const historyPath = path.join(root, "retained-history.json");
    const observedAt = "2026-10-26T10:00:00.000Z";
    const sessionID = "codex-reopen-fixture";
    const canonicalID = "codex-canonical-fixture";
    const live: DiscoveredProviderSession = {
      id: sessionID,
      provider: "codex",
      title: "Reopened Codex fixture",
      subtitle: "Ready to continue",
      sourceProfile: "fixture-profile",
      project: "fixture-project",
      cwd: "/tmp/agent-visor/fixture-project",
      owner: "Ghostty",
      section: "ready",
      updatedAt: observedAt,
      canOpenOwner: true,
      canEnterChat: true,
      ambientEligible: true,
      presence: { state: "open", evidence: "frontend", observedAt },
      conversationState: "open",
      turnState: "ready",
      completionAt: observedAt,
      completionUnseen: false,
      historyIdentity: {
        verified: true,
        current: true,
        canonicalId: canonicalID,
        aliases: ["codex-public-alias"],
        host: "Ghostty",
        configHome: "/tmp/agent-visor/codex-config",
      },
    };
    const first = new SessionRepository([{
      id: "codex",
      discover: async () => [structuredClone(live)],
    }], { retainedHistoryPath: historyPath, now: () => new Date(observedAt) });
    try {
      await first.refresh();
      let mode: "unavailable" | "saved" = "unavailable";
      const savedCatalogRow: DiscoveredProviderSession = {
        ...structuredClone(live),
        id: "codex-public-alias",
        subtitle: "Saved transcript preview",
        section: "history",
        canOpenOwner: false,
        ambientEligible: false,
        presence: { state: "unknown", evidence: "catalog", observedAt },
        conversationState: "unknown",
        turnState: "ready",
        lifecycleStatus: "saved",
        historyIdentity: {
          ...live.historyIdentity!,
          current: false,
        },
      };
      const reopened = new SessionRepository([{
        id: "codex",
        discover: async () => mode === "unavailable" ? [] : [structuredClone(savedCatalogRow)],
        discoveryAuthority: () => mode === "unavailable" ? "unavailable" as const : "authoritative" as const,
      }], { retainedHistoryPath: historyPath, now: () => new Date(observedAt) });
      const snapshot = await reopened.refresh();
      const row = snapshot.sessions.find(({ id }) => id === sessionID);
      expect(row).toMatchObject({
        id: sessionID,
        sourceProfile: "fixture-profile",
        section: "ready",
        lifecycleStatus: "unavailable",
        ambientEligible: true,
        canOpenOwner: false,
        presence: { state: "unknown", evidence: "unavailable" },
        sessionState: { conversation: "unknown", turn: "unknown", route: "unavailable" },
      });
      expect(row?.attentionTier).toBe("ready");
      expect(row?.completionUnseen).not.toBe(true);
      expect(reopened.historyPage().sessions[0]).toMatchObject({
        sourceProfile: "fixture-profile",
        presence: { state: "unknown", evidence: "unavailable" },
      });
      const reopenedPill = menuPresentation(snapshot, [], new Date(observedAt).valueOf()).pills
        .find(({ id }) => id === sessionID);
      expect(reopenedPill).toMatchObject({ id: sessionID, lifecycleStatus: "unavailable" });
      expect(reopenedPill?.completionUnseen).not.toBe(true);

      mode = "saved";
      const healthy = await reopened.refresh();
      const savedRow = healthy.sessions.find(({ id }) => id === "codex-public-alias");
      expect(healthy.sessions.filter(({ source }) => source === "Codex")).toHaveLength(1);
      expect(savedRow).toMatchObject({
        id: "codex-public-alias",
        sourceProfile: "fixture-profile",
        section: "history",
        lifecycleStatus: "saved",
        presence: { state: "unknown", evidence: "catalog" },
        ambientEligible: false,
      });
      expect(savedRow?.completionUnseen).not.toBe(true);
      expect(menuPresentation(healthy, [], new Date(observedAt).valueOf()).pills)
        .not.toEqual(expect.arrayContaining([expect.objectContaining({ id: "codex-public-alias" })]));
      expect(reopened.historyPage().sessions[0]).toMatchObject({
        sourceProfile: "fixture-profile",
        title: "Reopened Codex fixture",
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("carries explicit Claude presence through the snapshot and native pill projection", async () => {
    const rows = [
      discovered("open", {
        state: "open",
        evidence: "frontend",
        observedAt: "2026-08-22T21:00:00.000Z",
      }, "ready"),
      {
        ...discovered("closed", {
          state: "closed",
          evidence: "authoritative_inventory",
          observedAt: "2026-08-22T21:00:00.000Z",
        }, "working"),
        lifecycleStatus: "working" as const,
      },
      {
        ...discovered("unknown", {
          state: "unknown",
          evidence: "unavailable",
          observedAt: "2026-08-22T21:00:00.000Z",
        }, "ready"),
        ambientEligible: false,
      },
    ];
    const provider = {
      id: "claude_code" as const,
      discover: async () => structuredClone(rows),
    };
    const repository = new SessionRepository([provider]);

    const snapshot = await repository.refresh();
    const byID = new Map(snapshot.sessions.map((session) => [session.id, session]));
    expect(byID.get("open")?.presence).toEqual(rows[0]!.presence);
    expect(byID.get("closed")?.presence).toEqual(rows[1]!.presence);
    expect(byID.get("closed")).toMatchObject({ lifecycleStatus: "closed" });
    expect(byID.get("unknown")?.presence).toEqual(rows[2]!.presence);
    expect(sessionPresencePresentation(byID.get("open")!)).toMatchObject({
      group: "current", subgroup: "ready", status: "ready",
    });
    expect(sessionPresencePresentation(byID.get("closed")!)).toMatchObject({
      group: "history", status: "closed", tone: "neutral",
    });

    const menu = menuPresentation(snapshot, []);
    expect(menu.pills.map(({ id }) => id)).toContain("open");
    expect(menu.pills.map(({ id }) => id)).not.toContain("closed");
    expect(menu.navigatorPills.find(({ id }) => id === "unknown")).toMatchObject({
      lifecycleStatus: "unavailable",
      inspector: { status: "Status unavailable" },
    });
  });

  it("keeps provider rows without presence readable through the legacy projection", async () => {
    const legacy: DiscoveredProviderSession = {
      id: "legacy",
      provider: "pi",
      title: "Legacy Pi",
      subtitle: "Ready to continue",
      cwd: "/tmp/agent-visor",
      owner: "Ghostty",
      section: "ready",
      updatedAt: "2026-10-26T10:00:00.000Z",
      canOpenOwner: true,
      canEnterChat: true,
    };
    const repository = new SessionRepository([{
      id: "pi" as const,
      discover: async () => [legacy],
    }]);

    const snapshot: SessionSnapshot = await repository.refresh();
    expect(snapshot.sessions[0]).not.toHaveProperty("presence");
    expect(snapshot.sessions[0]).toMatchObject({ section: "ready", lifecycleStatus: "ready" });
  });

  it("downgrades retained presence after a failed or non-authoritative read", async () => {
    let phase: "healthy" | "throw" | "unavailable" = "healthy";
    const row = discovered("transient", {
      state: "open",
      evidence: "frontend",
      observedAt: "2026-10-26T10:00:00.000Z",
    }, "ready");
    row.subtitle = "Unopened result";
    const provider = {
      id: "claude_code" as const,
      discover: async () => {
        if (phase === "throw") throw new Error("fixture provider unavailable");
        return [structuredClone(row)];
      },
      discoveryAuthority: () => phase === "unavailable" ? "unavailable" as const : "authoritative" as const,
    };
    const repository = new SessionRepository([provider]);

    const healthy = await repository.refresh();
    expect(healthy.sessions[0]).toMatchObject({
      id: "transient",
      subtitle: "Unopened result",
      presence: { state: "open", evidence: "frontend" },
      sessionState: { conversation: "open", turn: "ready" },
    });

    phase = "throw";
    const failed = await repository.refresh();
    expect(failed.sessions[0]).toMatchObject({
      id: "transient",
      subtitle: "Unopened result",
      presence: { state: "unknown", evidence: "unavailable" },
      sessionState: { conversation: "open", turn: "ready" },
    });
    expect(menuPresentation(failed, []).navigatorPills[0]).toMatchObject({
      lifecycleStatus: "unavailable",
      inspector: { status: "Status unavailable" },
    });

    phase = "unavailable";
    const unavailable = await repository.refresh();
    expect(unavailable.sessions[0]).toMatchObject({
      id: "transient",
      presence: { state: "unknown", evidence: "unavailable" },
      sessionState: { conversation: "open", turn: "ready" },
    });

    phase = "healthy";
    const recovered = await repository.refresh();
    expect(recovered.sessions[0]).toMatchObject({
      id: "transient",
      presence: { state: "open", evidence: "frontend" },
      sessionState: { conversation: "open", turn: "ready" },
    });
  });

  it.each(["overview", "not_displayed"] as const)(
    "does not restore a prior ambient pill for an authoritative Claude %s exclusion",
    async (claudePresence) => {
      let phase: "conversation" | "excluded" = "conversation";
      const row = discovered("claude-excluded", {
        state: "open",
        evidence: "frontend",
        observedAt: "2026-10-26T10:00:00.000Z",
      }, "ready");
      const provider = {
        id: "claude_code" as const,
        discover: async () => [{
          ...structuredClone(row),
          claudePresence: phase === "conversation" ? "conversation" : claudePresence,
          ambientEligible: phase === "conversation",
          presence: {
            state: phase === "conversation" ? "open" : "unknown",
            evidence: phase === "conversation" ? "frontend" : "unavailable",
            observedAt: "2026-10-26T10:00:00.000Z",
          },
        }] as DiscoveredProviderSession[],
        discoveryAuthority: () => "authoritative" as const,
      };
      const repository = new SessionRepository([provider]);

      const open = await repository.refresh();
      expect(open.sessions[0]).toMatchObject({
        id: "claude-excluded",
        claudePresence: "conversation",
        ambientEligible: true,
        presence: { state: "open" },
      });
      expect(menuPresentation(open, []).pills.some(({ id }) => id === "claude-excluded")).toBe(true);

      phase = "excluded";
      const excluded = await repository.refresh();
      expect(excluded.sessions[0]).toMatchObject({
        id: "claude-excluded",
        claudePresence,
        ambientEligible: false,
        presence: { state: "unknown", evidence: "unavailable" },
      });
      expect(menuPresentation(excluded, []).pills.some(({ id }) => id === "claude-excluded")).toBe(false);
    },
  );

  it("only retries detection explicitly and publishes the recovered exact identity", async () => {
    let phase: "unknown" | "open" = "unknown";
    let discoveryCalls = 0;
    const row = discovered("retryable", {
      state: phase,
      evidence: phase === "open" ? "frontend" : "unavailable",
      observedAt: "2026-10-26T10:00:00.000Z",
    }, "ready");
    const provider = {
      id: "claude_code" as const,
      discover: async () => {
        discoveryCalls += 1;
        return [{ ...structuredClone(row), presence: {
          state: phase,
          evidence: phase === "open" ? "frontend" : "unavailable",
          observedAt: "2026-10-26T10:00:00.000Z",
        } } as DiscoveredProviderSession];
      },
      discoveryAuthority: () => "authoritative" as const,
    };
    const repository = new SessionRepository([provider]);

    await repository.refresh();
    expect(repository.current().sessions[0]).toMatchObject({
      id: "retryable",
      presence: { state: "unknown", evidence: "unavailable" },
    });
    expect(discoveryCalls).toBe(1);

    phase = "open";
    await expect(repository.retryDetection("retryable")).resolves.toBeUndefined();
    expect(discoveryCalls).toBe(2);
    expect(repository.current().sessions[0]).toMatchObject({
      id: "retryable",
      presence: { state: "open", evidence: "frontend" },
    });
  });

  it("allows Retry detection for a legacy row projected unavailable in a mixed snapshot", async () => {
    let recovered = false;
    let discoveryCalls = 0;
    const provider = {
      id: "claude_code" as const,
      discover: async () => {
        discoveryCalls += 1;
        return [
          discovered("explicit-open", {
            state: "open",
            evidence: "frontend",
            observedAt: "2026-10-26T10:00:00.000Z",
          }, "ready"),
          {
            ...discovered("legacy-retry", {
              state: "open",
              evidence: "frontend",
              observedAt: "2026-10-26T10:00:00.000Z",
            }, "ready"),
            ...(recovered ? {} : { presence: undefined }),
          },
        ] as DiscoveredProviderSession[];
      },
      discoveryAuthority: () => "authoritative" as const,
    };
    const repository = new SessionRepository([provider]);

    await repository.refresh();
    const visible = selectSessions(repository.current().sessions, "").orderedSessions;
    expect(visible.find(({ id }) => id === "legacy-retry")?.presence).toMatchObject({
      state: "unknown",
      evidence: "unavailable",
    });

    recovered = true;
    await expect(repository.retryDetection("legacy-retry")).resolves.toBeUndefined();
    expect(discoveryCalls).toBe(2);
    expect(repository.current().sessions.find(({ id }) => id === "legacy-retry")?.presence)
      .toMatchObject({ state: "open", evidence: "frontend" });
  });
});
