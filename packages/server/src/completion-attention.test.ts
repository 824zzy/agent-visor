import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { expect, it } from "vitest";
import { SessionRepository, type DiscoveredProviderSession } from "./sessions.js";
import { menuPresentation } from "./menu.js";
import { FakeNativeHelper } from "./native-helper.js";
import { NativeSessionControls } from "./session-controls.js";

const completedAt = "2026-10-05T15:00:00.000Z";
const completed: DiscoveredProviderSession = {
  id: "finished", provider: "codex", title: "Finished task", cwd: "/project", owner: "Codex",
  section: "ready", turnState: "ready", turnId: "turn-1", updatedAt: completedAt,
  codexLifecycle: { phase: "ready", observedAt: completedAt, turnId: "turn-1" },
  conversationState: "open", canOpenOwner: true, canEnterChat: true,
  controlTarget: { kind: "application", target: { pid: 42 } },
};

it("keeps an unopened completion ahead of working across age and restart, then keeps it seen", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "visor-completion-"));
  const options = { completionAttentionPath: path.join(root, "attention.json"),
    now: () => new Date("2026-10-05T15:01:00.000Z") };
  let row = completed;
  const provider = { id: "codex" as const, discover: async () => [row, {
    ...completed, id: "running", title: "Running task", section: "working" as const,
    turnState: "working" as const, updatedAt: options.now().toISOString(),
  }] };
  try {
    let repository = new SessionRepository([provider], options);
    await repository.refresh();
    row = { ...completed, section: "history" };
    options.now = () => new Date("2026-10-06T15:01:00.000Z");
    repository = new SessionRepository([provider], options);
    expect((await repository.refresh()).sessions.find((row) => row.id === completed.id)?.attentionTier).toBe("ready");
    expect(menuPresentation(repository.current(), [], options.now().valueOf()).pills.map((pill) => pill.id)).toEqual(["finished", "running"]);
    repository.setControls({ focus: async () => undefined, send: async () => undefined });
    expect(await repository.focusSession("finished")).toBeUndefined();
    repository = new SessionRepository([provider], options);
    expect((await repository.refresh()).sessions.find((row) => row.id === completed.id)?.attentionTier).toBe("history");
    row = { ...completed, turnId: "turn-2", updatedAt: options.now().toISOString() };
    expect((await repository.refresh()).sessions.find((row) => row.id === completed.id)?.attentionTier).toBe("ready");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

it("restores a seen fresh completion without rearming it after a metadata refresh", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "visor-seen-"));
  const options = { completionAttentionPath: path.join(root, "attention.json"),
    now: () => new Date("2026-10-05T15:01:00.000Z") };
  let row = completed;
  const provider = { id: "codex" as const, discover: async () => [row] };
  try {
    let repository = new SessionRepository([provider], options);
    await repository.refresh();
    repository.acknowledgeReady(row.id);
    repository = new SessionRepository([provider], options);
    row = { ...row, title: "Renamed" };
    expect((await repository.refresh()).sessions[0]?.attentionTier).toBe("acknowledged_ready");
    expect(repository.current().sessions[0]?.completionUnseen).toBeUndefined();
    row = { ...row, turnId: "turn-2", updatedAt: options.now().toISOString() };
    expect((await repository.refresh()).sessions[0]?.completionUnseen).toBe(true);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

it("does not invent unopened results for old catalog entries or an idle empty conversation", async () => {
  const repository = new SessionRepository([{ id: "codex", discover: async () => [
    { ...completed, section: "history" as const },
    { ...completed, id: "empty", provider: "claude_code" as const, codexLifecycle: undefined,
      turnId: undefined, updatedAt: "2026-10-06T15:01:00.000Z" },
  ] }], { now: () => new Date("2026-10-06T15:01:00.000Z") });
  expect((await repository.refresh()).sessions.every((row) => row.completionUnseen !== true)).toBe(true);
  expect(repository.current().sessions.find((row) => row.id === completed.id)?.section).toBe("history");
});

it("ignores malformed attention state instead of acknowledging a completion", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "visor-invalid-"));
  const file = path.join(root, "attention.json");
  try {
    writeFileSync(file, '{"version":1,"entries":[null]}');
    const repository = new SessionRepository([{ id: "codex", discover: async () => [completed] }], {
      completionAttentionPath: file, now: () => new Date("2026-10-05T15:01:00.000Z"),
    });
    expect((await repository.refresh()).sessions[0]?.completionUnseen).toBe(true);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

it("keeps a Codex completion unopened until explicitly activated", async () => {
  const id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
  const row = { ...completed, id, controlTarget: { kind: "codex_thread" as const,
    target: { pid: 42, home: "/fixture/.codex", threadId: id } } };
  let pid = 43;
  const helper = Object.assign(new FakeNativeHelper(), {
    foregroundSessionView: async () => ({ source: "codex" as const, pid, threadId: id,
      observedAt: "2026-10-05T15:01:00.000Z" }),
  });
  const repository = new SessionRepository([{ id: "codex", discover: async () => [row] }], {
    now: () => new Date("2026-10-05T15:01:00.000Z"),
  });
  repository.setControls(new NativeSessionControls(helper));
  expect((await repository.refresh()).sessions[0]?.attentionTier).toBe("ready");
  pid = 42;
  expect((await repository.refresh()).sessions[0]?.completionUnseen).toBe(true);
  expect(await repository.focusSession(id)).toBeUndefined();
  expect(repository.current().sessions[0]?.attentionTier).toBe("acknowledged_ready");
});

it("keeps a Claude completion unopened until explicitly activated", async () => {
  const terminal = { applicationPID: 7, processStartToken: "instance-one", terminalId: "surface-a",
    title: "✳ Cleanup", cwd: "/project" };
  const row: DiscoveredProviderSession = { ...completed, provider: "claude_code", owner: "Ghostty", title: "Cleanup",
    codexLifecycle: undefined, completionAt: completedAt,
    controlTarget: { kind: "claude_background", target: { jobId: "aa11bb22", executable: "/usr/bin/claude",
      cwd: "/project", application: "Ghostty", displayed: terminal } } };
  const helper = Object.assign(new FakeNativeHelper(), {
    foregroundSessionView: async () => ({ source: "ghostty" as const, terminal,
      observedAt: "2026-10-05T15:01:00.000Z" }),
  });
  const repository = new SessionRepository([{ id: "claude_code", discover: async () => [row],
    resolveForFocus: async (id) => id === row.id ? row : undefined }], {
    now: () => new Date("2026-10-05T15:01:00.000Z"),
  });
  repository.setControls(new NativeSessionControls(helper));
  expect((await repository.refresh()).sessions[0]?.completionUnseen).toBe(true);
  expect((await repository.refresh()).sessions[0]?.attentionTier).toBe("ready");
  expect(await repository.focusSession(row.id)).toBeUndefined();
  expect(repository.current().sessions[0]?.attentionTier).toBe("acknowledged_ready");
});
