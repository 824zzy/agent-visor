import { open, type FileHandle } from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  CHAT_IMAGE_MAX_BYTES,
  CHAT_IMAGE_SUPPORTED_MIME_TYPES,
  chatImageBytesMatchMime,
} from "@agent-visor/protocol";

export type ImageFileSystem = {
  open(path: string, flags: number): Promise<ImageFileHandle>;
};

export type ImageFileHandle = Pick<FileHandle, "stat" | "read" | "close">;

export type ImageFilePayload = {
  name: string;
  mimeType: string;
  byteLength: number;
  data: string;
};

const fileSystem: ImageFileSystem = { open };
const mimeByExtension: Readonly<Record<string, string>> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".tif": "image/tiff",
  ".tiff": "image/tiff",
  ".heic": "image/heic",
};

/** Read only local image files exposed by Finder-style clipboard URLs. */
export async function readImageFileURL(
  value: unknown,
  fs: ImageFileSystem = fileSystem,
): Promise<ImageFilePayload | undefined> {
  const filePath = localFilePath(value);
  if (!filePath) return undefined;
  const mimeType = mimeByExtension[path.extname(filePath).toLowerCase()];
  if (!mimeType || !(CHAT_IMAGE_SUPPORTED_MIME_TYPES as readonly string[]).includes(mimeType)) {
    return undefined;
  }

  let handle: ImageFileHandle;
  const flags = constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0);
  try { handle = await fs.open(filePath, flags); } catch { return undefined; }
  try {
    const metadata = await handle.stat();
    if (!metadata.isFile() || !Number.isFinite(metadata.size) || !Number.isInteger(metadata.size)
      || metadata.size < 0 || metadata.size > CHAT_IMAGE_MAX_BYTES) {
      return undefined;
    }
    // ponytail: if the shared image byte cap changes, keep this bounded
    // cap+1 read so a growing file cannot cross the IPC boundary.
    const bytes = Buffer.alloc(metadata.size + 1);
    let bytesRead = 0;
    while (bytesRead < bytes.length) {
      const result = await handle.read(bytes, bytesRead, bytes.length - bytesRead, bytesRead);
      if (!Number.isInteger(result.bytesRead) || result.bytesRead <= 0
        || result.bytesRead > bytes.length - bytesRead) break;
      bytesRead += result.bytesRead;
    }
    const finalMetadata = await handle.stat();
    if (bytesRead !== metadata.size || !finalMetadata.isFile()
      || finalMetadata.size !== metadata.size) return undefined;
    const imageBytes = bytes.subarray(0, metadata.size);
    if (!chatImageBytesMatchMime(mimeType, imageBytes)) return undefined;
    return {
      name: path.basename(filePath),
      mimeType,
      byteLength: bytesRead,
      data: imageBytes.toString("base64"),
    };
  } catch {
    return undefined;
  } finally {
    try { await handle.close(); } catch { /* the OS closes failed handles */ }
  }
}

function localFilePath(value: unknown): string | undefined {
  if (typeof value !== "string" || !value) return undefined;
  let url: URL;
  try { url = new URL(value); } catch { return undefined; }
  if (url.protocol !== "file:" || (url.hostname && url.hostname !== "localhost")
    || url.username || url.password || url.search || url.hash) return undefined;
  try {
    const filePath = fileURLToPath(url);
    return path.isAbsolute(filePath) ? filePath : undefined;
  } catch { return undefined; }
}
