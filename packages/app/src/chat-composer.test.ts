import { describe, expect, it } from "vitest";
import type { ChatImage, ChatSlashCommand } from "@agent-visor/protocol";
import {
  addComposerAttachments,
  applyComposerRecoveryCommand,
  appendComposerAttachments,
  composerKeyAction,
  composerEscapeAction,
  composerLayoutForContent,
  COMPOSER_MAX_FILE_SELECTION,
  COMPOSER_MAX_TEXT_BYTES,
  COMPOSER_MAX_TEXT_LENGTH,
  createComposerAttachmentOperations,
  createComposerDraftStore,
  composerDraftFromSubmitted,
  composerDraftToSubmitted,
  draftSubmission,
  preflightComposerFiles,
  validateComposerText,
  composerTextByteLength,
  filterSlashCommands,
  slashQuery,
  type ComposerAttachmentCandidate,
  type ComposerDraft,
} from "./chat-composer.js";

function image(name: string, byteLength = 8): ComposerAttachmentCandidate {
  return {
    name,
    mimeType: "image/png",
    byteLength,
    data: "iVBORw0KGgo=",
  };
}

function attachment(name: string, byteLength = 12) {
  return { ...image(name, byteLength), id: name, mimeType: "image/png" as const };
}

function command(
  name: string,
  overrides: Partial<ChatSlashCommand> = {},
): ChatSlashCommand {
  return {
    name,
    aliases: [],
    description: `${name} description`,
    source: "builtin",
    isHidden: false,
    opensInTerminalDialog: false,
    ...overrides,
    argNames: overrides.argNames ?? [],
  };
}

describe("composer draft store", () => {
  it("keeps independent drafts, including attachments, by session", () => {
    const store = createComposerDraftStore();
    const first: ComposerDraft = { text: "first", images: [attachment("one.png")] };
    store.save("session-one", first);
    store.save("session-two", { text: "second", images: [] });

    expect(store.load("session-one")).toEqual(first);
    expect(store.load("session-two")).toEqual({ text: "second", images: [] });
    expect(store.load("missing")).toEqual({ text: "", images: [] });

    first.images[0]!.name = "mutated outside the store";
    expect(store.load("session-one").images[0]!.name).toBe("one.png");
  });

  it("deletes an empty draft so remount restore is deterministic", () => {
    const store = createComposerDraftStore();
    store.save("session", { text: "draft", images: [] });
    store.save("session", { text: "", images: [] });
    expect(store.load("session")).toEqual({ text: "", images: [] });
  });

  it("atomically restores an exact submitted snapshot with attachment identity", () => {
    const store = createComposerDraftStore();
    const submitted = {
      text: "retry me",
      images: [{ name: "diagram.png", mimeType: "image/png" as const, data: "iVBORw0KGgo=", byteLength: 8 }],
    };
    const current = composerDraftFromSubmitted({ text: "", images: [] });
    store.save("session", current);

    const result = applyComposerRecoveryCommand(store, "session", current, 4, {
      id: "restore-1",
      type: "restore",
      draft: submitted,
      expectedComposer: { draft: { text: "", images: [] }, revision: 4 },
      expectedRevision: 4,
    });

    expect(result.status).toBe("applied");
    expect(result.draft.text).toBe("retry me");
    expect(result.draft.images[0]?.id).toBe("recovered-0-diagram.png");
    expect(composerDraftToSubmitted(store.load("session"))).toEqual(submitted);
  });

  it("preserves a newer draft and rejects a stale restore revision", () => {
    const store = createComposerDraftStore();
    const newer = composerDraftFromSubmitted({ text: "newer edit", images: [] });
    store.save("session", newer);

    const result = applyComposerRecoveryCommand(store, "session", newer, 7, {
      id: "restore-2",
      type: "restore",
      draft: { text: "old", images: [] },
      expectedComposer: { draft: { text: "", images: [] }, revision: 4 },
      expectedRevision: 4,
    });

    expect(result).toMatchObject({ status: "preserved", reason: "newer-draft" });
    expect(store.load("session")).toEqual(newer);
  });

  it("clears only when retry still owns the exact composer snapshot", () => {
    const store = createComposerDraftStore();
    const draft = composerDraftFromSubmitted({ text: "retry me", images: [] });
    store.save("session", draft);

    const applied = applyComposerRecoveryCommand(store, "session", draft, 5, {
      id: "clear-1",
      type: "clear",
      draft: { text: "retry me", images: [] },
      expectedComposer: { text: "retry me", images: [] },
    });
    expect(applied.status).toBe("applied");
    expect(store.load("session")).toEqual({ text: "", images: [] });

    const newer = composerDraftFromSubmitted({ text: "newer", images: [] });
    store.save("session", newer);
    const preserved = applyComposerRecoveryCommand(store, "session", newer, 6, {
      id: "clear-2",
      type: "clear",
      draft: { text: "retry me", images: [] },
      expectedComposer: { text: "retry me", images: [] },
    });
    expect(preserved).toMatchObject({ status: "preserved", reason: "newer-draft" });
    expect(store.load("session")).toEqual(newer);
  });
});

