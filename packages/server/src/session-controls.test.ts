import { mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ChatImage, ChatPage } from "@agent-visor/protocol";
import { FakeNativeHelper } from "./native-helper.js";
import {
  MAX_NATIVE_SESSION_ACTIONS_PER_SESSION,
  MAX_TERMINAL_DELIVERY_RECORDS,
  NativeSessionControls,
} from "./session-controls.js";
import type { DiscoveredProviderSession } from "./sessions.js";
import { processInstanceToken } from "./providers/shared.js";

const roots: string[] = [];
const target = {
  application: "Ghostty" as const,
  pid: 42,
  processStartToken: processInstanceToken(42, "2026-08-23T00:00:00.000Z"),
  tty: "ttys012",
  cwd: "/tmp/project",
};
const replacementTarget = {
  application: "Ghostty" as const,
  pid: 43,
  processStartToken: processInstanceToken(43, "2026-08-23T00:00:01.000Z"),
  tty: "ttys013",
  cwd: "/tmp/project",
};
const png = Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]);
const webp = Uint8Array.from([82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80]);

function image(overrides: Partial<ChatImage> = {}): ChatImage {
  return {
    name: "pixel.png",
    mimeType: "image/png",
    byteLength: png.byteLength,
    data: Buffer.from(png).toString("base64"),
    ...overrides,
  };
}

function session(overrides: Partial<DiscoveredProviderSession> = {}): DiscoveredProviderSession {
  return {
    id: "session-1", provider: "pi", cwd: "/tmp/project", owner: "Ghostty",
    section: "working", updatedAt: "2026-08-23T00:00:00.000Z",
    canOpenOwner: true, canEnterChat: true,
    controlTarget: { kind: "terminal", target }, messageTransport: "terminal",
    ...overrides,
  };
}

function page(...users: Array<{
  id: string;
  text: string;
  timestamp?: string;
  images?: ChatImage[];
  requestId?: string;
  deliveryId?: string;
  providerMessageId?: string;
}>): ChatPage {
  return {
    type: "chat_page",
    sessionId: "session-1",
    items: users.map(({ id, text, timestamp, images = [], requestId, deliveryId, providerMessageId }) => ({
      id, kind: "user" as const, text, images,
      ...(timestamp ? { timestamp } : {}),
      ...(requestId ? { requestId } : {}),
      ...(deliveryId ? { deliveryId } : {}),
      ...(providerMessageId ? { providerMessageId } : {}),
    })),
    hasMoreBefore: false,
    capabilities: {
      canSendText: true, canSendImages: true, canCancel: false,
      canApprove: false, canAnswer: false,
    },
    pendingAction: null,
  };
}

async function sendAndObserve(
  controls: NativeSessionControls,
  targetSession: DiscoveredProviderSession,
  text: string,
  deliveryId: string,
  canonicalId: string,
): Promise<void> {
  await controls.send(targetSession, text, [], deliveryId, {
    baselineUserEntryIds: [],
    baselineComplete: true,
    submittedText: text,
  });
  controls.reconcileChatPage(targetSession, page({ id: canonicalId, text }));
}

