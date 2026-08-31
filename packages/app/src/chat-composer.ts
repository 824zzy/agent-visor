import {
  CHAT_IMAGE_ATTACHMENTS_PER_MESSAGE,
  CHAT_IMAGE_MAX_BASE64_CHARS,
  CHAT_IMAGE_MAX_BYTES,
  CHAT_IMAGE_MAX_TOTAL_BASE64_CHARS,
  CHAT_IMAGE_SUPPORTED_MIME_TYPES,
  NATIVE_HELPER_MAX_TEXT_BYTES,
  CHAT_SEND_MAX_TEXT_UTF16_UNITS,
  chatImageBytesMatchMime,
  type ChatImage,
  type ChatSlashCommand,
} from "@agent-visor/protocol";

/**
 * The renderer-facing state for one composer. The store keeps this value in
 * memory only, which matches Swift's DraftStore and avoids treating a draft
 * as conversation history.
 */
export type ComposerAttachment = ChatImage & {
  id: string;
  byteLength?: number;
};

export type ComposerDraft = {
  text: string;
  images: ComposerAttachment[];
};

export type ComposerAttachmentCandidate = {
  name: string;
  mimeType: string;
  byteLength: number;
  data: string;
};

export type ComposerValidationErrorCode =
  | "unsupported_type"
  | "too_large"
  | "too_many"
  | "invalid_content"
  | "text_too_long";

export type ComposerValidationError = {
  code: ComposerValidationErrorCode;
  name: string;
  message: string;
};

export type ComposerAttachmentResult = {
  draft: ComposerDraft;
  accepted: ComposerAttachment[];
  errors: ComposerValidationError[];
};

export type ComposerDraftStore = {
  load(sessionId: string): ComposerDraft;
  save(sessionId: string, draft: ComposerDraft): void;
  clear(sessionId: string): void;
};

export type ComposerRecoveryCommand = {
  id: string;
  type: "restore" | "clear";
  draft: {
    text: string;
    images: ChatImage[];
  };
  expectedComposer:
    | {
      text: string;
      images: ChatImage[];
    }
    | {
      draft: {
        text: string;
        images: ChatImage[];
      };
      revision?: number;
    };
  expectedRevision?: number;
};

export type ComposerRecoveryApplication = {
  status: "applied" | "preserved";
  draft: ComposerDraft;
  reason?: "newer-draft" | "revision-advanced" | "store-changed";
};

export type ComposerAttachmentOperation = {
  sessionId: string;
  epoch: number;
};

export type ComposerAttachmentOperations = {
  begin(sessionId: string): ComposerAttachmentOperation;
  cancel(sessionId: string): void;
  complete(
    operation: ComposerAttachmentOperation,
    candidates: ComposerAttachmentCandidate[],
  ): ComposerAttachmentResult | undefined;
};

export const COMPOSER_MAX_LINES = 8;
// ponytail: if eight visual lines is no longer the product limit, update this
// policy, the measured TextInput height, and its focused Electron checks.
export const COMPOSER_MAX_ATTACHMENTS = CHAT_IMAGE_ATTACHMENTS_PER_MESSAGE;
export const COMPOSER_MAX_IMAGE_BYTES = CHAT_IMAGE_MAX_BYTES;
export const COMPOSER_MAX_FILE_SELECTION = 32;
// ponytail: if a picker exposes more files, add explicit batch handling before
// increasing this preflight bound or allocating any FileReader work.
export const COMPOSER_MIN_HEIGHT = 42;
export const COMPOSER_MAX_TEXT_LENGTH = CHAT_SEND_MAX_TEXT_UTF16_UNITS;
/** Global Codex-compatible UTF-16 ceiling; terminal routes use maxTextBytes. */
export const COMPOSER_MAX_TEXT_BYTES = NATIVE_HELPER_MAX_TEXT_BYTES;
// ponytail: if the provider text ceiling changes, update TextInput maxLength,
// this validation, and the protocol wire-budget derivation together.
export const COMPOSER_VERTICAL_PADDING = 20;
export const COMPOSER_DEFAULT_LINE_HEIGHT = 19;
export const SUPPORTED_COMPOSER_IMAGE_TYPES = CHAT_IMAGE_SUPPORTED_MIME_TYPES;

