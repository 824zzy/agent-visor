import path from "node:path";
import { describe, expect, it } from "vitest";
import { menuPresentation } from "../menu.js";
import { SessionRepository } from "../sessions.js";
import { CodexProvider } from "./codex.js";
import { readCodexDesktopRollouts } from "./codex-desktop.js";
import { LiveProviderEnvironment, type ProcessRecord } from "./environment.js";
import { processInstanceToken } from "./shared.js";

const current = "01a18016-2d8e-7040-8f7d-7b2439671b7c";
const saved = "01a18017-da3f-7302-89dc-a8d325846c66";
const app = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT";
const backend = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex";
const rollout = (id: string) => `/fixture/.codex/sessions/2026/10/27/rollout-2026-10-27T18-18-19-${id}.jsonl`;

class DesktopEnvironment extends LiveProviderEnvironment {
  writableRollouts = [rollout(current)];
  source = "vscode";
  originator = "Codex Desktop";
  desktopProbeCalls = 0;
  clock = Date.parse("2026-10-28T07:00:00Z");
  failCatalog = false;
  desktopStartedAt = new Date("2026-10-27T18:10:48");
  constructor() { super("/fixture", { now: () => new Date("2026-10-28T07:00:00Z") }); }
  override now() { return new Date(this.clock); }
  override async processes(): Promise<ProcessRecord[]> {
    return [{ pid: 9000, parentPID: 1, command: app, arguments: app,
      processStartToken: processInstanceToken(9000, this.desktopStartedAt) },
      { pid: 9001, parentPID: 9000, command: backend, arguments: `${backend} app-server` }];
  }
  override async codexDesktopCommand(_pid: number) { return app; }
  override async codexDesktopRollouts(pid: number, home: string, processes: ProcessRecord[]) {
    this.desktopProbeCalls++;
    return readCodexDesktopRollouts(pid, home, processes, {
      uid: 501, realpath: async value => String(value),
      run: async executable => ({ status: "success", exitCode: 0, stderr: "",
        stdout: executable === "/bin/ps"
          ? `9000 1 501 ?? Tue Oct 27 18:10:48 2026 ${app}\n9001 9000 501 ?? Tue Oct 27 18:10:49 2026 ${backend}\n`
          : "p9001\0\n" + this.writableRollouts.map((file, index) => `f${80 + index}\0au\0tREG\0n${file}\0\n`).join("") }),
    });
  }
  override async codexSettingsCatalog() { return undefined; }
  override async directory() { return []; }
  override async read() { return undefined; }
  override async stamp(file: string) {
    return file.endsWith("state_5.sqlite") || [rollout(current), rollout(saved)].includes(file)
      ? { modifiedAt: this.now(), size: 100 } : undefined;
  }
  override async sqlite(_file?: string, query?: string) {
    if (this.failCatalog && query?.includes("offset")) throw new Error("Fixture bulk catalog unavailable");
    return [current, saved].map(id => ({ id, cwd: "/project", rollout_path: rollout(id),
      title: id === current ? "Plan skills and MCP cleanup" : "Saved task", source: this.source,
      updated_at: this.now().valueOf() / 1000, archived: 0 }));
  }
  override async scanLinePrefixes(file: string, _bytes: number, visit: (line: string) => void) {
    const id = file === rollout(current) ? current : saved;
    visit(JSON.stringify({ type: "session_meta", payload: { id, originator: this.originator } }));
    visit(JSON.stringify({ type: "event_msg", timestamp: "2026-10-28T06:59:00Z",
      payload: { type: "task_complete", turn_id: "done" } }));
    return 100;
  }
}

