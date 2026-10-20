import { EventEmitter } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, expect, it, vi } from "vitest";

let cleanup: (() => Promise<void>) | undefined;
afterEach(async () => {
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.unstubAllEnvs();
  vi.doUnmock("electron");
  vi.doUnmock("node:child_process");
  vi.resetModules();
  await cleanup?.();
});

it("clears a previous Dock badge before the daemon can discover sessions", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-startup-"));
  let badge = "19";
  let daemonReached!: () => void;
  let quitReached!: () => void;
  const daemonStarted = new Promise<void>((resolve) => { daemonReached = resolve; });
  const quit = new Promise<void>((resolve) => { quitReached = resolve; });
  const paths = new Map([["appData", root], ["userData", root]]);
  const application = Object.assign(new EventEmitter(), {
    isPackaged: false,
    dock: { setBadge: (value: string) => { badge = value; } },
    setName: vi.fn(),
    getPath: (name: string) => paths.get(name),
    setPath: (name: string, value: string) => paths.set(name, value),
    requestSingleInstanceLock: () => true,
    whenReady: async () => undefined,
    quit: () => quitReached(),
  });
  const child = Object.assign(new EventEmitter(), {
    stdout: new EventEmitter(), stderr: new EventEmitter(), kill: vi.fn(),
  });
  cleanup = async () => {
    application.removeAllListeners();
    child.removeAllListeners();
    await rm(root, { recursive: true, force: true });
  };
  vi.stubEnv("AGENT_VISOR_NATIVE_HELPER", path.join(root, "helper"));
  vi.stubEnv("AGENT_VISOR_INTEGRATIONS_DIR", path.join(root, "integrations"));
  vi.useFakeTimers();
  vi.doMock("electron", () => ({
    app: application, BrowserWindow: class {}, dialog: {}, Menu: {}, shell: {},
    ipcMain: { on: vi.fn(), handle: vi.fn() },
  }));
  vi.doMock("node:child_process", async () => ({
    ...await vi.importActual<typeof import("node:child_process")>("node:child_process"),
    spawn: () => { daemonReached(); return child; },
  }));

  await import("./main.js");
  await Promise.race([
    daemonStarted,
    quit.then(() => { throw new Error("The fixture quit before reaching daemon startup."); }),
  ]);

  // The daemon has not replied or supplied any session snapshot.
  expect(badge).toBe("");

  child.emit("message", { type: "native_effect", action: "set_badge", count: 19 });
  expect(badge).toBe("");
});