afterEach(async () => {
  vi.useRealTimers();
  vi.restoreAllMocks();
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

  it("cycles Claude permission mode only through the verified terminal target", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    const claude = session({ provider: "claude_code" });

    expect(controls.canCyclePermissionMode(claude)).toBe(true);
    await controls.cyclePermissionMode(claude);
    expect(helper.cyclePermissionModeRequests).toEqual([target]);

    await expect(controls.cyclePermissionMode(session({ provider: "pi" })))
      .rejects.toThrow("unavailable");
    expect(helper.cyclePermissionModeRequests).toHaveLength(1);
  });

  it("fails closed when the terminal identity changes before permission cycling", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    const claude = session({ provider: "claude_code" });
    controls.reconcile(claude);
    const replacement = session({
      provider: "claude_code",
      controlTarget: { kind: "terminal", target: replacementTarget },
    });

    expect(controls.canCyclePermissionMode(replacement)).toBe(false);
    await expect(controls.cyclePermissionMode(replacement)).rejects.toThrow("unavailable");
    expect(helper.cyclePermissionModeRequests).toEqual([]);
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

  it("serializes terminal registration with writes so a queued send cannot replace the active delivery", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    let releaseFirst: (() => void) | undefined;
    let firstStarted: (() => void) | undefined;
    const started = new Promise<void>((resolve) => { firstStarted = resolve; });
    let sendCount = 0;
    helper.sendTerminal = async (value, text, submit) => {
      helper.terminalSendRequests.push({ target: value, text, submit });
      sendCount += 1;
      if (sendCount !== 1) return;
      firstStarted?.();
      await new Promise<void>((resolve) => { releaseFirst = resolve; });
    };
    const controls = new NativeSessionControls(helper, root);
    const evidence = (text: string) => ({
      baselineUserEntryIds: [], baselineComplete: true, submittedText: text,
    });
    const first = controls.send(session(), "First", [], "delivery-a", evidence("First"));
    await started;
    const second = controls.send(session(), "Second", [], "delivery-b", evidence("Second"));

    // A is the only registered delivery while its helper write is blocked;
    // B must not be able to steal the cancellation slot before its turn.
    controls.reconcileChatPage(session(), page({ id: "canonical-a", text: "First" }));
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-a");

    releaseFirst?.();
    await Promise.all([first, second]);
    // A remains the newest confirmed cancellation target until the provider
    // publishes B's canonical row. B's successful paste must not erase A.
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-a");
    controls.reconcileChatPage(session(), page(
      { id: "canonical-a", text: "First" },
      { id: "canonical-b", text: "Second" },
    ));
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-b");
    expect(helper.terminalSendRequests.map(({ text }) => text)).toEqual(["First", "Second"]);
  });

  it("rejects a stale queued send before registration or native write", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    let releaseFirst: (() => void) | undefined;
    let firstStarted: (() => void) | undefined;
    const started = new Promise<void>((resolve) => { firstStarted = resolve; });
    helper.focusTerminal = async (value) => {
      helper.terminalFocusRequests.push(structuredClone(value));
      firstStarted?.();
      await new Promise<void>((resolve) => { releaseFirst = resolve; });
    };
    const controls = new NativeSessionControls(helper, root);
    const first = controls.focus(session());
    await started;

    let current = true;
    const queued = controls.send(session(), "stale", [], "delivery-stale", {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "stale",
    }, () => current);
    current = false;
    releaseFirst?.();

    await first;
    await expect(queued).rejects.toThrow(/current|available|changed/i);
    expect(helper.terminalSendRequests).toEqual([]);

    controls.reconcileChatPage(session(), page({ id: "canonical-stale", text: "stale" }));
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();
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
      name: "pixel.png", mimeType: "image/png", byteLength: png.byteLength,
      data: Buffer.from(png).toString("base64"),
    }]);

    expect(helper.terminalSendRequests).toHaveLength(2);
    const imagePath = helper.terminalSendRequests[0]!.text;
    expect(await readFile(imagePath)).toEqual(Buffer.from(png));
    expect((await stat(imagePath)).mode & 0o777).toBe(0o600);
    expect(helper.terminalSendRequests[0]!.submit).toBe(false);
    expect(helper.terminalSendRequests[1]).toEqual({ target, text: "Review", submit: true });
    await controls.close();
    await expect(stat(imagePath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("removes only operation images when a terminal action fails", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    helper.sendTerminal = async (value, text, submit) => {
      helper.terminalSendRequests.push({ target: value, text, submit });
      throw new Error("helper disappeared during image paste");
    };
    const controls = new NativeSessionControls(helper, root);

    await expect(controls.send(session({ provider: "claude_code" }), "Review", [image()]))
      .rejects.toThrow("helper disappeared");
    await expect(readdir(root)).resolves.toEqual([]);
  });

  it("uses Codex app-server transport with local images", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const calls: unknown[][] = [];
    const controls = new NativeSessionControls(helper, root, async (...args) => { calls.push(args); });

    await controls.send(session({ provider: "codex", messageTransport: "codex_app_server" }), "Fix", [{
      name: "pixel.webp", mimeType: "image/webp", byteLength: webp.byteLength,
      data: Buffer.from(webp).toString("base64"),
    }]);

    expect(calls).toHaveLength(1);
    expect(calls[0]![0]).toBe("session-1");
    expect(calls[0]![1]).toBe("Fix");
    expect(calls[0]![2]).toHaveLength(1);
  });

  it("cancels a working terminal-backed provider through the exact terminal target", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);

    await sendAndObserve(controls, session(), "Working", "delivery-terminal", "user-working");
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-terminal");
    await expect(controls.cancel(session(), "wrong-delivery")).rejects.toThrow("unavailable");
    await controls.cancel(session(), "delivery-terminal");

    expect(helper.terminalCancelRequests).toEqual([target]);
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();
    expect(controls.canCancel(session(), "delivery-terminal")).toBe(false);
  });

  it("does not let a deferred cancel resurrect after forget tombstone churn", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    await sendAndObserve(controls, session(), "Working", "delivery-deferred-cancel", "canonical-cancel");
    let release: (() => void) | undefined;
    let started!: () => void;
    const startedPromise = new Promise<void>((resolve) => { started = resolve; });
    helper.cancelTerminal = async (value) => {
      helper.terminalCancelRequests.push(structuredClone(value));
      started();
      await new Promise<void>((resolve) => { release = resolve; });
    };
    const deferred = controls.cancel(session(), "delivery-deferred-cancel");
    await startedPromise;
    controls.forget("session-1");
    for (let index = 0; index < 513; index += 1) controls.forget(`unrelated-cancel-${index}`);
    release?.();
    await expect(deferred).rejects.toThrow("unavailable");
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();
    expect(helper.terminalCancelRequests).toHaveLength(1);
  });

  it("binds Pi text-plus-image cancellation to the exact path-bearing transcript row", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    await controls.send(session(), "Explain this image", [image({ name: "diagram.png" })], "delivery-pi-text-image", {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "Explain this image", requestId: "request-pi-text-image",
    });
    const prompt = helper.terminalSendRequests.at(-1)?.text ?? "";
    expect(prompt).toMatch(/^Explain this image\n\/.*\.png$/);
    controls.reconcileChatPage(session(), page({ id: "pi-text-image", text: prompt }), true);
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-pi-text-image");
  });

  it("binds Pi image-only cancellation to its exact canonical path", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    await controls.send(session(), "", [image({ name: "only.png" })], "delivery-pi-image-only", {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "", requestId: "request-pi-image-only",
    });
    const prompt = helper.terminalSendRequests.at(-1)?.text ?? "";
    expect(prompt).toMatch(/^\/.*\.png$/);
    controls.reconcileChatPage(session(), page({ id: "pi-image-only", text: prompt }), true);
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-pi-image-only");
  });

  it("requires exact image fingerprints for identity-less Claude fallback", async () => {
    const evidence = {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "Review",
      authoritativeComplete: true, submittedAt: "2026-08-23T00:00:10.000Z",
    };
    const observe = async (
      submittedImages: ChatImage[],
      canonicalImages: ChatImage[],
      deliveryId: string,
    ) => {
      const helper = new FakeNativeHelper();
      const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
      roots.push(root);
      const controls = new NativeSessionControls(helper, root);
      await controls.send(session({ provider: "claude_code" }), "Review", submittedImages, deliveryId, evidence);
      controls.reconcileChatPage(session({ provider: "claude_code" }), page({
        id: `canonical-${deliveryId}`,
        text: "Review",
        timestamp: "2026-08-23T00:00:11.000Z",
        images: canonicalImages,
      }));
      const active = controls.activeCancelDeliveryId(session({ provider: "claude_code" }));
      await controls.close();
      return active;
    };

    expect(await observe([image()], [], "delivery-no-image")).toBeUndefined();
    expect(await observe([image()], [image({ byteLength: png.byteLength + 1, data: Buffer.from([...png, 1]).toString("base64") })], "delivery-different-image"))
      .toBeUndefined();
    expect(await observe([image()], [image()], "delivery-same-image")).toBe("delivery-same-image");
  });

  it("requires image order and multiplicity to match fallback evidence", async () => {
    const pngImage = image({ name: "one.png" });
    const webpImage: ChatImage = {
      name: "two.webp", mimeType: "image/webp", byteLength: webp.byteLength,
      data: Buffer.from(webp).toString("base64"),
    };
    const evidence = {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "Review",
      authoritativeComplete: true, submittedAt: "2026-08-23T00:00:10.000Z",
    };
    const observe = async (canonicalImages: ChatImage[], deliveryId: string) => {
      const helper = new FakeNativeHelper();
      const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
      roots.push(root);
      const controls = new NativeSessionControls(helper, root);
      await controls.send(session({ provider: "claude_code" }), "Review", [pngImage, webpImage], deliveryId, evidence);
      controls.reconcileChatPage(session({ provider: "claude_code" }), page({
        id: `canonical-${deliveryId}`, text: "Review",
        timestamp: "2026-08-23T00:00:11.000Z", images: canonicalImages,
      }));
      const active = controls.activeCancelDeliveryId(session({ provider: "claude_code" }));
      await controls.close();
      return active;
    };

    expect(await observe([webpImage, pngImage], "delivery-reversed")).toBeUndefined();
    expect(await observe([pngImage], "delivery-missing-image")).toBeUndefined();
    expect(await observe([pngImage, webpImage], "delivery-matching-images")).toBe("delivery-matching-images");
  });

  it("keeps Stop hidden until the submitted terminal turn has one canonical echo", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    const evidence = {
      baselineUserEntryIds: ["user-before"],
      baselineComplete: true,
      submittedText: "Working",
    };

    await controls.send(session(), "Working", [], "delivery-terminal", evidence);
    controls.reconcileChatPage(session(), page({ id: "user-before", text: "Working" }));
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();

    controls.reconcileChatPage(session(), page(
      { id: "user-before", text: "Working" },
      { id: "user-after", text: "Working" },
    ));
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-terminal");

    // Re-reading the same transcript must not create a second turn or clear the match.
    controls.reconcileChatPage(session(), page(
      { id: "user-before", text: "Working" },
      { id: "user-after", text: "Working" },
    ));
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-terminal");
  });

  it("uses the baseline to distinguish identical prompts and fails closed on a different turn", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    const evidence = {
      baselineUserEntryIds: ["same-before"],
      baselineComplete: true,
      submittedText: "Same prompt",
    };

    await controls.send(session(), "Same prompt", [], "delivery-same", evidence);
    controls.reconcileChatPage(session(), page(
      { id: "same-before", text: "Same prompt" },
      { id: "same-after", text: "Same prompt" },
    ));
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-same");

    const second = new NativeSessionControls(helper, root);
    await second.send(session(), "Expected", [], "delivery-mismatch", {
      baselineUserEntryIds: ["before"], baselineComplete: true, submittedText: "Expected",
    });
    second.reconcileChatPage(session(), page(
      { id: "before", text: "Prior" },
      { id: "external", text: "Different external turn" },
    ));
    expect(second.activeCancelDeliveryId(session())).toBeUndefined();
  });

  it("never uses text fallback when a canonical row carries mismatched identity", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    await controls.send(session(), "Same prompt", [], "delivery-exact", {
      baselineUserEntryIds: ["before"],
      baselineComplete: true,
      submittedText: "Same prompt",
      requestId: "request-exact",
    });

    controls.reconcileChatPage(session(), page(
      { id: "before", text: "Earlier" },
      { id: "wrong-delivery", text: "Same prompt", deliveryId: "delivery-other" },
    ));
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();

    const requestControls = new NativeSessionControls(helper, root);
    await requestControls.send(session(), "Same prompt", [], "delivery-request", {
      baselineUserEntryIds: ["before"],
      baselineComplete: true,
      submittedText: "Same prompt",
      requestId: "request-exact",
    });
    requestControls.reconcileChatPage(session(), page(
      { id: "before", text: "Earlier" },
      { id: "wrong-request", text: "Same prompt", requestId: "request-other" },
    ));
    expect(requestControls.activeCancelDeliveryId(session())).toBeUndefined();
  });

  it("requires authoritative post-submit evidence for content fallback", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const submittedAt = "2026-08-23T00:00:10.000Z";
    const nonAuthoritative = new NativeSessionControls(helper, root);
    await nonAuthoritative.send(session(), "Same prompt", [], "delivery-empty", {
      baselineUserEntryIds: [], baselineComplete: false, submittedText: "Same prompt",
      authoritativeComplete: false, submittedAt,
    });
    nonAuthoritative.reconcileChatPage(session(), page({
      id: "old-row", text: "Same prompt", timestamp: "2026-08-23T00:00:11.000Z",
    }));
    expect(nonAuthoritative.activeCancelDeliveryId(session())).toBeUndefined();

    const old = new NativeSessionControls(helper, root);
    await old.send(session(), "Same prompt", [], "delivery-old", {
      baselineUserEntryIds: ["before"], baselineComplete: true, submittedText: "Same prompt",
      authoritativeComplete: true, submittedAt,
    });
    old.reconcileChatPage(session(), page(
      { id: "before", text: "Earlier", timestamp: "2026-08-23T00:00:09.000Z" },
      { id: "old-row", text: "Same prompt", timestamp: "2026-08-23T00:00:09.500Z" },
    ));
    expect(old.activeCancelDeliveryId(session())).toBeUndefined();

    const fresh = new NativeSessionControls(helper, root);
    await fresh.send(session(), "Same prompt", [], "delivery-fresh", {
      baselineUserEntryIds: ["before"], baselineComplete: true, submittedText: "Same prompt",
      authoritativeComplete: true, submittedAt,
    });
    fresh.reconcileChatPage(session(), page(
      { id: "before", text: "Earlier", timestamp: "2026-08-23T00:00:09.000Z" },
      { id: "new-row", text: "Same prompt", timestamp: "2026-08-23T00:00:11.000Z" },
    ));
    expect(fresh.activeCancelDeliveryId(session())).toBe("delivery-fresh");
  });

  it("allows exact delivery identity without a source timestamp", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    await controls.send(session(), "Image prompt", [], "delivery-exact", {
      baselineUserEntryIds: [], baselineComplete: false, submittedText: "Image prompt",
      authoritativeComplete: false, submittedAt: "2026-08-23T00:00:10.000Z",
      requestId: "request-exact",
    });
    controls.reconcileChatPage(session(), page({
      id: "exact-row", text: "Image prompt", deliveryId: "delivery-exact",
    }));
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-exact");
  });

  it("consumes one canonical row at most once across identical deliveries", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    const evidence = {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "Same prompt",
    };

    await controls.send(session(), "Same prompt", [], "delivery-a", evidence);
    await controls.send(session(), "Same prompt", [], "delivery-b", evidence);
    const canonical = page({ id: "one-row", text: "Same prompt" });
    controls.reconcileChatPage(session(), canonical);

    // The one canonical ID cannot silently back both pending deliveries. The
    // exact row is consumed by at most one cancellation target.
    const active = controls.activeCancelDeliveryId(session());
    expect(active).toBeUndefined();
    expect(helper.terminalCancelRequests).toEqual([]);
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();
  });

  it("does not consume a replayed canonical row for a later delivery", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);

    await sendAndObserve(controls, session(), "Same prompt", "delivery-first", "old-row");
    controls.reconcileChatPage(session(), page(
      { id: "old-row", text: "Same prompt" },
      { id: "external-row", text: "External" },
    ));
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();

    await controls.send(session(), "Same prompt", [], "delivery-second", {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "Same prompt",
    });
    controls.reconcileChatPage(session(), page({ id: "old-row", text: "Same prompt" }));
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();
  });

  it("rejects the action over-cap before a queued send can materialize images", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    let releaseFirst: (() => void) | undefined;
    let signalStarted!: () => void;
    const started = new Promise<void>((resolve) => { signalStarted = resolve; });
    let firstCall = true;
    helper.sendTerminal = async (value, text, submit) => {
      helper.terminalSendRequests.push({ target: value, text, submit });
      if (firstCall) {
        firstCall = false;
        signalStarted();
        await new Promise<void>((resume) => { releaseFirst = resume; });
      }
    };
    const controls = new NativeSessionControls(helper, root);
    const evidence = {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "queued",
    };
    const first = controls.send(session(), "first", [], "delivery-first", evidence);
    // Wait until the head owns the lane, then fill every remaining bounded
    // reservation with distinct sends. The rejected send must not touch the
    // image root or native helper.
    await started;
    const queued = Array.from({ length: MAX_NATIVE_SESSION_ACTIONS_PER_SESSION - 1 }, (_, index) =>
      controls.send(session(), `queued-${index}`, [], `delivery-${index}`, evidence));
    await expect(controls.send(
      session(), "over-cap", [image()], "delivery-over-cap", evidence,
    )).rejects.toThrow(/too many provider actions/i);
    expect(helper.terminalSendRequests).toHaveLength(1);
    releaseFirst?.();
    await Promise.all([first, ...queued]);
  });

  it("rejects terminal evidence admission when every bounded record is still actionable", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    for (let index = 0; index < MAX_TERMINAL_DELIVERY_RECORDS; index += 1) {
      await controls.send(session(), `prompt-${index}`, [], `delivery-${index}`, {
        baselineUserEntryIds: [], baselineComplete: true, submittedText: `prompt-${index}`,
        authoritativeComplete: false,
      });
    }
    await expect(controls.send(
      session(), "over-evidence-cap", [], "delivery-over-evidence-cap", {
        baselineUserEntryIds: [], baselineComplete: true, submittedText: "over-evidence-cap",
        authoritativeComplete: false,
      },
    )).rejects.toThrow(/evidence capacity/i);
    expect(helper.terminalSendRequests).toHaveLength(MAX_TERMINAL_DELIVERY_RECORDS);
  });

  it("clears a bound terminal delivery when a later same-target turn becomes latest", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    await controls.send(session(), "First", [], "delivery-first", {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "First",
    });
    controls.reconcileChatPage(session(), page({ id: "first", text: "First" }));
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-first");

    controls.reconcileChatPage(session(), page(
      { id: "first", text: "First" },
      { id: "external", text: "External" },
    ));
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();
    expect(helper.terminalCancelRequests).toEqual([]);
  });

  it("clears terminal cancellation when the turn completes or its route changes", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);

    await sendAndObserve(controls, session(), "Working", "delivery-a", "user-a");
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-a");

    controls.reconcile(session({ section: "ready" }));
    expect(controls.activeCancelDeliveryId(session({ section: "ready" }))).toBeUndefined();
    await expect(controls.cancel(session(), "delivery-a")).rejects.toThrow("unavailable");

    const replacementSession = session({ controlTarget: { kind: "terminal", target: replacementTarget } });
    await sendAndObserve(controls, replacementSession, "Working", "delivery-b", "user-b");
    expect(controls.activeCancelDeliveryId(session({ controlTarget: { kind: "terminal", target: replacementTarget } }))).toBe("delivery-b");
    controls.reconcile(session({ controlTarget: { kind: "terminal", target } }));
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();
    await expect(controls.cancel(session(), "delivery-b")).rejects.toThrow("unavailable");
    expect(helper.terminalCancelRequests).toEqual([]);
  });

  it("clears every terminal delivery timer on session-wide clear", async () => {
    vi.useFakeTimers();
    const clearTimeoutSpy = vi.spyOn(globalThis, "clearTimeout");
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    const evidence = (text: string) => ({
      baselineUserEntryIds: [], baselineComplete: true, submittedText: text,
    });

    await controls.send(session(), "First", [], "delivery-first", evidence("First"));
    await controls.send(session(), "Second", [], "delivery-second", evidence("Second"));
    expect(vi.getTimerCount()).toBe(2);

    controls.clear("session-1");

    expect(vi.getTimerCount()).toBe(0);
    expect(clearTimeoutSpy).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(5 * 60_000 + 1);
    expect(clearTimeoutSpy).toHaveBeenCalledTimes(2);
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();
  });

  it("forgets one session's terminal timer without affecting another session", async () => {
    vi.useFakeTimers();
    const clearTimeoutSpy = vi.spyOn(globalThis, "clearTimeout");
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    const secondSession = session({ id: "session-2" });
    const evidence = (text: string) => ({
      baselineUserEntryIds: [], baselineComplete: true, submittedText: text,
    });

    await controls.send(session(), "First", [], "delivery-first", evidence("First"));
    await controls.send(secondSession, "Second", [], "delivery-second", evidence("Second"));
    expect(vi.getTimerCount()).toBe(2);

    controls.forget("session-1");

    expect(vi.getTimerCount()).toBe(1);
    expect(clearTimeoutSpy).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(5 * 60_000 + 1);
    expect(vi.getTimerCount()).toBe(0);
    expect(clearTimeoutSpy).toHaveBeenCalledTimes(1);
  });

  it("keeps terminal TTL timers bounded through repeated exact-clear churn", async () => {
    vi.useFakeTimers();
    const clearTimeoutSpy = vi.spyOn(globalThis, "clearTimeout");
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);

    for (let index = 0; index < 12; index += 1) {
      const deliveryId = `delivery-churn-${index}`;
      await controls.send(session(), `Churn ${index}`, [], deliveryId, {
        baselineUserEntryIds: [], baselineComplete: true, submittedText: `Churn ${index}`,
      });
      expect(vi.getTimerCount()).toBe(1);
      controls.clear("session-1", deliveryId);
      expect(vi.getTimerCount()).toBe(0);
    }

    expect(clearTimeoutSpy).toHaveBeenCalledTimes(12);
    await vi.advanceTimersByTimeAsync(5 * 60_000 + 1);
    expect(clearTimeoutSpy).toHaveBeenCalledTimes(12);
  });

  it("fails closed when a terminal PID is reused by a different process instance", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    await sendAndObserve(controls, session(), "First", "delivery-instance-a", "user-a");

    const reusedPID = session({
      controlTarget: {
        kind: "terminal",
        target: { ...target, processStartToken: "start-b" },
      },
    });
    expect(controls.activeCancelDeliveryId(reusedPID)).toBeUndefined();
    await expect(controls.cancel(reusedPID, "delivery-instance-a")).rejects.toThrow("unavailable");
    expect(helper.terminalCancelRequests).toEqual([]);
  });

  it("does not advertise or write terminal actions without a process-instance token", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    const missingToken = session({
      controlTarget: {
        kind: "terminal",
        target: { application: "Ghostty", pid: target.pid, tty: target.tty, cwd: target.cwd },
      },
    });
    await expect(controls.send(missingToken, "must fail", [], "delivery-no-token", {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "must fail",
    })).rejects.toThrow("process identity");
    expect(controls.canCancel(missingToken)).toBe(false);
    expect(helper.terminalSendRequests).toEqual([]);
  });

  it("replaces an old terminal delivery and cannot escape the current target with its ID", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);

    await sendAndObserve(controls, session(), "First", "delivery-a", "user-a");
    const replacementSession = session({ controlTarget: { kind: "terminal", target: replacementTarget } });
    // A target replacement is authoritative only after the control snapshot
    // reconciles the new verified process instance.
    controls.reconcile(replacementSession);
    await sendAndObserve(controls, replacementSession, "Second", "delivery-b", "user-b");
    const current = session({ controlTarget: { kind: "terminal", target: replacementTarget } });
    expect(controls.activeCancelDeliveryId(current)).toBe("delivery-b");
    await expect(controls.cancel(current, "delivery-a")).rejects.toThrow("unavailable");
    await controls.cancel(current, "delivery-b");
    expect(helper.terminalCancelRequests).toEqual([replacementTarget]);
  });

  it("clears the prior terminal delivery when a new send fails", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);

    await sendAndObserve(controls, session(), "First", "delivery-a", "user-a");
    helper.sendTerminal = async () => { throw new Error("terminal disappeared"); };
    await expect(controls.send(session(), "Second", [], "delivery-b")).rejects.toThrow("terminal disappeared");
    // A's confirmed identity remains actionable when queued B fails.
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-a");
    expect(helper.terminalCancelRequests).toEqual([]);
  });

  it("keeps A cancellable while queued B fails, then selects B after B is canonical", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    await sendAndObserve(controls, session(), "First", "delivery-a", "user-a");
    helper.sendTerminal = async (value, text, submit) => {
      helper.terminalSendRequests.push({ target: value, text, submit });
      throw new Error("B failed");
    };
    await expect(controls.send(session(), "Second", [], "delivery-b", {
      baselineUserEntryIds: ["user-a"], baselineComplete: true, submittedText: "Second",
    })).rejects.toThrow("B failed");
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-a");

  });

  it("does not register a queued terminal delivery after its target is replaced", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    let release: (() => void) | undefined;
    const started = new Promise<void>((resolve) => {
      helper.sendTerminal = async (value, text, submit) => {
        helper.terminalSendRequests.push({ target: value, text, submit });
        resolve();
        await new Promise<void>((resume) => { release = resume; });
      };
    });
    const controls = new NativeSessionControls(helper, root);
    const delivery = controls.send(session(), "Working", [], "delivery-pending");
    await started;

    controls.reconcile(session({
      controlTarget: { kind: "terminal", target: replacementTarget },
    }));
    release?.();
    await delivery;

    expect(controls.activeCancelDeliveryId(session({
      controlTarget: { kind: "terminal", target: replacementTarget },
    }))).toBeUndefined();
    expect(helper.terminalCancelRequests).toEqual([]);
  });

  it("forgets one session's control identity and queued state without affecting another", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    const secondSession = session({ id: "session-2" });

    await sendAndObserve(controls, session(), "First", "delivery-a", "user-a");
    await sendAndObserve(controls, secondSession, "Other", "delivery-other", "user-other");
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-a");
    expect(controls.activeCancelDeliveryId(secondSession)).toBe("delivery-other");

    controls.forget("session-1");
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();
    await expect(controls.cancel(session(), "delivery-a")).rejects.toThrow("unavailable");
    expect(controls.activeCancelDeliveryId(secondSession)).toBe("delivery-other");

    // Reusing the session ID starts with a clean generation/target ledger.
    await sendAndObserve(controls, session(), "Replacement", "delivery-new", "user-new");
    expect(controls.activeCancelDeliveryId(session())).toBe("delivery-new");
  });

  it("keeps a deferred operation invalid after tombstone churn and session-ID reuse", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    let release: (() => void) | undefined;
    let started!: () => void;
    const startedPromise = new Promise<void>((resolve) => { started = resolve; });
    helper.sendTerminal = async (value, text, submit) => {
      helper.terminalSendRequests.push({ target: value, text, submit });
      started();
      await new Promise<void>((resolve) => { release = resolve; });
    };
    const controls = new NativeSessionControls(helper, root);
    const deferred = controls.send(session(), "old", [], "old-delivery", {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "old",
    });
    await startedPromise;
    controls.forget("session-1");
    for (let index = 0; index < 513; index += 1) controls.forget(`unrelated-${index}`);
    release?.();
    await expect(deferred).rejects.toThrow("removed");
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();

    // Reusing the ID gets a fresh operation, but the old completion cannot
    // register or mutate its delivery state.
    helper.sendTerminal = async (value, text, submit) => {
      helper.terminalSendRequests.push({ target: value, text, submit });
    };
    await controls.send(session(), "new", [], "new-delivery", {
      baselineUserEntryIds: [], baselineComplete: true, submittedText: "new",
    });
    expect(helper.terminalSendRequests.map(({ text }) => text)).toEqual(["old", "new"]);
    expect(controls.activeCancelDeliveryId(session())).toBeUndefined();
  });

  it("cancels Claude in Terminal through the same verified terminal seam", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);

    const terminalSession = session({
      provider: "claude_code",
      controlTarget: {
        kind: "terminal",
        target: { ...target, application: "Terminal" },
      },
    });
    await sendAndObserve(controls, terminalSession, "Working", "delivery-claude", "user-claude");
    await controls.cancel(terminalSession, "delivery-claude");

    expect(helper.terminalCancelRequests).toEqual([{
      ...target,
      application: "Terminal",
    }]);
  });

  it("uses the Codex turn interrupt seam and fails closed for unsupported sessions", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const codexCalls: string[] = [];
    const codexSends: string[] = [];
    const controls = new NativeSessionControls(
      helper,
      root,
      async (sessionId) => { codexSends.push(sessionId); },
      undefined,
      undefined,
      (sessionId, deliveryId) => { codexCalls.push(`${sessionId}:${deliveryId}`); return true; },
    );

    const codexSession = session({ provider: "codex", messageTransport: "codex_app_server" });
    await controls.send(codexSession, "Working", [], "delivery-codex");
    expect(controls.activeCancelDeliveryId(codexSession)).toBe("delivery-codex");
    await expect(controls.cancel(codexSession, "wrong-delivery")).rejects.toThrow("unavailable");
    await controls.cancel(codexSession, "delivery-codex");
    expect(codexSends).toEqual(["session-1"]);
    expect(codexCalls).toEqual(["session-1:delivery-codex"]);
    expect(helper.terminalCancelRequests).toEqual([]);
    expect(controls.canCancel(codexSession, "delivery-codex")).toBe(false);
    expect(controls.canCancel(session({ section: "ready" }))).toBe(false);
    expect(controls.canCancel(session({ provider: "cursor" }))).toBe(false);
    await expect(controls.cancel(session({ provider: "cursor" }))).rejects.toThrow("unavailable");
  });

  it("rejects malformed attachment metadata before native delivery", async () => {
    const cases: ChatImage[] = [
      image({ byteLength: -1 }),
      image({ byteLength: 1.5 }),
      image({ byteLength: png.byteLength - 1 }),
      image({ data: "not base64" }),
      image({ data: Buffer.from([255, 216, 255]).toString("base64") }),
      image({ mimeType: "image/jpeg" }),
    ];

    for (const attachment of cases) {
      const helper = new FakeNativeHelper();
      const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
      roots.push(root);
      const controls = new NativeSessionControls(helper, root);
      await expect(controls.send(session(), "Review", [attachment])).rejects.toThrow();
      expect(helper.terminalSendRequests).toEqual([]);
    }
  });

  it("rejects unsupported MIME types and payloads over the shared byte cap", async () => {
    const helper = new FakeNativeHelper();
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-controls-test-"));
    roots.push(root);
    const controls = new NativeSessionControls(helper, root);
    const unsupported = image({ mimeType: "image/bmp" as ChatImage["mimeType"] });
    await expect(controls.send(session(), "Review", [unsupported])).rejects.toThrow();

    const oversized = Buffer.alloc(10_000_001);
    oversized[0] = 137;
    oversized[1] = 80;
    oversized[2] = 78;
    oversized[3] = 71;
    oversized[4] = 13;
    oversized[5] = 10;
    oversized[6] = 26;
    oversized[7] = 10;
    await expect(controls.send(session(), "Review", [image({
      byteLength: oversized.byteLength,
      data: oversized.toString("base64"),
    })])).rejects.toThrow();
    expect(helper.terminalSendRequests).toEqual([]);
  });
});
