import { describe, expect, it } from "vitest";
import {
  ClaudeAgentInventory,
  claudeAgentCommandDeadlineMs,
  claudeAgentMaxOutputBytes,
  type ClaudeAgentInventoryRunner,
  type ClaudeAgentInventoryRow,
} from "./claude-agent-inventory.js";
import type { ProcessResult } from "../machine.js";

const home = "/Users/me";
const executable = "/Users/me/.local/bin/claude";

function success(rows: unknown): ProcessResult {
  return { status: "success", stdout: JSON.stringify(rows), stderr: "", exitCode: 0 };
}

function failure(stderr = "failed"): ProcessResult {
  return { status: "failed", stdout: "", stderr, exitCode: 1 };
}

function fixture(
  result: ProcessResult,
  options: { configDir?: string; resolveExecutable?: () => Promise<string | undefined> } = {},
) {
  let clock = 0;
  const calls: Array<{ executable: string; arguments_: readonly string[]; deadlineMs: number; maxOutputBytes: number }> = [];
  let next = result;
  const run: ClaudeAgentInventoryRunner = async (value, arguments_, runOptions) => {
    calls.push({ executable: value, arguments_, ...runOptions });
    return next;
  };
  const reader = new ClaudeAgentInventory({
    home,
    configDir: options.configDir,
    now: () => new Date(clock),
    refreshIntervalMs: 1_000,
    staleGraceMs: 5_000,
    unsupportedRetryMs: 2_000,
    resolveExecutable: options.resolveExecutable ?? (async () => executable),
    run,
  });
  return {
    reader,
    calls,
    setResult(value: ProcessResult) { next = value; },
    advance(ms: number) { clock += ms; },
  };
}

