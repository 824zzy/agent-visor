import { describe, expect, it } from "vitest";
import {
  chatImageBase64Bytes,
  chatImageBytesMatchMime,
  chatImageMimeForBytes,
} from "./index.js";

const fixtures: Record<string, Uint8Array> = {
  "image/png": Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]),
  "image/jpeg": Uint8Array.from([255, 216, 255, 224]),
  "image/gif": Uint8Array.from([71, 73, 70, 56, 57, 97]),
  "image/webp": Uint8Array.from([82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80]),
  "image/tiff": Uint8Array.from([73, 73, 42, 0]),
  "image/heic": Uint8Array.from([0, 0, 0, 0, 102, 116, 121, 112, 104, 101, 105, 99]),
};

describe("shared image byte policy", () => {
  it("accepts realistic signatures for each supported MIME", () => {
    for (const [mime, bytes] of Object.entries(fixtures)) {
      expect(chatImageBytesMatchMime(mime, bytes)).toBe(true);
    }
  });

  it("rejects empty, truncated, and mismatched content", () => {
    expect(chatImageBytesMatchMime("image/png", new Uint8Array())).toBe(false);
    expect(chatImageBytesMatchMime("image/png", fixtures["image/png"]!.slice(0, 4))).toBe(false);
    expect(chatImageBytesMatchMime("image/png", fixtures["image/jpeg"]!)).toBe(false);
    expect(chatImageBytesMatchMime("image/bmp", fixtures["image/png"]!)).toBe(false);
  });

  it("decodes only bounded canonical base64 and infers supported MIME", () => {
    const rawPng = Buffer.from(fixtures["image/png"]!).toString("base64");
    const bytes = chatImageBase64Bytes(rawPng);
    expect(bytes).toEqual(fixtures["image/png"]);
    expect(chatImageMimeForBytes(bytes!)).toBe("image/png");
    expect(chatImageBase64Bytes("not base64")).toBeUndefined();
    expect(chatImageBase64Bytes(`${rawPng}A`)).toBeUndefined();
  });
});
