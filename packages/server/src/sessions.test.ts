import { describe, expect, it } from "vitest";
import {
  SessionRepository,
  type DiscoveredProviderSession,
  type ProviderAdapter,
} from "./sessions.js";

const live: DiscoveredProviderSession = {
  id: "pi-1",
  provider: "pi",
  title: "Migration",
  subtitle: "Active Pi session",
  cwd: "/Users/me/Codes/agent-visor",
  owner: "Ghostty",
  section: "working",
  updatedAt: "2026-08-22T08:00:00.000Z",
  canOpenOwner: true,
  canEnterChat: true,
  authority: 1,
};

class FakeProvider implements ProviderAdapter {
  readonly id = "pi";
  sessions = [live];

  async discover(): Promise<DiscoveredProviderSession[]> {
    return structuredClone(this.sessions);
  }
}

describe("SessionRepository", () => {
  it("keeps a stable revision while provider data is unchanged", async () => {
    const provider = new FakeProvider();
    const repository = new SessionRepository([provider]);

    const first = await repository.refresh();
    const second = await repository.refresh();

    expect(first.revision).toBe(1);
    expect(second).toEqual(first);
  });

  it("increments once when normalized session content changes", async () => {
    const provider = new FakeProvider();
    const repository = new SessionRepository([provider]);
    await repository.refresh();
    provider.sessions[0] = { ...live, section: "ready", subtitle: "Ready" };

    const changed = await repository.refresh();

    expect(changed.revision).toBe(2);
    expect(changed.sessions[0]?.section).toBe("ready");
  });

  it("preserves the last provider snapshot after a transient read failure", async () => {
    const provider = new FakeProvider();
    const repository = new SessionRepository([provider]);
    const first = await repository.refresh();
    provider.discover = async () => { throw new Error("mid-write read"); };

    expect(await repository.refresh()).toEqual(first);
  });

  it("applies hook phases without replacing provider-specific names", async () => {
    const provider = new FakeProvider();
    const repository = new SessionRepository([provider]);
    await repository.refresh();

    const changed = repository.applyHook({
      sessionId: "pi-1",
      cwd: live.cwd,
      provider: "pi",
      event: "PermissionRequest",
      status: "waiting_for_approval",
      receivedAt: "2026-08-22T08:01:00.000Z",
    });

    expect(changed.sessions[0]).toMatchObject({
      title: "Migration",
      section: "needs_you",
      subtitle: "Approval required",
    });
  });

  it("creates an Auggie row from its hook-only integration", () => {
    const repository = new SessionRepository([]);

    const snapshot = repository.applyHook({
      sessionId: "auggie-1",
      cwd: live.cwd,
      provider: "auggie",
      event: "SessionStart",
      status: "working",
      receivedAt: "2026-08-22T08:01:00.000Z",
    });

    expect(snapshot.sessions[0]).toMatchObject({
      id: "auggie-1",
      source: "Auggie",
      section: "working",
      canEnterChat: false,
    });
  });

  it("lets an authoritative host replace a duplicate provider row", async () => {
    const pi = new FakeProvider();
    const zed: ProviderAdapter = {
      id: "zed",
      async discover() {
        return [{
          ...live,
          title: "Zed-owned title",
          owner: "Zed",
          authority: 2,
        }];
      },
    };
    const repository = new SessionRepository([pi, zed]);

    const snapshot = await repository.refresh();

    expect(snapshot.sessions).toHaveLength(1);
    expect(snapshot.sessions[0]?.title).toBe("Zed-owned title");
    expect(snapshot.sessions[0]?.owner).toBe("Zed");
  });
});