describe("ClaudeAgentInventory", () => {
  it("parses a valid array with optional fields and uses the bounded command", async () => {
    const rows: ClaudeAgentInventoryRow[] = [{
      id: "8e45ed2c",
      name: "cc-misc",
      kind: "background",
      cwd: "/Users/me/Codes",
      startedAt: 1_790_817_192_357,
      sessionId: "8e45ed2c-cd3b-4140-a8da-4614085a3536",
      pid: 88082,
      state: "done",
      status: "idle",
      waitingFor: "input",
    }, {
      name: "agent view",
      kind: "interactive",
      cwd: "/Users/me/Codes",
      startedAt: 1_790_817_192_358,
      sessionId: "fa6ddf2e-efba-45cc-90c2-579e461c3ffa",
      pid: 87741,
      status: "idle",
    }];
    const fixtureState = fixture(success(rows));

    const snapshot = await fixtureState.reader.read();

    expect(snapshot).toMatchObject({ kind: "success", root: `${home}/.claude`, rows });
    expect(fixtureState.calls).toEqual([{
      executable,
      arguments_: ["agents", "--json", "--all"],
      deadlineMs: claudeAgentCommandDeadlineMs,
      maxOutputBytes: claudeAgentMaxOutputBytes,
    }]);
    expect(snapshot.startedAt).toBeLessThanOrEqual(snapshot.completedAt);
  });

  it("keeps a valid empty inventory distinct from a failed read", async () => {
    const empty = fixture(success([]));
    await expect(empty.reader.read()).resolves.toMatchObject({ kind: "success", rows: [] });

    const failed = fixture(failure("connection failed"));
    await expect(failed.reader.read()).resolves.toMatchObject({ kind: "failure", reason: "process_failed" });
  });

  it.each([
    ["non-array", JSON.stringify({ sessions: [] })],
    ["missing required fields", JSON.stringify([{ name: "unknown" }])],
    ["invalid optional field", JSON.stringify([{ kind: "interactive", cwd: "/tmp", startedAt: 1, pid: "not-a-number" }])],
    ["invalid timestamp", JSON.stringify([{ kind: "interactive", cwd: "/tmp", startedAt: "later" }])],
  ])("rejects %s inventory responses without producing rows", async (_label, stdout) => {
    const state = fixture({ status: "success", stdout, stderr: "", exitCode: 0 });

    await expect(state.reader.read()).resolves.toMatchObject({ kind: "failure", reason: "invalid_rows" });
  });

  it("classifies unsupported commands and applies bounded retry", async () => {
    const state = fixture(failure("error: unknown command 'agents'"));

    const first = await state.reader.read();
    const second = await state.reader.read();
    expect(first).toMatchObject({ kind: "unsupported", reason: "command_unavailable" });
    expect(second).toBe(first);
    expect(state.calls).toHaveLength(1);

    state.advance(2_000);
    await state.reader.read();
    expect(state.calls).toHaveLength(2);
  });

  it("shares an initial request between concurrent callers", async () => {
    let resolve!: (result: ProcessResult) => void;
    const pending = new Promise<ProcessResult>((done) => { resolve = done; });
    const calls: string[] = [];
    const reader = new ClaudeAgentInventory({
      home,
      resolveExecutable: async () => executable,
      run: async (value) => { calls.push(value); return pending; },
    });

    const first = reader.read();
    const second = reader.read();
    await Promise.resolve();
    expect(calls).toEqual([executable]);
    resolve(success([{ kind: "background", cwd: "/tmp", startedAt: 1, id: "deadbeef", state: "done" }]));
    const snapshots = await Promise.all([first, second]);
    expect(snapshots[0]).toEqual(snapshots[1]);
  });

  it("returns the last good snapshot during a transient failure, then expires it", async () => {
    const state = fixture(success([{ kind: "background", cwd: "/tmp", startedAt: 1, id: "deadbeef", state: "done", name: "cc-misc" }]));
    const first = await state.reader.read();

    state.advance(1_001);
    state.setResult({ status: "timed_out", stdout: "", stderr: "" });
    expect(await state.reader.read()).toMatchObject({
      kind: "success", rows: [{ name: "cc-misc" }], freshness: "stale", authoritative: true,
    });
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    const failed = await state.reader.read();
    expect(failed).toMatchObject({
      kind: "failure", reason: "timed_out",
      lastGood: { rows: [{ name: "cc-misc" }], freshness: "stale", authoritative: true },
    });

    state.advance(5_001);
    state.setResult({ status: "timed_out", stdout: "", stderr: "" });
    expect(await state.reader.read()).toMatchObject({
      kind: "failure", lastGood: { rows: [{ name: "cc-misc" }], freshness: "stale", authoritative: false },
    });
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    const expired = await state.reader.read();
    expect(expired).toMatchObject({ kind: "failure", reason: "timed_out" });
    expect(expired).toMatchObject({
      lastGood: { rows: [{ name: "cc-misc" }], freshness: "stale", authoritative: false },
    });
  });

  it("marks an old identity as stale while a refresh remains nonblocking", async () => {
    let clock = 0;
    let calls = 0;
    let release!: (result: ProcessResult) => void;
    const pending = new Promise<ProcessResult>((resolve) => { release = resolve; });
    const reader = new ClaudeAgentInventory({
      home,
      now: () => new Date(clock),
      refreshIntervalMs: 1_000,
      staleGraceMs: 30_000,
      resolveExecutable: async () => executable,
      run: async () => {
        calls += 1;
        return calls === 1 ? success([{ kind: "background", cwd: "/tmp", startedAt: 1, id: "deadbeef", state: "done", name: "cc-misc" }]) : pending;
      },
    });
    await reader.read();

    clock = 30_001;
    const stale = await reader.read();
    expect(stale).toMatchObject({
      kind: "success", rows: [{ name: "cc-misc" }], freshness: "stale", authoritative: false,
    });
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    expect(calls).toBe(2);

    release(success([{ kind: "background", cwd: "/tmp", startedAt: 1, id: "deadbeef", state: "done", name: "cc-misc" }]));
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    await expect(reader.read()).resolves.toMatchObject({
      kind: "success", freshness: "fresh", authoritative: true,
    });
  });

  it("fails closed for another Claude config root or an untrusted executable", async () => {
    const isolated = fixture(success([{ id: "job" }]), { configDir: "/tmp/other-claude" });
    await expect(isolated.reader.read()).resolves.toMatchObject({ kind: "unsupported", reason: "config_root" });
    expect(isolated.calls).toHaveLength(0);

    const untrusted = fixture(success([{ id: "job" }]), {
      resolveExecutable: async () => "claude",
    });
    await expect(untrusted.reader.read()).resolves.toMatchObject({ kind: "unsupported", reason: "executable_missing" });
    expect(untrusted.calls).toHaveLength(0);
  });

  it("treats timeout and truncated output as failures, never as empty", async () => {
    const timeout = fixture({ status: "timed_out", stdout: "", stderr: "" });
    await expect(timeout.reader.read()).resolves.toMatchObject({ kind: "failure", reason: "timed_out" });

    const overflow = fixture({
      status: "failed", stdout: "x".repeat(claudeAgentMaxOutputBytes), stderr: "", exitCode: null,
    });
    await expect(overflow.reader.read()).resolves.toMatchObject({ kind: "failure", reason: "process_failed" });
  });
});