describe("composer keyboard policy", () => {
  it("submits on plain Enter and inserts a newline on Shift+Enter", () => {
    expect(composerKeyAction({ key: "Enter", shiftKey: false })).toBe("submit");
    expect(composerKeyAction({ key: "Enter", shiftKey: true })).toBe("newline");
  });

  it("does not submit while an IME composition is active", () => {
    expect(composerKeyAction({ key: "Enter", shiftKey: false, isComposing: true })).toBe("ignore");
    expect(composerKeyAction({ key: "Enter", shiftKey: false, keyCode: 229 })).toBe("ignore");
  });

  it("closes slash suggestions first, then clears the complete draft", () => {
    expect(composerEscapeAction(true)).toBe("close_suggestions");
    expect(composerEscapeAction(false)).toBe("clear_draft");
  });
});

describe("composer sizing policy", () => {
  it("uses visual measured height and scrolls internally after eight lines", () => {
    const eight = composerLayoutForContent({ contentHeight: 172, lineHeight: 19, verticalPadding: 20 });
    expect(eight).toMatchObject({ height: 172, visualLineCount: 8, scrollable: false });

    const ten = composerLayoutForContent({ contentHeight: 210, lineHeight: 19, verticalPadding: 20 });
    expect(ten).toMatchObject({ height: 172, visualLineCount: 10, scrollable: true });
  });
});

describe("composer text policy", () => {
  it("rejects text beyond the shared UTF-16 send limit", () => {
    const text = "x".repeat(COMPOSER_MAX_TEXT_LENGTH + 1);
    expect(validateComposerText(text)).toMatchObject({ code: "text_too_long" });
    expect(draftSubmission({ text, images: [] })).toBeUndefined();
  });

  it("enforces terminal limits by UTF-8 bytes while preserving Codex's UTF-16 limit", () => {
    const ascii = "x".repeat(COMPOSER_MAX_TEXT_BYTES);
    expect(composerTextByteLength(ascii)).toBe(COMPOSER_MAX_TEXT_BYTES);
    expect(validateComposerText(ascii, COMPOSER_MAX_TEXT_BYTES)).toBeUndefined();
    expect(validateComposerText(`${ascii}x`, COMPOSER_MAX_TEXT_BYTES)).toMatchObject({ code: "text_too_long" });
    expect(draftSubmission({ text: `${ascii}x`, images: [] }, COMPOSER_MAX_TEXT_BYTES)).toBeUndefined();

    const multibyte = "😀".repeat(COMPOSER_MAX_TEXT_BYTES / 4);
    expect(composerTextByteLength(multibyte)).toBe(COMPOSER_MAX_TEXT_BYTES);
    expect(validateComposerText(multibyte, COMPOSER_MAX_TEXT_BYTES)).toBeUndefined();
    expect(validateComposerText(`${multibyte}x`, COMPOSER_MAX_TEXT_BYTES)).toMatchObject({ code: "text_too_long" });
    // No provider cap means the Codex/global UTF-16 policy remains in force.
    expect(validateComposerText("😀".repeat(COMPOSER_MAX_TEXT_LENGTH / 2))).toBeUndefined();
  });
});

