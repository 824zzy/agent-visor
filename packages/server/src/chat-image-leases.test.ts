import { mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { ChatImage } from "@agent-visor/protocol";
import {
  CHAT_IMAGE_LEASE_TTL_MS,
  ChatImageLeaseStore,
  MAX_CHAT_IMAGE_LEASE_BYTES,
} from "./chat-image-leases.js";

const roots: string[] = [];
const pngBytes = Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]);

function image(bytes = pngBytes, name = "one.png"): ChatImage {
  return {
    name,
    mimeType: "image/png",
    byteLength: bytes.byteLength,
    data: Buffer.from(bytes).toString("base64"),
  };
}

function scope(overrides: Partial<{
  sessionId: string;
  generation: number;
  requestId: string;
  deliveryId: string;
}> = {}) {
  return {
    sessionId: "session-a",
    generation: 1,
    requestId: "request-a",
    deliveryId: "delivery-a",
    ...overrides,
  };
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("ChatImageLeaseStore", () => {
  it("materializes one exact delivery and releases its files on canonical cleanup", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-image-lease-"));
    roots.push(root);
    const store = new ChatImageLeaseStore({ root, ttlMs: 60_000 });
    const materialized = await store.materialize(scope(), [image()]);

    expect(materialized.paths).toHaveLength(1);
    expect(await readFile(materialized.paths[0]!)).toEqual(Buffer.from(pngBytes));
    expect((await stat(materialized.paths[0]!)).mode & 0o777).toBe(0o600);
    expect(store.get(scope())).toMatchObject({ bytes: pngBytes.byteLength, state: "active" });

    store.markAwaitingCanonical(scope());
    await store.release(scope());
    await expect(readdir(root)).resolves.toEqual([]);
    expect(store.recordCount).toBe(0);
  });

  it("rejects aggregate byte capacity before the writer runs", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-image-lease-"));
    roots.push(root);
    let writes = 0;
    const store = new ChatImageLeaseStore({
      root,
      maxBytes: pngBytes.byteLength,
      writeFile: async () => { writes += 1; },
    });
    await store.materialize(scope(), [image()]);

    await expect(store.materialize(scope({ deliveryId: "delivery-b" }), [image()]))
      .rejects.toThrow(/byte capacity/i);
    expect(writes).toBe(1);
    expect(store.recordCount).toBe(1);
  });

  it("does not delete another delivery when filenames collide", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-image-lease-"));
    roots.push(root);
    const writes: string[] = [];
    const store = new ChatImageLeaseStore({
      root,
      writeFile: async (file, data) => {
        writes.push(file);
        await import("node:fs/promises").then(({ writeFile }) => writeFile(file, data, { flag: "wx" }));
      },
    });
    const first = await store.materialize(scope(), [image()]);
    const second = await store.materialize(scope({ deliveryId: "delivery-b" }), [image()]);
    expect(first.paths[0]).not.toBe(second.paths[0]);
    await store.release(scope());
    await expect(stat(second.paths[0]!)).resolves.toBeDefined();
    expect(writes).toHaveLength(2);
  });

  it("expires an awaiting canonical lease through the explicit clock hook", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-image-lease-"));
    roots.push(root);
    let now = 100;
    const store = new ChatImageLeaseStore({ root, now: () => now, ttlMs: CHAT_IMAGE_LEASE_TTL_MS });
    const materialized = await store.materialize(scope(), [image()]);
    store.markAwaitingCanonical(scope());
    now += CHAT_IMAGE_LEASE_TTL_MS;
    await store.expire();
    expect(store.recordCount).toBe(0);
    await expect(stat(materialized.paths[0]!)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("forgets only the requested session and generation", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-image-lease-"));
    roots.push(root);
    const store = new ChatImageLeaseStore({ root });
    const a = await store.materialize(scope(), [image()]);
    const b = await store.materialize(scope({ sessionId: "session-b" }), [image(pngBytes, "two.png")]);
    const old = await store.materialize(scope({ generation: 0, deliveryId: "delivery-old" }), [image(pngBytes, "old.png")]);
    await store.replaceGeneration("session-a", 1);
    expect(store.has(scope())).toBe(true);
    expect(store.has(scope({ sessionId: "session-b" }))).toBe(true);
    expect(store.has(scope({ generation: 0, deliveryId: "delivery-old" }))).toBe(false);
    await expect(stat(b.paths[0]!)).resolves.toBeDefined();
    await expect(stat(a.paths[0]!)).resolves.toBeDefined();
    await expect(stat(old.paths[0]!)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("does not admit a second record when the record cap is full", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-image-lease-"));
    roots.push(root);
    let writes = 0;
    const store = new ChatImageLeaseStore({
      root,
      maxRecords: 1,
      maxBytes: MAX_CHAT_IMAGE_LEASE_BYTES,
      writeFile: async () => { writes += 1; },
    });
    await store.materialize(scope(), [image()]);
    await expect(store.materialize(scope({ deliveryId: "delivery-b" }), [image()]))
      .rejects.toThrow(/capacity is full/i);
    expect(writes).toBe(1);
  });

  it("keeps a blocked materialization owned until release cleans its late path", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-image-lease-"));
    roots.push(root);
    let unblock!: () => void;
    let started!: () => void;
    const writeStarted = new Promise<void>((resolve) => { started = resolve; });
    const writeGate = new Promise<void>((resolve) => { unblock = resolve; });
    const store = new ChatImageLeaseStore({
      root,
      writeFile: async (file, data) => {
        await writeFile(file, data, { flag: "wx" });
        started();
        await writeGate;
      },
    });

    const materializing = store.materialize(scope(), [image()]);
    await writeStarted;
    expect(store.recordCount).toBe(1);
    expect(store.retainedBytes).toBe(pngBytes.byteLength);
    const releasing = store.release(scope());
    expect(store.recordCount).toBe(1);
    unblock();

    await expect(materializing).rejects.toThrow(/released|cancelled/i);
    await expect(releasing).resolves.toBe(true);
    expect(store.recordCount).toBe(0);
    await expect(readdir(root)).resolves.toEqual([]);
  });

  it("cleans a partially written multi-image delivery without returning an orphan", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-image-lease-"));
    roots.push(root);
    let writes = 0;
    const store = new ChatImageLeaseStore({
      root,
      writeFile: async (file, data) => {
        writes += 1;
        await writeFile(file, data, { flag: "wx" });
        if (writes === 2) throw new Error("second image write failed");
      },
    });

    await expect(store.materialize(scope(), [image(), image(pngBytes, "two.png")]))
      .rejects.toThrow("second image write failed");
    expect(store.recordCount).toBe(0);
    await expect(readdir(root)).resolves.toEqual([]);
  });

  it("retains cleanup-pending bytes after a delete failure and retries by clock", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-image-lease-"));
    roots.push(root);
    let now = 100;
    let removeAttempts = 0;
    const store = new ChatImageLeaseStore({
      root,
      now: () => now,
      removeFile: async (file) => {
        removeAttempts += 1;
        if (removeAttempts === 1) throw new Error("temporary cleanup failure");
        await rm(file, { force: true });
      },
    });
    await store.materialize(scope(), [image()]);

    await expect(store.release(scope())).resolves.toBe(false);
    expect(store.recordCount).toBe(1);
    expect(store.retainedBytes).toBe(pngBytes.byteLength);
    now += 1_000;
    await store.expire();
    expect(removeAttempts).toBe(2);
    expect(store.recordCount).toBe(0);
    expect(store.retainedBytes).toBe(0);
    await expect(readdir(root)).resolves.toEqual([]);
  });

  it("keeps persistent cleanup failure bounded and accounted against capacity", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-image-lease-"));
    roots.push(root);
    const store = new ChatImageLeaseStore({
      root,
      maxRecords: 1,
      removeFile: async () => { throw new Error("persistent cleanup failure"); },
    });
    await store.materialize(scope(), [image()]);

    await expect(store.release(scope())).resolves.toBe(false);
    expect(store.recordCount).toBe(1);
    expect(store.retainedBytes).toBe(pngBytes.byteLength);
    await expect(store.materialize(scope({ deliveryId: "delivery-b" }), [image()]))
      .rejects.toThrow(/capacity is full/i);
  });
});
