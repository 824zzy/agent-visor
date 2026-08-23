import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { FakeNativeHelper } from "./native-helper.js";
import { NativeSessionControls } from "./session-controls.js";
import type { DiscoveredProviderSession } from "./sessions.js";

const roots: string[] = [];
const target = { application: "Ghostty" as const, tty: "ttys012", cwd: "/tmp/project" };

function session(overrides: Partial<DiscoveredProviderSession> = {}): DiscoveredProviderSession {
  return {
    id: "session-1", provider: "pi", cwd: "/tmp/project", owner: "Ghostty",
    section: "working", updatedAt: "2026-08-23T00:00:00.000Z",
    canOpenOwner: true, canEnterChat: true,
    controlTarget: { kind: "terminal", target }, messageTransport: "terminal",
    ...overrides,
  };
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("native session controls", () => {
  it("focuses and sends to the exact terminal target", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);

    await controls.focus(session());
    await controls.send(session(), "Continue", []);

    expect(helper.terminalFocusRequests).toEqual([target]);
    expect(helper.terminalSendRequests).toEqual([{ target, text: "Continue", submit: true }]);
  });

  it("serializes focus and skips stale queued requests", async () => {
    const helper = new FakeNativeHelper();
    let release: (() => void) | undefined;
    let calls = 0;
    const firstStarted = new Promise<void>((resolve) => {
      helper.focusTerminal = async (value) => {
        helper.terminalFocusRequests.push(structuredClone(value));
        calls += 1;
        if (calls !== 1) return;
        resolve();
        await new Promise<void>((resume) => { release = resume; });
      };
    });
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    const first = controls.focus(session());
    await firstStarted;
    const second = controls.focus(session({
      controlTarget: { kind: "terminal", target: { ...target, tty: "ttys013" } },
    }));
    const third = controls.focus(session({
      controlTarget: { kind: "terminal", target: { ...target, tty: "ttys014" } },
    }));
    release?.();
    await Promise.all([first, second, third]);

    expect(helper.terminalFocusRequests.map(({ tty }) => tty)).toEqual(["ttys012", "ttys014"]);
  });

  it("opens only provider-owned exact session URLs", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const urls: string[] = [];
    const controls = new NativeSessionControls(
      helper, root, undefined, async (url) => { urls.push(url); },
    );

    await controls.focus(session({
      provider: "codex",
      controlTarget: { kind: "url", url: "codex://threads/019f3931-ec11-7f31-8400-1c8624aa9e4d" },
    }));

    expect(urls).toEqual(["codex://threads/019f3931-ec11-7f31-8400-1c8624aa9e4d"]);
  });

  it("delivers Claude images as private path pastes before text", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);

    await controls.send(session({ provider: "claude_code" }), "Review", [{
      name: "pixel.png", mimeType: "image/png", data: Buffer.from("png").toString("base64"),
    }]);

    expect(helper.terminalSendRequests).toHaveLength(2);
    const imagePath = helper.terminalSendRequests[0]!.text;
    expect(await readFile(imagePath, "utf8")).toBe("png");
    expect((await stat(imagePath)).mode & 0o777).toBe(0o600);
    expect(helper.terminalSendRequests[0]!.submit).toBe(false);
    expect(helper.terminalSendRequests[1]).toEqual({ target, text: "Review", submit: true });
    await controls.close();
    await expect(stat(imagePath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("uses Codex app-server transport with local images", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const calls: unknown[][] = [];
    const controls = new NativeSessionControls(helper, root, async (...args) => { calls.push(args); });

    await controls.send(session({ provider: "codex", messageTransport: "codex_app_server" }), "Fix", [{
      name: "pixel.webp", mimeType: "image/webp", data: Buffer.from("webp").toString("base64"),
    }]);

    expect(calls).toHaveLength(1);
    expect(calls[0]![0]).toBe("session-1");
    expect(calls[0]![1]).toBe("Fix");
    expect(calls[0]![2]).toHaveLength(1);
  });
});
