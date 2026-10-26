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
});
