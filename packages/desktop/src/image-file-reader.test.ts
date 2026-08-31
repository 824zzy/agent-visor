import { describe, expect, it } from "vitest";
import { readImageFileURL, type ImageFileSystem } from "./image-file-reader.js";

function fileSystem(options: {
  size?: number;
  isFile?: boolean;
  data?: Uint8Array;
  readSize?: number;
  openError?: Error;
} = {}): ImageFileSystem {
  const data = options.data ?? Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]);
  return {
    open: async (_path, flags) => {
      if (options.openError) throw options.openError;
      return {
        stat: async () => ({ size: options.size ?? data.byteLength, isFile: () => options.isFile ?? true }),
        read: async (buffer, offset, length, position) => {
          const readSize = options.readSize ?? Math.min(Math.max(data.byteLength - position, 0), length);
          buffer.set(data.subarray(position, position + readSize), offset);
          return { bytesRead: readSize, buffer };
        },
        close: async () => undefined,
      };
    },
  };
}

describe("safe image file URL reader", () => {
  it("reads a local PNG file URL into a renderer attachment payload", async () => {
    await expect(readImageFileURL("file:///tmp/capture.png", fileSystem())).resolves.toEqual({
      name: "capture.png",
      mimeType: "image/png",
      byteLength: 8,
      data: "iVBORw0KGgo=",
    });
  });

  it("accepts TIFF copied-file URLs using the shared image policy", async () => {
    await expect(readImageFileURL("file:///tmp/capture.tiff", fileSystem({
      data: Uint8Array.from([73, 73, 42, 0]),
    }))).resolves.toMatchObject({
      name: "capture.tiff",
      mimeType: "image/tiff",
    });
  });

  it("rejects non-file schemes and unsupported file types before stat", async () => {
    let openCalls = 0;
    const fs = fileSystem();
    const guarded: ImageFileSystem = {
      ...fs,
      open: async (...args) => {
        openCalls += 1;
        return fs.open(...args);
      },
    };

    await expect(readImageFileURL("https://example.test/capture.png", guarded)).resolves.toBeUndefined();
    await expect(readImageFileURL("file:///tmp/notes.txt", guarded)).resolves.toBeUndefined();
    expect(openCalls).toBe(0);
  });

  it("rejects directories and oversized images before reading bytes", async () => {
    let readLength = 0;
    const fs = fileSystem({ size: 10_000_001, isFile: true });
    const guarded: ImageFileSystem = {
      ...fs,
      open: async (...args) => {
        const handle = await fs.open(...args);
        return {
          ...handle,
          read: async (buffer, offset, length, position) => {
            readLength = length;
            return handle.read(buffer, offset, length, position);
          },
        };
      },
    };
    await expect(readImageFileURL("file:///tmp/large.png", guarded)).resolves.toBeUndefined();
    expect(readLength).toBe(0);

    await expect(readImageFileURL("file:///tmp/directory.png", fileSystem({ isFile: false })))
      .resolves.toBeUndefined();
  });

  it("reads through one open handle with a cap-plus-one bound and rejects growth", async () => {
    let readLength = 0;
    const data = Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]);
    const fs = fileSystem({ data, size: data.byteLength });
    const growing: ImageFileSystem = {
      open: async (...args) => {
        const handle = await fs.open(...args);
        return {
          ...handle,
          stat: async () => ({ size: 4, isFile: () => true }),
          read: async (buffer, offset, length, position) => {
            readLength = length;
            return { bytesRead: length, buffer };
          },
        };
      },
    };
    await expect(readImageFileURL("file:///tmp/growing.png", growing)).resolves.toBeUndefined();
    expect(readLength).toBe(5);
  });

  it("rejects symlinks and extension/signature mismatches", async () => {
    await expect(readImageFileURL("file:///tmp/link.png", fileSystem({
      openError: Object.assign(new Error("symlink"), { code: "ELOOP" }),
    }))).resolves.toBeUndefined();
    await expect(readImageFileURL("file:///tmp/not-png.png", fileSystem({
      data: Uint8Array.from([255, 216, 255, 224]),
    }))).resolves.toBeUndefined();
  });
});
