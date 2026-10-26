import { describe, expect, it } from "vitest";
import { PaseoProvider, type PaseoAgent } from "./paseo.js";
import { ClaudeProvider } from "./claude.js";
import type { ProviderEnvironment, ProcessRecord } from "./environment.js";
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

class TerminalClaudeEnvironment implements ProviderEnvironment {
  readonly home = "/Users/me";
  readonly observedWindowMs = 42 * 60 * 60 * 1000;
  startedAt: Date | undefined = now;
  metadata = { pid: 42, sessionId, cwd: "/Users/me/Codes", kind: "interactive", status: "idle",
    name: "Terminal conversation", parkedJobId: undefined as string | undefined };
  processRows: ProcessRecord[] = [
    { pid: 42, parentPID: 10, tty: "ttys023", command: "/usr/local/bin/claude", arguments: "claude" },
    { pid: 10, parentPID: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
  ];
  now() { return now; }
  async processes() { return this.processRows; }
  async processStartedAt() { return this.startedAt; }
  async cwd() { return this.metadata.cwd; }
  async directory(value: string) { return value.endsWith("/.claude/sessions") ? ["42.json"] : []; }
  async isDirectory() { return true; }
  async stamp() { return { modifiedAt: now, size: 512 }; }
  async read(value: string) { return value.endsWith("/sessions/42.json") ? JSON.stringify(this.metadata) : undefined; }
  async readHeadTail() { return { head: "", tail: "" }; }
  async scanLinePrefixes() { return 0; }
  async sqlite() { return []; }
}

function mixedSources(reverse = false) {
  const environment = new TerminalClaudeEnvironment();
  const row: PaseoAgent = { ...agent(), status: "idle" };
  const providers = [new PaseoProvider({ read: async () => ({
    serverId: "srv_local", providers: { "claude-copilot": "claude" }, agents: [row],
  }) }), new ClaudeProvider(environment)];
  const repository = new SessionRepository(reverse ? providers.reverse() : providers, { now: () => now });
  return { environment, row, repository };
}

describe("Paseo session pills", () => {
  it.each([false, true])("keeps a verified live Ghostty conversation instead of its historical Paseo alias (reverse discovery: %s)", async (reverse) => {
    const { repository } = mixedSources(reverse);
    const snapshot = await repository.refresh();
    expect(snapshot.sessions).toMatchObject([{ id: sessionId, title: "Terminal conversation", owner: "Ghostty" }]);
    expect(menuPresentation(snapshot, [], now.valueOf()).pills).toMatchObject([
      { id: sessionId, title: "Terminal conversation", owner: "Ghostty" },
    ]);
  });

  it.each(["closed", "overview", "missing-process", "application-only", "unverified-process"])("keeps Paseo history when native ownership is not verified (%s)", async (reason) => {
    const { environment, repository } = mixedSources();
    if (reason === "closed") environment.metadata.status = "closed";
    if (reason === "overview") environment.metadata.parkedJobId = "old-job";
    if (reason === "missing-process") environment.processRows = [];
    if (reason === "application-only") Object.assign(environment.processRows[1]!, {
      command: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: "Claude",
    });
    if (reason === "unverified-process") environment.startedAt = undefined;
    expect((await repository.refresh()).sessions).toMatchObject([
      { id: `paseo:srv_local:${agentId}`, owner: "Paseo", section: "history" },
    ]);
  });

  it.each(["running", "initializing", "permission", "finished", "failure"])("preserves active Paseo ownership and its profile (%s)", async (state) => {
    const { environment, row, repository } = mixedSources();
    environment.metadata.status = "busy";
    row.status = state === "running" || state === "initializing" ? state : state === "failure" ? "error" : "idle";
    if (state === "permission") row.pendingPermissions = [{ toolName: "AskUserQuestion" }];
    if (state === "finished") {
      row.requiresAttention = true; row.attentionReason = "finished"; row.attentionTimestamp = now.toISOString();
    }
    if (state === "failure") row.requiresAttention = true;
    const snapshot = await repository.refresh();
    expect(snapshot.sessions).toMatchObject([
      { id: `paseo:srv_local:${agentId}`, owner: "Paseo", sourceProfile: "claude-copilot" },
    ]);
    const pills = menuPresentation(snapshot, [], now.valueOf()).pills;
    if (state === "finished" || state === "permission" || state === "failure") expect(pills).toEqual([]);
    else expect(pills).toMatchObject([
      { id: `paseo:srv_local:${agentId}`, phase: state === "permission" || state === "failure" ? "needs_you" : "working" },
    ]);
    const hooked = repository.applyHook({ sessionId, provider: "claude_code", cwd: environment.metadata.cwd,
      event: "Stop", status: "idle", receivedAt: now.toISOString(), tty: "ttys023" });
    expect(hooked.sessions.map(session => session.id)).toEqual([`paseo:srv_local:${agentId}`]);
  });

  it("reconciles ownership on refresh without reviving a parked overview from hooks", async () => {
    const { environment, row, repository } = mixedSources();
    row.status = "running";
    expect((await repository.refresh()).sessions.map(session => session.id)).toEqual([`paseo:srv_local:${agentId}`]);
    row.status = "idle";
    expect((await repository.refresh()).sessions.map(session => session.id)).toEqual([sessionId]);
    repository.applyHook({ sessionId, provider: "claude_code", cwd: environment.metadata.cwd,
      event: "Stop", status: "idle", receivedAt: now.toISOString(), tty: "ttys023" });
    environment.metadata.parkedJobId = "old-job";
    const overview = await repository.refresh();
    expect(overview.sessions.map(session => session.id)).toEqual([`paseo:srv_local:${agentId}`]);
    expect(menuPresentation(overview, [], now.valueOf()).pills.some(pill => pill.id === sessionId)).toBe(false);
    environment.metadata.parkedJobId = undefined;
    expect((await repository.refresh()).sessions.map(session => session.id)).toEqual([sessionId]);
    row.status = "running";
    expect((await repository.refresh()).sessions.map(session => session.id)).toEqual([`paseo:srv_local:${agentId}`]);
  });

  it.each(["different-id", "different-cwd", "uppercase-id"])("matches ownership by provider identity and cwd, not title (%s)", async (identity) => {
    const { environment, row, repository } = mixedSources();
    row.title = environment.metadata.name;
    if (identity === "different-id") row.runtimeInfo!.sessionId = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff";
    if (identity === "different-cwd") row.cwd = "/Users/me/Other";
    if (identity === "uppercase-id") row.runtimeInfo!.sessionId = sessionId.toUpperCase();
    const ids = (await repository.refresh()).sessions.map(session => session.id).sort();
    expect(ids).toEqual(identity === "uppercase-id" ? [sessionId] : [sessionId, `paseo:srv_local:${agentId}`].sort());
  });

  it.each(["idle", "waiting_for_approval"])("keeps a real unanswered Claude question yellow after selecting its live frontend (%s)", async (status) => {
    const { environment, repository } = mixedSources();
    environment.metadata.status = status;
    await repository.refresh();
    const snapshot = repository.applyHook({ sessionId, provider: "claude_code", cwd: environment.metadata.cwd,
      event: "PreToolUse", status: "waiting_for_approval", receivedAt: now.toISOString(), tty: "ttys023",
      tool: "AskUserQuestion", toolUseId: "question-1", expectsResponse: true,
      toolInput: { questions: [{ question: "Which strategy?", options: [{ label: "Minimal" }] }] },
    });
    expect(snapshot.sessions).toMatchObject([{ id: sessionId, owner: "Ghostty", section: "needs_you" }]);
    expect(menuPresentation(snapshot, [], now.valueOf()).pills).toMatchObject([
      { id: sessionId, phase: "needs_you", attentionTier: "needs_you" },
    ]);
  });

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

  it("keeps a fresh Paseo runtime Current while a saved idle record stays unavailable", async () => {
    const running = agent();
    const saved = { ...agent(), id: "saved-id", status: "idle", runtimeInfo: undefined,
      persistence: { sessionId } };
    const provider = new PaseoProvider({ read: async () => ({
      serverId: "srv_local", providers: { "claude-copilot": "claude" }, agents: [running, saved],
    }) });
    const snapshot = await new SessionRepository([provider], { now: () => now }).refresh();

    expect(snapshot.sessions).toEqual(expect.arrayContaining([
      expect.objectContaining({
        id: `paseo:srv_local:${agentId}`,
        section: "working",
        presence: expect.objectContaining({ state: "open", evidence: "runtime" }),
      }),
      expect.objectContaining({
        id: "paseo:srv_local:saved-id",
        section: "history",
        presence: expect.objectContaining({ state: "unknown", evidence: "catalog" }),
        ambientEligible: false,
      }),
    ]));
    expect(menuPresentation(snapshot, [], now.valueOf()).pills.map(({ id }) => id))
      .toEqual([`paseo:srv_local:${agentId}`]);
  });

  it("retains a saved result through an unavailable read and recovers without a new pulse", async () => {
    let phase: "healthy" | "failure" | "empty" = "healthy";
    const row = { ...agent(), status: "idle", runtimeInfo: undefined,
      persistence: { sessionId }, requiresAttention: true,
      attentionReason: "finished" as string | null, attentionTimestamp: now.toISOString() as string | null };
    const provider = new PaseoProvider({ read: async () => {
      if (phase === "failure") return undefined;
      return { serverId: "srv_local", providers: { "claude-copilot": "claude" },
        agents: phase === "empty" ? [] : [row] };
    } }, () => now);
    const repository = new SessionRepository([provider], { now: () => now });

    const healthy = await repository.refresh();
    expect(healthy.sessions).toMatchObject([{
      id: `paseo:srv_local:${agentId}`,
      sourceProfile: "claude-copilot",
      presence: { state: "unknown", evidence: "catalog" },
      completionUnseen: true,
    }]);
    expect(await provider.discover()).toMatchObject([{
      id: `paseo:srv_local:${agentId}`,
      nativeSessionAlias: { provider: "claude_code", id: sessionId },
      controlTarget: { kind: "url", url: "paseo://h/srv_local/agent/28a801ab-3b50-46ca-829c-783c202b79c4" },
    }]);

    phase = "failure";
    const failed = await repository.refresh();
    expect(failed.sessions).toMatchObject([{
      id: `paseo:srv_local:${agentId}`,
      sourceProfile: "claude-copilot",
      presence: { state: "unknown", evidence: "unavailable" },
      completionUnseen: true,
    }]);
    expect(menuPresentation(failed, [], now.valueOf()).pills).toEqual([]);
    expect(menuPresentation(failed, [], now.valueOf()).navigatorPills).toMatchObject([{
      id: `paseo:srv_local:${agentId}`,
      lifecycleStatus: "unavailable",
    }]);

    phase = "healthy";
    const recovered = await repository.refresh();
    expect(recovered.sessions).toMatchObject([{
      id: `paseo:srv_local:${agentId}`,
      sourceProfile: "claude-copilot",
      presence: { state: "unknown", evidence: "catalog" },
      completionUnseen: true,
    }]);

    phase = "empty";
    expect((await repository.refresh()).sessions).toEqual([]);
    expect(provider.discoveryAuthority()).toBe("authoritative");
  });

  it("keeps archived rows closed unless the same row has contradictory live runtime evidence", async () => {
    const archivedLive = { ...agent(), id: "archived-live", status: "running", archivedAt: now.toISOString() };
    const archivedClosed = { ...agent(), id: "archived-idle", status: "idle", runtimeInfo: undefined,
      persistence: { sessionId }, archivedAt: now.toISOString(), requiresAttention: false };
    const provider = new PaseoProvider({ read: async () => ({
      serverId: "srv_local", providers: { "claude-copilot": "claude" },
      agents: [archivedLive, archivedClosed],
    }) }, () => now);
    const repository = new SessionRepository([provider], { now: () => now });
    const snapshot = await repository.refresh();

    expect(snapshot.sessions).toEqual(expect.arrayContaining([
      expect.objectContaining({
        id: "paseo:srv_local:archived-live",
        section: "working",
        presence: expect.objectContaining({ state: "open", evidence: "runtime" }),
      }),
      expect.objectContaining({
        id: "paseo:srv_local:archived-idle",
        section: "history",
        lifecycleStatus: "closed",
        presence: expect.objectContaining({ state: "closed", evidence: "authoritative_inventory" }),
        ambientEligible: false,
      }),
    ]));
    expect(menuPresentation(snapshot, [], now.valueOf()).pills.map(({ id }) => id))
      .toEqual(["paseo:srv_local:archived-live"]);
    expect(await provider.resolveForFocus("paseo:srv_local:archived-idle")).toBeUndefined();
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
      { ...agent(), id: "archived", status: "idle", runtimeInfo: undefined,
        archivedAt: now.toISOString() },
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
    row.status = "idle";
    row.runtimeInfo = undefined;
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
