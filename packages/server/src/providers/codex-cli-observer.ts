import { constants } from "node:fs";
import { open } from "node:fs/promises";
import path from "node:path";
import { isRecord, isVerifiableProcessInstanceToken } from "./shared.js";

/** Observer identity is independent of Desktop's historical transcript metadata. */
export type CodexCliObservation = { version: 1; sessionId: string; pid: number; tty: string; cwd: string;
  home: string; processStartToken: string; observedAt: string; sessionFile?: string; ended: boolean };

export function isCodexCliObservation(value: unknown): value is CodexCliObservation {
  return isRecord(value) && value.version === 1 && typeof value.sessionId === "string"
    && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value.sessionId)
    && typeof value.pid === "number" && isVerifiableProcessInstanceToken(value.pid, typeof value.processStartToken === "string" ? value.processStartToken : undefined)
    && typeof value.tty === "string" && /^(?:\/dev\/)?tty[A-Za-z0-9]+$/.test(value.tty)
    && typeof value.cwd === "string" && path.isAbsolute(value.cwd) && value.cwd.length <= 4096
    && typeof value.home === "string" && path.isAbsolute(value.home) && value.home.length <= 4096
    && typeof value.observedAt === "string" && Number.isFinite(Date.parse(value.observedAt))
    && typeof value.ended === "boolean"
    && (value.sessionFile === undefined || (typeof value.sessionFile === "string" && path.isAbsolute(value.sessionFile)));
}

export async function readCodexCliObservation(pid: number, home: string, files = { open }): Promise<CodexCliObservation | undefined> {
  try {
    const filePath = path.join(home, "agent-visor", "cli", `${pid}.json`);
    const file = await files.open(filePath, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const limit = 16 * 1024;
      const info = await file.stat();
      if (!info.isFile() || info.uid !== process.getuid?.() || info.size > limit || (info.mode & 0o022)) return undefined;
      const raw = Buffer.alloc(limit + 1);
      let size = 0;
      while (size <= limit) {
        const { bytesRead } = await file.read(raw, size, raw.length - size, size);
        if (!bytesRead) break;
        size += bytesRead;
      }
      if (size > limit) return undefined;
      const value: unknown = JSON.parse(raw.subarray(0, size).toString("utf8"));
      return isCodexCliObservation(value) && value.pid === pid && value.home === home ? value : undefined;
    } finally { await file.close(); }
  } catch { return undefined; }
}
