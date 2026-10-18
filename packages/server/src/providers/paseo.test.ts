import { describe, expect, it } from "vitest";
import { PaseoProvider } from "./paseo.js";
import { SessionRepository } from "../sessions.js";
import { menuPresentation } from "../menu.js";
import { FakeNativeHelper } from "../native-helper.js";
import { NativeSessionControls } from "../session-controls.js";

const now = new Date("2026-10-12T21:00:00.000Z");
const agentId = "28a801ab-3b50-46ca-829c-783c202b79c4";
const sessionId = "532d44b3-a557-41c3-9117-023fc09e5e16";
const agent = () => ({
  id: agentId, provider: "claude-copilot", title: "Copilot work",
  cwd: "/Users/me/Codes", status: "running", updatedAt: now.toISOString(),
  pendingPermissions: [], requiresAttention: false, archivedAt: null,
  runtimeInfo: { sessionId },
});

describe("Paseo session pills", () => {
  it("keeps physical pills identical when only the confirmed source profile changes", async () => {
    const row = { ...agent(), provider: "claude" };
    const repository = new SessionRepository([new PaseoProvider({ read: async () => ({
      serverId: "srv_local", providers: { "claude-copilot": "claude" }, agents: [row],
    }) })], { now: () => now });
    const before = await repository.refresh();
    const previous = menuPresentation(before, [], now.valueOf());
    expect(previous.pills[0]?.inspector).toMatchObject({
      runtimeItems: ["Claude Code · Paseo"], detailRows: [],
    });

    row.provider = "claude-copilot";
    const after = await repository.refresh();
    const current = menuPresentation(after, [], now.valueOf());
    expect(current.pills[0]?.inspector?.detailRows).toEqual([
      { label: "Profile", value: "claude-copilot" },
    ]);
    expect(current.pills.map(({ inspector: _, ...pill }) => pill))
      .toEqual(previous.pills.map(({ inspector: _, ...pill }) => pill));
    expect(after.revision).toBeGreaterThan(before.revision);
  });

  it("publishes an SDK conversation from a profile that extends Claude with its exact Paseo route", async () => {
    const provider = new PaseoProvider({ read: async () => ({
      serverId: "srv_local", providers: { "claude-copilot": "claude" }, agents: [agent()],
    }) });
    const repository = new SessionRepository([provider], { now: () => now });
    const snapshot = await repository.refresh();
    expect(menuPresentation(snapshot, [], now.valueOf()).pills).toMatchObject([
      { title: "Copilot work", owner: "Paseo", phase: "working" },
    ]);
    expect(await provider.resolveForFocus(snapshot.sessions[0]!.id)).toMatchObject({
      canEnterChat: false,
      controlTarget: { kind: "url", url: "paseo://h/srv_local/agent/28a801ab-3b50-46ca-829c-783c202b79c4" },
    });
  });

  it("puts a running conversation awaiting a permission or question ahead of ordinary working pills", async () => {
    const row = { ...agent(), pendingPermissions: [{ toolName: "AskUserQuestion" }] };
    const provider = new PaseoProvider({ read: async () => ({
      serverId: "srv_local", providers: { "claude-copilot": "claude" }, agents: [row],
    }) });
    const snapshot = await new SessionRepository([provider], { now: () => now }).refresh();
    expect(menuPresentation(snapshot, [], now.valueOf()).pills).toMatchObject([
      { title: "Copilot work", phase: "needs_you", attentionTier: "needs_you" },
    ]);
  });

  it("keeps an idle startup quiet and pulses only a completion Paseo reports as unopened", async () => {
    const row = { ...agent(), status: "idle", requiresAttention: false,
      attentionReason: null as string | null, attentionTimestamp: null as string | null };
    const source = new SessionRepository([new PaseoProvider({ read: async () => ({
      serverId: "srv_local", providers: { "claude-copilot": "claude" }, agents: [row],
    }) })], { now: () => now });
    expect((await source.refresh()).sessions).toMatchObject([{ section: "history" }]);
    row.requiresAttention = true;
    row.attentionReason = "finished";
    row.attentionTimestamp = "2026-10-12T20:59:00.000Z";
    expect((await source.refresh()).sessions).toMatchObject([
      { section: "ready", completionUnseen: true, updatedAt: "2026-10-12T20:59:00.000Z" },
    ]);
    // The user read the result directly in Paseo; metadata updates must not pulse it again.
    row.requiresAttention = false;
    row.updatedAt = now.toISOString();
    const viewed = await source.refresh();
    expect(viewed.sessions[0]?.completionUnseen).not.toBe(true);
    expect(viewed.sessions[0]?.attentionTier).not.toBe("ready");
  });

  it("excludes archives, internal helpers, child agents and unrelated providers from ambient pills", async () => {
    const rows = [agent(),
      { ...agent(), id: "archived", archivedAt: now.toISOString() },
      { ...agent(), id: "internal", internal: true },
      { ...agent(), id: "child", parentAgentId: agentId },
      { ...agent(), id: "pi", provider: "pi" },
    ];
    const provider = new PaseoProvider({ read: async () => ({
      serverId: "srv_local", providers: { "claude-copilot": "claude" }, agents: rows,
    }) });
    const source = new SessionRepository([provider], { now: () => now });
    expect(menuPresentation(await source.refresh(), [], now.valueOf()).pills).toMatchObject([
      { id: "paseo:srv_local:28a801ab-3b50-46ca-829c-783c202b79c4" },
    ]);
  });

  it("opens the existing Paseo agent and refuses a stale click after archival", async () => {
    const row = { ...agent(), archivedAt: null as string | null };
    const opened: string[] = [];
    const helper = new FakeNativeHelper();
    const source = new SessionRepository([new PaseoProvider({ read: async () => ({
      serverId: "srv_local", providers: { "claude-copilot": "claude" }, agents: [row],
    }) })], { now: () => now });
    source.setControls(new NativeSessionControls(helper, undefined, undefined, async url => { opened.push(url); }));
    const id = (await source.refresh()).sessions[0]!.id;
    expect(await source.focusSession(id)).toBeUndefined();
    expect(opened).toEqual(["paseo://h/srv_local/agent/28a801ab-3b50-46ca-829c-783c202b79c4"]);
    row.archivedAt = now.toISOString();
    expect(await source.focusSession(id)).toBe("Exact session focus is unavailable.");
    expect(opened).toHaveLength(1);
  });

  it("clears unread attention when Paseo clears its attention fields without changing activity time", async () => {
    const row = { ...agent(), status: "idle", updatedAt: "2026-10-12T20:59:00.000Z",
      requiresAttention: true, attentionReason: "finished" as string | null,
      attentionTimestamp: "2026-10-12T20:59:00.000Z" as string | null };
    const source = new SessionRepository([new PaseoProvider({ read: async () => ({
      serverId: "srv_local", providers: { "claude-copilot": "claude" }, agents: [row],
    }) })], { now: () => now });
    expect((await source.refresh()).sessions[0]?.completionUnseen).toBe(true);
    row.requiresAttention = false; row.attentionReason = null; row.attentionTimestamp = null;
    expect((await source.refresh()).sessions[0]?.completionUnseen).not.toBe(true);
  });
});