export type ComposerFilePreflight = {
  accepted: File[];
  errors: ComposerValidationError[];
};

const emptyDraft = (): ComposerDraft => ({ text: "", images: [] });

function cloneDraft(draft: ComposerDraft): ComposerDraft {
  return {
    text: draft.text,
    images: draft.images.map((image) => ({ ...image })),
  };
}

/** Create an isolated in-memory store so tests and each app instance are independent. */
export function createComposerDraftStore(): ComposerDraftStore {
  const drafts = new Map<string, ComposerDraft>();
  return {
    load(sessionId) {
      const draft = drafts.get(sessionId);
      return draft ? cloneDraft(draft) : emptyDraft();
    },
    save(sessionId, draft) {
      if (!draft.text && draft.images.length === 0) {
        drafts.delete(sessionId);
        return;
      }
      drafts.set(sessionId, cloneDraft(draft));
    },
    clear(sessionId) {
      drafts.delete(sessionId);
    },
  };
}

/**
 * Apply a controller recovery command as one guarded store operation.
 *
 * The caller's draft and revision are checked before the store is written;
 * this prevents a timeout/failure callback from overwriting edits made after
 * the original submit. A lower local revision is allowed after a remount as
 * long as the persisted draft still matches the controller's expected
 * snapshot. The controller remains the source of truth for session and
 * generation identity.
 */
export function applyComposerRecoveryCommand(
  store: ComposerDraftStore,
  sessionId: string,
  currentDraft: ComposerDraft,
  currentRevision: number,
  command: ComposerRecoveryCommand,
): ComposerRecoveryApplication {
  const expected = toComposerDraftSnapshot(command.expectedComposer);
  const persisted = store.load(sessionId);
  if (!composerDraftsEqual(currentDraft, persisted)) {
    return { status: "preserved", draft: cloneDraft(currentDraft), reason: "store-changed" };
  }
  if (!composerDraftsEqual(currentDraft, expected)) {
    return { status: "preserved", draft: cloneDraft(currentDraft), reason: "newer-draft" };
  }
  if (command.type === "restore"
    && command.expectedRevision !== undefined
    && currentRevision > command.expectedRevision) {
    return { status: "preserved", draft: cloneDraft(currentDraft), reason: "revision-advanced" };
  }
  const next = command.type === "restore"
    ? composerDraftFromSubmitted(command.draft)
    : emptyDraft();
  if (next.text.length === 0 && next.images.length === 0) store.clear(sessionId);
  else store.save(sessionId, next);
  return { status: "applied", draft: cloneDraft(next) };
}

/** Convert the renderer draft to the provider-neutral submitted snapshot. */
export function composerDraftToSubmitted(draft: ComposerDraft): {
  text: string;
  images: ChatImage[];
} {
  return {
    text: draft.text,
    images: draft.images.map(({ id: _id, ...image }) => ({ ...image })),
  };
}

/** Rehydrate a submitted snapshot with renderer-local attachment identities. */
export function composerDraftFromSubmitted(draft: {
  text: string;
  images: ChatImage[];
}): ComposerDraft {
  return {
    text: draft.text,
    images: draft.images.map((image, index) => ({
      ...image,
      id: `recovered-${index}-${image.name}`,
    })),
  };
}

function toComposerDraftSnapshot(snapshot: {
  text?: string;
  images?: ChatImage[];
  draft?: {
    text: string;
    images: ChatImage[];
  };
  revision?: number;
}): ComposerDraft {
  return composerDraftFromSubmitted(snapshot.draft ?? {
    text: snapshot.text ?? "",
    images: snapshot.images ?? [],
  });
}

function composerDraftsEqual(left: ComposerDraft, right: ComposerDraft): boolean {
  if (left.text !== right.text || left.images.length !== right.images.length) return false;
  return left.images.every((image, index) => {
    const other = right.images[index];
    return image.name === other?.name
      && image.mimeType === other.mimeType
      && image.data === other.data
      && image.byteLength === other.byteLength;
  });
}

/** The app-lifetime store mirrors Swift DraftStore.shared. */
export const composerDraftStore = createComposerDraftStore();