describe("composer attachment validation", () => {
  it("preflights file metadata and only returns files safe to read", () => {
    const result = preflightComposerFiles([
      { name: "ok.png", type: "image/png", size: 8 } as File,
      { name: "bad.bmp", type: "image/bmp", size: 8 } as File,
      { name: "large.png", type: "image/png", size: 10_000_001 } as File,
      { name: "fractional.png", type: "image/png", size: 1.5 } as File,
    ], 9);

    expect(result.accepted.map(({ name }) => name)).toEqual(["ok.png"]);
    expect(result.errors.map(({ code }) => code)).toEqual([
      "unsupported_type", "too_large", "invalid_content",
    ]);
  });

  it("bounds picker metadata iteration before any FileReader work", () => {
    let yielded = 0;
    const files = {
      *[Symbol.iterator]() {
        while (yielded < 100) {
          yielded += 1;
          yield { name: `image-${yielded}.png`, type: "image/png", size: 8 } as File;
        }
      },
    };

    const result = preflightComposerFiles(files, 0);

    expect(yielded).toBe(COMPOSER_MAX_FILE_SELECTION);
    expect(result.accepted).toHaveLength(10);
    expect(result.errors.every(({ code }) => code === "too_many")).toBe(true);
  });

  it("accepts supported images and reports unsupported or oversized files", () => {
    const result = addComposerAttachments({ text: "", images: [] }, [
      image("ok.png"),
      { ...image("bad.bmp"), mimeType: "image/bmp" },
      { ...image("large.png"), byteLength: 10_000_001 },
    ]);

    expect(result.draft.images).toHaveLength(1);
    expect(result.errors.map(({ code }) => code)).toEqual(["unsupported_type", "too_large"]);
  });

  it("rejects candidates beyond the existing ten-image send limit", () => {
    const existing: ComposerDraft = {
      text: "",
      images: Array.from({ length: 10 }, (_, index) => ({
        ...attachment(`existing-${index}.png`),
      })),
    };
    const result = addComposerAttachments(existing, [image("eleventh.png")]);
    expect(result.draft.images).toHaveLength(10);
    expect(result.errors[0]?.code).toBe("too_many");
  });

  it("rejects malformed metadata, base64, and image content before storing a preview", () => {
    const result = addComposerAttachments({ text: "", images: [] }, [
      image("negative.png", -1),
      image("fractional.png", 1.5),
      image("mismatch.png", 7),
      { ...image("bad-base64.png"), data: "not base64" },
      { ...image("wrong-signature.png"), data: "/9j/4A==" },
    ]);

    expect(result.draft.images).toEqual([]);
    expect(result.errors.map(({ code }) => code)).toEqual([
      "invalid_content", "invalid_content", "invalid_content", "invalid_content", "invalid_content",
    ]);
  });

  it("trims text for send but keeps image-only submissions valid", () => {
    expect(draftSubmission({ text: "  hello \n", images: [] })).toEqual({ text: "hello", images: [] });
    expect(draftSubmission({ text: "  ", images: [attachment("one.png")] })).toMatchObject({ text: "" });
    expect(draftSubmission({ text: "  ", images: [] })).toBeUndefined();
  });

  it("appends a late file read to the latest persisted draft", async () => {
    const store = createComposerDraftStore();
    store.save("session", { text: "before", images: [] });
    let release: () => void = () => undefined;
    const read = new Promise<void>((resolve) => { release = resolve; });
    const lateAppend = read.then(() => appendComposerAttachments(store, "session", [image("late.png")]));

    store.save("session", { text: "latest", images: [attachment("new.png")] });
    release();
    await lateAppend;

    expect(store.load("session")).toMatchObject({
      text: "latest",
      images: [{ name: "new.png" }, { name: "late.png" }],
    });
  });

  it("drops a completed image read after the operation is cancelled", () => {
    const store = createComposerDraftStore();
    const operations = createComposerAttachmentOperations(store);
    store.save("session", { text: "before", images: [] });
    const operation = operations.begin("session");

    store.save("session", { text: "latest", images: [] });
    operations.cancel("session");

    expect(operations.complete(operation, [image("late.png")])).toBeUndefined();
    expect(store.load("session")).toEqual({ text: "latest", images: [] });
  });
});

describe("slash command presentation policy", () => {
  const commands = [
    command("compact"),
    command("resume", { aliases: ["continue"] }),
    command("vim", { isHidden: true }),
    command("config", { opensInTerminalDialog: true }),
    command("review", { description: "Run a code review" }),
  ];

  it("only opens for the first slash token and closes after whitespace", () => {
    expect(slashQuery("/")).toBe("");
    expect(slashQuery("/comp")).toBe("comp");
    expect(slashQuery("/comp extra")).toBeUndefined();
    expect(slashQuery("text /comp")).toBeUndefined();
    // Swift filters the first line and leaves the popover open while the
    // user is still editing the remainder of the buffer.
    expect(slashQuery("/comp\nmore")).toBe("comp");
  });

  it("matches Swift ordering and hidden/dialog filtering", () => {
    expect(filterSlashCommands("", commands).map(({ name }) => name)).toEqual(["compact", "resume", "review"]);
    expect(filterSlashCommands("cont", commands).map(({ name }) => name)).toEqual(["resume"]);
    expect(filterSlashCommands("vim", commands).map(({ name }) => name)).toEqual(["vim"]);
    expect(filterSlashCommands("comp", commands).map(({ name }) => name)).toEqual(["compact"]);
  });
});