describe("Codex Desktop live presence", () => {
  it("shows the exact live Desktop conversation as a pill while catalog-only conversations stay Saved", async () => {
    const environment = new DesktopEnvironment();
    const repository = new SessionRepository([new CodexProvider(environment)], { now: () => environment.now() });
    const snapshot = await repository.refresh();
    expect(snapshot.sessions.find(row => row.id === current)?.presence).toMatchObject({ state: "open", evidence: "runtime" });
    expect(snapshot.sessions.find(row => row.id === saved)?.presence).toMatchObject({ state: "unknown", evidence: "catalog" });
    expect(menuPresentation(snapshot, [], environment.now().valueOf()).pills.map(pill => pill.id)).toContain(current);
    expect(menuPresentation(snapshot, [], environment.now().valueOf()).pills.map(pill => pill.id)).not.toContain(saved);
    expect(repository.chatRecord(current)?.controlTarget).toEqual({ kind: "codex_thread",
      target: { pid: 9000, home: path.join(environment.home, ".codex"), threadId: current } });
  });

  it("uses fresh Desktop ownership when an old CLI transcript is now open in Desktop", async () => {
    const environment = new DesktopEnvironment();
    environment.source = "cli";
    environment.originator = "codex-tui";
    const repository = new SessionRepository([new CodexProvider(environment)], { now: () => environment.now() });
    await repository.refresh();
    expect(repository.chatRecord(current)).toMatchObject({ owner: "Codex", sessionClass: "interactive",
      presence: { state: "open", evidence: "runtime" }, controlTarget: { kind: "codex_thread", target: { pid: 9000, threadId: current } } });
    expect(repository.chatRecord(saved)?.controlTarget).toBeUndefined();
  });

  it("does not retain live presence after the Desktop backend releases the conversation", async () => {
    const environment = new DesktopEnvironment();
    const repository = new SessionRepository([new CodexProvider(environment)], { now: () => environment.now() });
    await repository.refresh();
    environment.writableRollouts = [];
    const snapshot = await repository.refresh();
    expect(snapshot.sessions.find(row => row.id === current)?.presence).toMatchObject({ state: "unknown", evidence: "catalog" });
    expect(menuPresentation(snapshot, [], environment.now().valueOf()).pills).toEqual([]);
  });

  it("preserves a verified live CLI route even when Desktop also holds the same transcript", async () => {
    const environment = new DesktopEnvironment();
    const desktopProcesses = await environment.processes();
    environment.processes = async () => [...desktopProcesses,
      { pid: 42, parentPID: 43, command: "/usr/local/bin/codex", arguments: "codex", tty: "ttys001" },
      { pid: 43, parentPID: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" }];
    environment.cwd = async () => "/project";
    environment.processStartedAt = async () => new Date("2026-10-28T06:00:00Z");
    environment.codexProcessHome = async () => "/fixture/.codex";
    const provider = new CodexProvider(environment);
    const repository = new SessionRepository([provider], { now: () => environment.now() });
    provider.noteHook({ provider: "codex", sessionId: current, event: "UserPromptSubmit", status: "working",
      cwd: "/project", pid: 42, tty: "ttys001", receivedAt: environment.now().toISOString(), sessionFile: rollout(current) });
    const snapshot = await repository.refresh();
    expect(repository.chatRecord(current)).toMatchObject({ owner: "Ghostty", sessionClass: "terminal",
      controlTarget: { kind: "terminal", target: { pid: 42, application: "Ghostty" } } });
    expect(snapshot.sessions.find(row => row.id === current)?.presence).toMatchObject({ state: "open", evidence: "frontend" });
  });

  it("does not promote another catalog ID that points at a live thread's transcript", async () => {
    const environment = new DesktopEnvironment();
    const rows = await environment.sqlite();
    environment.sqlite = async () => rows.map(row => row.id === saved ? { ...row, rollout_path: rollout(current) } : row);
    const repository = new SessionRepository([new CodexProvider(environment)], { now: () => environment.now() });
    const snapshot = await repository.refresh();
    expect(snapshot.sessions.find(row => row.id === saved)?.presence).toMatchObject({ state: "unknown", evidence: "catalog" });
  });

  it("keeps Desktop observation in background discovery when resolving an exact session for user actions", async () => {
    const environment = new DesktopEnvironment();
    const provider = new CodexProvider(environment);
    expect((await provider.resolve(current))?.presence?.state).toBe("unknown");
    expect(environment.desktopProbeCalls).toBe(0);
    await provider.discover();
    expect((await provider.resolve(current))?.presence).toMatchObject({ state: "open", evidence: "runtime" });
    expect(environment.desktopProbeCalls).toBe(1);
    environment.writableRollouts = [];
    await provider.discover();
    expect((await provider.resolve(current))?.presence).toMatchObject({ state: "unknown", evidence: "catalog" });
    expect(environment.desktopProbeCalls).toBe(2);
  });

  it("does not reuse background evidence for a replacement Desktop process with the same PID", async () => {
    const environment = new DesktopEnvironment();
    const provider = new CodexProvider(environment);
    await provider.discover();
    environment.desktopStartedAt = new Date("2026-10-28T08:00:00");
    expect((await provider.resolve(current))?.presence).toMatchObject({ state: "unknown", evidence: "catalog" });
    expect(environment.desktopProbeCalls).toBe(1);
  });
  it("does not refresh cached proof or revive it after failed background discovery", async () => {
    const environment = new DesktopEnvironment();
    const provider = new CodexProvider(environment);
    const repository = new SessionRepository([provider], { now: () => environment.now() });
    await repository.refresh();
    const observedAt = repository.chatRecord(current)?.presence?.observedAt;
    environment.clock += 1_000;
    expect((await provider.resolve(current))?.presence?.observedAt).toBe(observedAt);
    environment.writableRollouts = [];
    environment.failCatalog = true;
    environment.clock += 3_600_000;
    await repository.refresh();
    await repository.chatOpened(current, "fixture-view");
    expect(repository.chatRecord(current)?.presence?.state).not.toBe("open");
    expect(environment.desktopProbeCalls).toBe(1);
  });

  it("expires old Desktop proof without probing on a user action and recovers on discovery", async () => {
    const environment = new DesktopEnvironment();
    const provider = new CodexProvider(environment);
    await provider.discover();
    environment.clock += 60_000;
    expect((await provider.resolve(current))?.presence?.state).toBe("unknown");
    expect(environment.desktopProbeCalls).toBe(1);
    await provider.discover();
    expect((await provider.resolve(current))?.presence?.state).toBe("open");
    expect(environment.desktopProbeCalls).toBe(2);
  });

  it("keeps uncertain live CLI ownership and allows Desktop after that CLI exits", async () => {
    const environment = new DesktopEnvironment();
    const desktop = await environment.processes();
    let live = true, known = true, partial = false;
    const fullInventory = async () => [...desktop, ...(live ? [
      { pid: 42, parentPID: 43, command: "/usr/local/bin/codex", arguments: "codex", tty: "ttys001" },
      { pid: 43, parentPID: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
    ] : [])];
    environment.processes = async () => partial ? desktop : fullInventory();
    environment.processesFreshInventory = async () => ({ state: "authoritative", observedAt: environment.now().toISOString(), processes: await fullInventory() });
    environment.cwd = async () => "/project";
    environment.processStartedAt = async () => new Date("2026-10-28T06:00:00Z");
    Object.defineProperty(environment, "readCodexTuiBinding", { value: async () => known ? {
      sessionIds: [current], origin: "http://127.0.0.1:60119", socketPath: "/fixture/codex.sock", socketIdentity: "fixture",
      inventory: { loaded: [current], roots: [{ id: current, path: rollout(current) }] },
    } : undefined });
    Object.defineProperty(environment, "codexTuiTransportCapability", { value: async () => "unknown" });
    const repository = new SessionRepository([new CodexProvider(environment)], { now: () => environment.now() });
    await repository.refresh();
    expect(repository.chatRecord(current)?.controlTarget?.kind).toBe("terminal");
    known = false;
    await repository.refresh();
    expect(repository.chatRecord(current)?.owner).toBe("Codex CLI");
    expect(repository.chatRecord(current)?.controlTarget).toBeUndefined();
    partial = true;
    await repository.refresh();
    expect(repository.chatRecord(current)?.owner).toBe("Codex CLI");
    expect(repository.chatRecord(current)?.controlTarget).toBeUndefined();
    live = false;
    await repository.refresh();
    expect(repository.chatRecord(current)?.controlTarget?.kind).toBe("codex_thread");
  });

  it("keeps same-UUID CLI provenance inside its own Codex home", async () => {
    const environment = new DesktopEnvironment();
    const customHome = "/fixture/profile-two";
    const inHome = (home: string) => rollout(current).replace("/fixture/.codex", home);
    environment.processes = async () => [
      { pid: 9000, parentPID: 1, command: app, arguments: app, processStartToken: processInstanceToken(9000, environment.desktopStartedAt) },
      { pid: 9002, parentPID: 1, command: app, arguments: app, processStartToken: processInstanceToken(9002, environment.desktopStartedAt) },
      { pid: 42, parentPID: 43, command: "/usr/local/bin/codex", arguments: "codex", tty: "ttys001" },
      { pid: 43, parentPID: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: "ghostty" },
    ];
    environment.codexDesktopCommand = async (pid: number) => pid === 9002 ? `${app} CODEX_HOME=${customHome}` : app;
    environment.codexDesktopRollouts = async (_pid, home) => home === customHome ? [inHome(home)] : [];
    environment.cwd = async () => "/project";
    environment.processStartedAt = async () => new Date("2026-10-28T06:00:00Z");
    environment.stamp = async file => file.endsWith("state_5.sqlite") || file.endsWith(".jsonl") ? { modifiedAt: environment.now(), size: 100 } : undefined;
    environment.sqlite = async file => [{ id: current, cwd: "/project", rollout_path: inHome(file!.startsWith(customHome) ? customHome : "/fixture/.codex"),
      title: file!.startsWith(customHome) ? "Desktop copy" : "CLI copy", source: "vscode", updated_at: environment.clock / 1000, archived: 0 }];
    Object.defineProperty(environment, "readCodexTuiBinding", { value: async (_pid: number, home: string) => home === "/fixture/.codex" ? {
      sessionIds: [current], origin: "http://127.0.0.1:60119", socketPath: "/fixture/codex.sock", socketIdentity: "fixture",
      inventory: { loaded: [current], roots: [{ id: current, path: rollout(current) }] },
    } : undefined });
    Object.defineProperty(environment, "codexTuiTransportCapability", { value: async () => "unknown" });
    const repository = new SessionRepository([new CodexProvider(environment, () => [{ path: customHome, label: "Profile two" }])], { now: () => environment.now() });
    const snapshot = await repository.refresh();
    expect(repository.chatRecord(current)?.controlTarget?.kind).toBe("terminal");
    const copy = snapshot.sessions.find(row => row.title === "Desktop copy")!;
    expect(copy.presence).toMatchObject({ state: "open", evidence: "runtime" });
    expect(repository.chatRecord(copy.id)?.controlTarget).toMatchObject({ kind: "codex_thread", target: { pid: 9002, home: customHome, threadId: current } });
  });

  it("does not let an older discovery restore proof after a newer failed discovery", async () => {
    const environment = new DesktopEnvironment();
    const provider = new CodexProvider(environment);
    let enter!: () => void, release!: () => void;
    const entered = new Promise<void>(resolve => { enter = resolve; });
    const gate = new Promise<void>(resolve => { release = resolve; });
    const observe = environment.codexDesktopRollouts.bind(environment);
    environment.codexDesktopRollouts = async (...args) => {
      const files = await observe(...args);
      enter(); await gate; return files;
    };
    const older = provider.discover();
    await entered;
    environment.failCatalog = true;
    const newer = provider.discover();
    // Permit a non-serialized implementation to complete the newer failure.
    await Promise.race([newer, new Promise(resolve => setTimeout(resolve, 100))]);
    release();
    await Promise.all([older, newer]);
    expect(provider.discoveryAuthority()).toBe("unavailable");
    expect((await provider.resolve(current))?.presence?.state).not.toBe("open");
  });

  it("does not publish an in-flight Chat read's Desktop proof after discovery invalidates it", async () => {
    const environment = new DesktopEnvironment();
    const provider = new CodexProvider(environment);
    const repository = new SessionRepository([provider], { now: () => environment.now() });
    await repository.refresh();
    let enter!: () => void, release!: () => void, reads = 0;
    const entered = new Promise<void>(resolve => { enter = resolve; });
    const gate = new Promise<void>(resolve => { release = resolve; });
    const stamp = environment.stamp.bind(environment);
    environment.stamp = async file => {
      if (file === rollout(current) && ++reads === 2) { enter(); await gate; }
      return stamp(file);
    };
    const opening = repository.chatOpened(current, "overlap-view");
    await entered;
    environment.failCatalog = true;
    await repository.refresh();
    release(); await opening;
    expect(repository.chatRecord(current)?.presence?.state).not.toBe("open");
  });

});