/** Validate file metadata before any accepted file is materialized by FileReader. */
export function preflightComposerFiles(
  files: ArrayLike<File> | Iterable<File>,
  existingAttachmentCount: number,
): ComposerFilePreflight {
  const accepted: File[] = [];
  const errors: ComposerValidationError[] = [];
  for (const file of boundedFiles(files)) {
    let name = "Image";
    let mimeType = "";
    let byteLength: unknown;
    try {
      name = file.name || name;
      mimeType = file.type;
      byteLength = file.size;
    } catch {
      errors.push(invalidFileMetadataError(name));
      continue;
    }
    if (!supportedImageType(mimeType)) {
      errors.push({
        code: "unsupported_type",
        name,
        message: `${name}: choose a PNG, JPEG, GIF, WebP, TIFF, or HEIC image.`,
      });
      continue;
    }
    if (typeof byteLength !== "number" || !Number.isFinite(byteLength)
      || !Number.isInteger(byteLength) || byteLength < 0) {
      errors.push(invalidFileMetadataError(name));
      continue;
    }
    if (byteLength > COMPOSER_MAX_IMAGE_BYTES) {
      errors.push({
        code: "too_large",
        name,
        message: `${name}: images must be 10 MB or smaller.`,
      });
      continue;
    }
    if (existingAttachmentCount + accepted.length >= COMPOSER_MAX_ATTACHMENTS) {
      errors.push({
        code: "too_many",
        name,
        message: `You can attach up to ${COMPOSER_MAX_ATTACHMENTS} images per message.`,
      });
      continue;
    }
    accepted.push(file);
  }
  return { accepted, errors };
}

/**
 * Append completed file reads to the draft that is current at completion
 * time. FileReader callbacks can outlive several user edits, so callers must
 * not pass a draft captured before the asynchronous read started.
 */
export function appendComposerAttachments(
  store: ComposerDraftStore,
  sessionId: string,
  candidates: ComposerAttachmentCandidate[],
): ComposerAttachmentResult {
  const result = addComposerAttachments(store.load(sessionId), candidates);
  store.save(sessionId, result.draft);
  return result;
}

/** Keep asynchronous file reads tied to the mounted session and its current draft epoch. */
export function createComposerAttachmentOperations(
  store: ComposerDraftStore,
): ComposerAttachmentOperations {
  const epochs = new Map<string, number>();
  return {
    begin(sessionId) {
      return { sessionId, epoch: epochs.get(sessionId) ?? 0 };
    },
    cancel(sessionId) {
      epochs.set(sessionId, (epochs.get(sessionId) ?? 0) + 1);
    },
    complete(operation, candidates) {
      if ((epochs.get(operation.sessionId) ?? 0) !== operation.epoch) return undefined;
      return appendComposerAttachments(store, operation.sessionId, candidates);
    },
  };
}

export type ComposerKeyInput = {
  key: string;
  shiftKey?: boolean;
  isComposing?: boolean;
  keyCode?: number;
};

export type ComposerKeyAction = "submit" | "newline" | "ignore";

/**
 * Map a keyboard event to the public composer interaction. keyCode 229 is the
 * browser's composition sentinel on engines that do not expose isComposing.
 */
export function composerKeyAction(input: ComposerKeyInput): ComposerKeyAction {
  if (input.isComposing || input.keyCode === 229) return "ignore";
  if (input.key !== "Enter") return "ignore";
  return input.shiftKey ? "newline" : "submit";
}

export type ComposerEscapeAction = "close_suggestions" | "clear_draft";

/** Swift consumes Escape in the composer: dismiss suggestions first, then clear the draft. */
export function composerEscapeAction(slashOpen: boolean): ComposerEscapeAction {
  return slashOpen ? "close_suggestions" : "clear_draft";
}

export type ComposerLayoutInput = {
  contentHeight: number;
  lineHeight: number;
  verticalPadding?: number;
  minHeight?: number;
};

export type ComposerLayout = {
  height: number;
  maxHeight: number;
  visualLineCount: number;
  scrollable: boolean;
};

/**
 * Convert the browser's measured scrollHeight into the same grow-then-scroll
 * behavior as Swift's NSTextView. contentHeight includes the input padding.
 */
