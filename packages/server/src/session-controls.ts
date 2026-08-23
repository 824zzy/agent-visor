import { randomUUID } from "node:crypto";
import { mkdir, readdir, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { ChatImage } from "@agent-visor/protocol";
import { sendCodexTurn, type CodexActionRegistrar } from "./codex-turn.js";
import type { NativeHelperAdapter } from "./native-helper.js";
import type { DiscoveredProviderSession, SessionControls } from "./sessions.js";

export class NativeSessionControls implements SessionControls {
  private focusQueue = Promise.resolve();
  private focusSerial = 0;
  private sendQueue = Promise.resolve();

  constructor(
    private readonly helper: NativeHelperAdapter,
    private readonly imageRoot = path.join(os.tmpdir(), `agent-visor-images-${process.getuid?.() ?? 0}`),
    private readonly sendCodex = sendCodexTurn,
    private readonly openURL: (url: string) => Promise<void> = async () => {
      throw new Error("Exact application focus is unavailable.");
    },
    private readonly registerCodexAction?: CodexActionRegistrar,
  ) {}

  focus(session: DiscoveredProviderSession): Promise<void> {
    const serial = ++this.focusSerial;
    const operation = this.focusQueue.then(async () => {
      if (serial !== this.focusSerial) return;
      const control = session.controlTarget;
      if (!control) throw new Error("Exact session focus is unavailable.");
      if (control.kind === "url") await this.openURL(control.url);
      else if (control.kind === "terminal") await this.helper.focusTerminal(control.target);
      else await this.helper.focus(control.target);
    });
    this.focusQueue = operation.then(() => undefined, () => undefined);
    return operation;
  }

  send(session: DiscoveredProviderSession, text: string, images: ChatImage[]): Promise<void> {
    const operation = this.sendQueue.then(() => this.deliver(session, text, images));
    this.sendQueue = operation.then(() => undefined, () => undefined);
    return operation;
  }

  private async deliver(
    session: DiscoveredProviderSession,
    text: string,
    images: ChatImage[],
  ): Promise<void> {
    if (!text && !images.length) throw new Error("The message is empty.");
    const imagePaths = await this.storeImages(images);
    if (session.messageTransport === "codex_app_server") {
      await this.sendCodex(session.id, text, imagePaths, this.registerCodexAction);
      return;
    }
    if (session.messageTransport !== "terminal" || session.controlTarget?.kind !== "terminal") {
      throw new Error("Native message delivery is unavailable for this session.");
    }

    const target = session.controlTarget.target;
    if (session.provider === "claude_code") {
      if (imagePaths.length && target.application === "Terminal") {
        throw new Error("Claude image delivery is unavailable in Terminal.");
      }
      for (const imagePath of imagePaths) {
        await this.helper.sendTerminal(target, imagePath, false);
        await new Promise((resolve) => setTimeout(resolve, 120));
      }
      await this.helper.sendTerminal(target, text, true);
      return;
    }
    const prompt = session.provider === "pi"
      ? [text, ...imagePaths].filter(Boolean).join("\n")
      : text;
    await this.helper.sendTerminal(target, prompt, true);
  }

  async close(): Promise<void> {
    await rm(this.imageRoot, { recursive: true, force: true });
  }

  private async storeImages(images: ChatImage[]): Promise<string[]> {
    if (!images.length) return [];
    await mkdir(this.imageRoot, { recursive: true, mode: 0o700 });
    await cleanup(this.imageRoot);
    return Promise.all(images.map(async (image) => {
      if (!image.data || image.data.length % 4 !== 0
        || !/^[A-Za-z0-9+/]*={0,2}$/.test(image.data)) {
        throw new Error("An image has invalid content.");
      }
      const data = Buffer.from(image.data, "base64");
      if (!data.length || data.length > 10 * 1_048_576) {
        throw new Error("Each image must contain at most 10 MB.");
      }
      const extension = {
        "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
      }[image.mimeType];
      const file = path.join(this.imageRoot, `${randomUUID()}.${extension}`);
      await writeFile(file, data, { mode: 0o600, flag: "wx" });
      return file;
    }));
  }
}

async function cleanup(root: string): Promise<void> {
  const cutoff = Date.now() - 60 * 60_000;
  for (const name of await readdir(root)) {
    const file = path.join(root, name);
    try {
      if ((await stat(file)).mtimeMs < cutoff) await rm(file, { force: true });
    } catch { /* another cleanup removed it */ }
  }
}
