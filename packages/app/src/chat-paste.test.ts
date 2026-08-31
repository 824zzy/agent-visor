import { describe, expect, it, vi } from "vitest";
import {
  composerPasteSnapshotIsCurrent,
  createComposerPasteSnapshot,
  extractComposerPaste,
  hasComposerPastePayload,
  insertComposerTextAtSelection,
  type ClipboardImageItem,
} from "./chat-paste.js";

function imageFile(name = "capture.png", type = "image/png"): File {
  return { name, type, size: 12 } as File;
}

function item(overrides: Partial<ClipboardImageItem>): ClipboardImageItem {
  return {
    kind: "file",
    type: "image/png",
    getAsFile: () => imageFile(),
    ...overrides,
  };
}

describe("composer paste adapter", () => {
  it("uses direct clipboard files when present and keeps only supported images", async () => {
    const image = imageFile();
    const result = await extractComposerPaste({
      files: [image, { name: "notes.txt", type: "text/plain", size: 4 } as File],
      items: [item({ getAsFile: () => imageFile("fallback.png") })],
    });

    expect(result.files).toEqual([image]);
    expect(result.urlCandidates).toEqual([]);
  });

  it("falls back to image item files when the clipboard file list is empty", async () => {
    const png = imageFile("capture.png");
    const tiff = imageFile("capture.tiff", "image/tiff");
    const result = await extractComposerPaste({
      files: [],
      items: [
        item({ getAsFile: () => png }),
        item({ type: "image/tiff", getAsFile: () => tiff }),
      ],
    });

    expect(result.files).toEqual([png, tiff]);
  });

  it("ignores non-image clipboard items", async () => {
    const getAsFile = vi.fn(() => imageFile("not-used.png"));
    const result = await extractComposerPaste({
      files: [],
      items: [
        item({ kind: "string", type: "text/plain", getAsFile }),
        item({ kind: "file", type: "text/plain", getAsFile }),
      ],
    });

    expect(result.files).toEqual([]);
    expect(result.urlCandidates).toEqual([]);
    expect(getAsFile).not.toHaveBeenCalled();
  });

  it("reads one copied local image file URL through the supplied safe reader", async () => {
    const readImageFile = vi.fn(async (url: string) => ({
      name: "capture.png",
      mimeType: "image/png",
      byteLength: 12,
      data: "iVBORw0KGgo=",
      url,
    }));
    const result = await extractComposerPaste({
      files: [],
      items: [{
        kind: "string",
        type: "text/uri-list",
        getAsString: (callback) => callback("# Finder copy\nfile:///tmp/capture.png\n"),
      }],
    }, readImageFile);

    expect(readImageFile).toHaveBeenCalledWith("file:///tmp/capture.png");
    expect(result.urlCandidates).toEqual([{
      name: "capture.png",
      mimeType: "image/png",
      byteLength: 12,
      data: "iVBORw0KGgo=",
    }]);
  });

  it("does not ask the reader to open non-file clipboard URLs", async () => {
    const readImageFile = vi.fn(async () => undefined);
    const result = await extractComposerPaste({
      files: [],
      items: [{
        kind: "string",
        type: "text/plain",
        getAsString: (callback) => callback("https://example.test/capture.png"),
      }],
    }, readImageFile);

    expect(readImageFile).not.toHaveBeenCalled();
    expect(result.urlCandidates).toEqual([]);
  });

  it("preflights text/plain string items and preserves their text when no image is found", async () => {
    const value = "https://example.test/not-an-image";
    const data = {
      files: [],
      items: [{
        kind: "string",
        type: "text/plain",
        getAsString: (callback: (text: string) => void) => callback(value),
      }],
    };

    expect(hasComposerPastePayload(data)).toBe(true);
    await expect(extractComposerPaste(data)).resolves.toMatchObject({
      files: [],
      urlCandidates: [],
      fallbackText: value,
    });
  });

  it("inserts preserved clipboard text at the active composer selection", () => {
    expect(insertComposerTextAtSelection("before after", "middle", 7, 12)).toEqual({
      value: "before middle",
      selectionStart: 13,
      selectionEnd: 13,
    });
  });

  it("preserves item-only multi-URL text and does not read any URL as an image", async () => {
    const value = "file:///tmp/one.png\nhttps://example.test/two.png";
    const readImageFile = vi.fn(async () => undefined);
    const data = {
      files: [],
      items: [{
        kind: "string",
        type: "text/plain",
        getAsString: (callback: (text: string) => void) => callback(value),
      }],
    };

    expect(hasComposerPastePayload(data)).toBe(true);
    await expect(extractComposerPaste(data, readImageFile)).resolves.toMatchObject({
      fallbackText: value,
      urlCandidates: [],
    });
    expect(readImageFile).not.toHaveBeenCalled();
  });

  it("recognizes percent-encoded image extensions before asking the safe reader", async () => {
    const readImageFile = vi.fn(async (url: string) => ({
      name: "capture.png",
      mimeType: "image/png",
      byteLength: 8,
      data: "iVBORw0KGgo=",
      url,
    }));
    const value = "file:///tmp/capture%2Epng";
    const data = {
      files: [],
      items: [{
        kind: "string",
        type: "text/uri-list",
        getAsString: (callback: (text: string) => void) => callback(value),
      }],
    };

    expect(hasComposerPastePayload(data)).toBe(true);
    await extractComposerPaste(data, readImageFile);
    expect(readImageFile).toHaveBeenCalledWith("file:///tmp/capture%2Epng");
  });

  it("resolves async clipboard strings sequentially within one retained-text budget", async () => {
    const calls: string[] = [];
    const oversizedText = "x".repeat(256 * 1_024);
    const readImageFile = vi.fn(async () => undefined);
    const result = await extractComposerPaste({
      files: [],
      items: [
        {
          kind: "string",
          type: "text/plain",
          getAsString: (callback) => { calls.push("first"); callback(oversizedText); },
        },
        {
          kind: "string",
          type: "text/plain",
          getAsString: (callback) => {
            calls.push("second");
            callback("file:///tmp/should-not-read.png");
          },
        },
      ],
    }, readImageFile);

    expect(calls).toEqual(["first"]);
    expect(result.fallbackText).toHaveLength(256 * 1_024);
    expect(readImageFile).not.toHaveBeenCalled();
  });

  it("invalidates a deferred paste after typing, moving selection, or switching sessions", () => {
    const draft = { text: "before", images: [] };
    const snapshot = createComposerPasteSnapshot("first", draft, {
      value: "before",
      selectionStart: 6,
      selectionEnd: 6,
    });
    const currentInput = { value: "before", selectionStart: 6, selectionEnd: 6 };

    expect(composerPasteSnapshotIsCurrent(snapshot, "first", draft, currentInput)).toBe(true);
    expect(composerPasteSnapshotIsCurrent(snapshot, "first", { ...draft, text: "typed" }, currentInput)).toBe(false);
    expect(composerPasteSnapshotIsCurrent(snapshot, "first", draft, {
      ...currentInput, selectionStart: 2, selectionEnd: 2,
    })).toBe(false);
    expect(composerPasteSnapshotIsCurrent(snapshot, "second", draft, currentInput)).toBe(false);
  });

  it("waits for one deferred string callback without inserting until it resolves", async () => {
    let release: ((value: string) => void) | undefined;
    const pending = extractComposerPaste({
      files: [],
      items: [{
        kind: "string",
        type: "text/plain",
        getAsString: (callback) => { release = callback; },
      }],
    });
    let settled = false;
    void pending.then(() => { settled = true; });
    await Promise.resolve();
    expect(settled).toBe(false);
    release?.("preserved text");
    await expect(pending).resolves.toMatchObject({ fallbackText: "preserved text" });
  });

  it("falls through non-image files to an image item", async () => {
    const pasted = imageFile("fallback.png");
    const result = await extractComposerPaste({
      files: [{ name: "notes.txt", type: "text/plain", size: 4 } as File],
      items: [item({ getAsFile: () => pasted })],
    });

    expect(result.files).toEqual([pasted]);
  });

  it("accepts a text/plain-only local URL when synchronous clipboard data is available", async () => {
    const readImageFile = vi.fn(async (url: string) => ({
      name: "capture.tiff", mimeType: "image/tiff", byteLength: 4, data: "SUkqAA==", url,
    }));
    const data = {
      files: [],
      items: [{ kind: "string", type: "text/plain" }],
      getData: (type: string) => type === "text/plain" ? "file:///tmp/capture.tiff" : "",
    };

    expect(hasComposerPastePayload(data)).toBe(true);
    await expect(extractComposerPaste(data, readImageFile)).resolves.toMatchObject({
      urlCandidates: [{ name: "capture.tiff", mimeType: "image/tiff" }],
    });
  });

  it("preserves multi-URL text instead of consuming it as an image paste", async () => {
    const readImageFile = vi.fn(async () => undefined);
    const data = {
      files: [],
      items: [{ kind: "string", type: "text/plain" }],
      getData: (type: string) => type === "text/plain"
        ? "file:///tmp/one.png\nfile:///tmp/two.png" : "",
    };

    expect(hasComposerPastePayload(data)).toBe(false);
    await expect(extractComposerPaste(data, readImageFile)).resolves.toEqual({ files: [], urlCandidates: [] });
    expect(readImageFile).not.toHaveBeenCalled();
  });

  it("bounds image item materialization before calling getAsFile", async () => {
    let calls = 0;
    const items = Array.from({ length: 100 }, () => item({
      getAsFile: () => {
        calls += 1;
        return imageFile();
      },
    }));

    const result = await extractComposerPaste({ files: [], items });

    expect(result.files).toHaveLength(64);
    expect(calls).toBe(64);
  });
});