export function composerLayoutForContent(input: ComposerLayoutInput): ComposerLayout {
  const lineHeight = input.lineHeight > 0 ? input.lineHeight : COMPOSER_DEFAULT_LINE_HEIGHT;
  const verticalPadding = input.verticalPadding ?? COMPOSER_VERTICAL_PADDING;
  const minHeight = input.minHeight ?? COMPOSER_MIN_HEIGHT;
  const maxHeight = lineHeight * COMPOSER_MAX_LINES + verticalPadding;
  const contentOnlyHeight = Math.max(0, input.contentHeight - verticalPadding);
  const visualLineCount = Math.max(1, Math.ceil(contentOnlyHeight / lineHeight));
  const height = Math.min(maxHeight, Math.max(minHeight, input.contentHeight));
  return {
    height,
    maxHeight,
    visualLineCount,
    scrollable: input.contentHeight > maxHeight,
  };
}

function newAttachmentID(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `attachment-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function supportedImageType(mimeType: string): mimeType is ComposerAttachment["mimeType"] {
  return (SUPPORTED_COMPOSER_IMAGE_TYPES as readonly string[]).includes(mimeType);
}

/** Validate and append files without silently dropping a user-visible error. */
export function addComposerAttachments(
  draft: ComposerDraft,
  candidates: ComposerAttachmentCandidate[],
): ComposerAttachmentResult {
  const next = cloneDraft(draft);
  const accepted: ComposerAttachment[] = [];
  const errors: ComposerValidationError[] = [];
  let encodedBytes = next.images.reduce((total, image) => (
    total + (typeof image.data === "string" ? image.data.length : 0)
  ), 0);
  for (const candidate of candidates) {
    if (!supportedImageType(candidate.mimeType)) {
      errors.push({
        code: "unsupported_type",
        name: candidate.name,
        message: `${candidate.name}: choose a PNG, JPEG, GIF, WebP, TIFF, or HEIC image.`,
      });
      continue;
    }
    if (typeof candidate.byteLength !== "number" || !Number.isFinite(candidate.byteLength)) {
      errors.push(invalidContentError(candidate));
      continue;
    }
    if (candidate.byteLength > COMPOSER_MAX_IMAGE_BYTES) {
      errors.push({
        code: "too_large",
        name: candidate.name,
        message: `${candidate.name}: images must be 10 MB or smaller.`,
      });
      continue;
    }
    if (!Number.isInteger(candidate.byteLength) || candidate.byteLength < 0) {
      errors.push(invalidContentError(candidate));
      continue;
    }
    if (typeof candidate.data !== "string"
      || candidate.data.length > CHAT_IMAGE_MAX_BASE64_CHARS
      || encodedBytes > CHAT_IMAGE_MAX_TOTAL_BASE64_CHARS - candidate.data.length) {
      errors.push(invalidContentError(candidate));
      continue;
    }
    const bytes = decodeBase64(candidate.data);
    if (!bytes || bytes.byteLength !== candidate.byteLength
      || !chatImageBytesMatchMime(candidate.mimeType, bytes)) {
      errors.push(invalidContentError(candidate));
      continue;
    }
    if (next.images.length >= COMPOSER_MAX_ATTACHMENTS) {
      errors.push({
        code: "too_many",
        name: candidate.name,
        message: `You can attach up to ${COMPOSER_MAX_ATTACHMENTS} images per message.`,
      });
      continue;
    }
    const attachment: ComposerAttachment = {
      id: newAttachmentID(),
      name: candidate.name || "image",
      mimeType: candidate.mimeType,
      data: candidate.data,
      byteLength: candidate.byteLength,
    };
    next.images.push(attachment);
    accepted.push(attachment);
    encodedBytes += candidate.data.length;
  }
  return { draft: next, accepted, errors };
}

function boundedFiles(files: ArrayLike<File> | Iterable<File>): File[] {
  const result: File[] = [];
  if (typeof (files as Iterable<File>)[Symbol.iterator] === "function") {
    const iterator = (files as Iterable<File>)[Symbol.iterator]();
    while (result.length < COMPOSER_MAX_FILE_SELECTION) {
      const next = iterator.next();
      if (next.done) break;
      result.push(next.value);
    }
    return result;
  }
  const arrayLike = files as ArrayLike<File>;
  const length = Math.min(COMPOSER_MAX_FILE_SELECTION, Math.max(0, Number(arrayLike.length) || 0));
  for (let index = 0; index < length; index += 1) result.push(arrayLike[index]!);
  return result;
}

function invalidFileMetadataError(name: string): ComposerValidationError {
  return {
    code: "invalid_content",
    name,
    message: `${name}: the image metadata is invalid.`,
  };
}

function invalidContentError(candidate: ComposerAttachmentCandidate): ComposerValidationError {
  const name = typeof candidate.name === "string" && candidate.name ? candidate.name : "Image";
  const mimeType = typeof candidate.mimeType === "string" ? candidate.mimeType : "image";
  return {
    code: "invalid_content",
    name,
    message: `${name}: the image could not be read or is not a valid ${mimeType.replace("image/", "")} image.`,
  };
}

function decodeBase64(value: unknown): Uint8Array | undefined {
  if (typeof value !== "string" || !value || value.length % 4 !== 0
    || value.length > CHAT_IMAGE_MAX_BASE64_CHARS
    || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    return undefined;
  }
  try {
    const binary = atob(value);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    return undefined;
  }
}

export function removeComposerAttachment(
  draft: ComposerDraft,
  attachmentId: string,
): ComposerDraft {
  return {
    text: draft.text,
    images: draft.images.filter((image) => image.id !== attachmentId),
  };
}

export type ComposerSubmission = {
  text: string;
  images: ComposerAttachment[];
};

export function draftSubmission(draft: ComposerDraft, maxTextBytes?: number): ComposerSubmission | undefined {
  if (validateComposerText(draft.text, maxTextBytes)) return undefined;
  const text = draft.text.trim();
  if (!text && draft.images.length === 0) return undefined;
  return { text, images: draft.images.map((image) => ({ ...image })) };
}

export function composerTextByteLength(text: string): number {
  return new TextEncoder().encode(text).byteLength;
}

export function validateComposerText(text: string, maxTextBytes?: number): ComposerValidationError | undefined {
  const providerLimit = maxTextBytes === undefined
    ? undefined
    : Math.min(COMPOSER_MAX_TEXT_BYTES, Math.max(1, Math.floor(maxTextBytes)));
  if (providerLimit !== undefined && composerTextByteLength(text) > providerLimit) {
    return {
      code: "text_too_long",
      name: "Message",
      message: `Message text must be ${providerLimit.toLocaleString()} UTF-8 bytes or shorter for this terminal.`,
    };
  }
  if (text.length <= COMPOSER_MAX_TEXT_LENGTH) return undefined;
  return {
    code: "text_too_long",
    name: "Message",
    message: `Message text must be ${COMPOSER_MAX_TEXT_LENGTH.toLocaleString()} characters or shorter.`,
  };
}

/** Return the first-token query, or undefined when Swift closes its popover. */
export function slashQuery(text: string): string | undefined {
  if (!text.startsWith("/")) return undefined;
  const firstLine = text.split("\n", 1)[0] ?? "";
  if (firstLine.includes(" ") || firstLine.includes("\t")) return undefined;
  return firstLine.slice(1);
}

/** Match Swift's exact > alias > prefix > substring > description ranking. */
export function filterSlashCommands(
  query: string,
  commands: ChatSlashCommand[],
): ChatSlashCommand[] {
  const normalized = query.toLowerCase();
  if (!normalized) {
    return [...commands]
      .filter((command) => !command.isHidden && !command.opensInTerminalDialog)
      .sort((left, right) => left.name.localeCompare(right.name));
  }
  return commands
    .flatMap((command) => {
      if (command.opensInTerminalDialog) return [];
      const name = command.name.toLowerCase();
      const aliases = command.aliases.map((alias) => alias.toLowerCase());
      const description = command.description.toLowerCase();
      const score = name === normalized ? 100
        : aliases.includes(normalized) ? 90
          : name.startsWith(normalized) ? 60
            : aliases.some((alias) => alias.startsWith(normalized)) ? 50
              : command.isHidden ? 0
                : name.includes(normalized) ? 30
                  : aliases.some((alias) => alias.includes(normalized)) ? 20
                    : description.includes(normalized) ? 10 : 0;
      return score ? [{ command, score }] : [];
    })
    .sort((left, right) => right.score - left.score || left.command.name.localeCompare(right.command.name))
    .map(({ command }) => command);
}
