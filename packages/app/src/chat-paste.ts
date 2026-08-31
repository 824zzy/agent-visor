import type { ComposerAttachmentCandidate } from "./chat-composer";

export type ClipboardImageItem = {
  kind?: string;
  type?: string;
  getAsFile?(): File | null;
  getAsString?(callback: (value: string) => void): void;
};

export type ClipboardImageData = {
  files?: ArrayLike<File> | Iterable<File>;
  items?: ArrayLike<ClipboardImageItem> | Iterable<ClipboardImageItem>;
  getData?(type: string): string;
};

export type ImageFileURLPayload = {
  name: string;
  mimeType: string;
  byteLength: number;
  data: string;
};

export type ReadImageFileURL = (url: string) => Promise<ImageFileURLPayload | undefined>;

export type ComposerPasteResult = {
  files: File[];
  urlCandidates: ComposerAttachmentCandidate[];
  /** Text from an async clipboard item that the composer must insert. */
  fallbackText?: string;
};

export type ComposerPasteDraft = {
  text: string;
  images: ReadonlyArray<{ id: string }>;
};

export type ComposerPasteInputState = {
  value: string;
  selectionStart: number;
  selectionEnd: number;
};

export type ComposerPasteSnapshot = ComposerPasteInputState & {
  sessionId: string;
  draft: ComposerPasteDraft;
};

export const COMPOSER_PASTE_CANCELED_MESSAGE = "Paste canceled because the composer changed.";

const URL_MIME_TYPES = new Set(["text/uri-list", "text/plain"]);
const COMPOSER_PASTE_MAX_FILES = 32;
// ponytail: if clipboard batches exceed this bound, add explicit batch
// handling before increasing the number of files materialized here.
const COMPOSER_PASTE_MAX_ITEMS = 64;
// ponytail: if browsers expose more clipboard items, add bounded paging before
// increasing this preflight and async extraction bound.
const COMPOSER_PASTE_MAX_STRING_ITEMS = 8;
// ponytail: if URL string items need a larger scan, add a native clipboard
// adapter instead of starting unbounded getAsString callbacks.
const COMPOSER_PASTE_MAX_TEXT_LENGTH = 256 * 1_024;
// ponytail: if clipboard text can exceed this retained budget, add a native
// streaming clipboard adapter before increasing async materialization.

/** Decide whether paste should be consumed before asynchronous URL extraction. */
export function hasComposerPastePayload(data: ClipboardImageData | null | undefined): boolean {
  if (!data) return false;
  const files = values(data.files, COMPOSER_PASTE_MAX_FILES);
  if (files.some((file) => isImageMime(file.type))) return true;
  const items = values(data.items, COMPOSER_PASTE_MAX_ITEMS);
  if (items.some((item) => {
    if ((!item.kind || item.kind === "file") && isImageMime(item.type ?? "")) return true;
    if ((!item.kind || item.kind === "string")
      && URL_MIME_TYPES.has((item.type ?? "").toLowerCase())
      && typeof item.getAsString === "function") return true;
    return false;
  })) return true;
  return ["text/uri-list", "text/plain"]
    .some((type) => hasOneSupportedImageURL(safeClipboardData(data, type)));
}

/** Capture the state that an async paste is allowed to modify. */
export function createComposerPasteSnapshot(
  sessionId: string,
  draft: ComposerPasteDraft,
  input: ComposerPasteInputState,
): ComposerPasteSnapshot {
  return { sessionId, draft, ...input };
}

/** Reject a late fallback result if the user changed its session, draft, or selection. */
export function composerPasteSnapshotIsCurrent(
  snapshot: ComposerPasteSnapshot,
  sessionId: string,
  draft: ComposerPasteDraft,
  input: ComposerPasteInputState,
): boolean {
  return snapshot.sessionId === sessionId
    && snapshot.draft === draft
    && snapshot.value === input.value
    && snapshot.selectionStart === input.selectionStart
    && snapshot.selectionEnd === input.selectionEnd;
}

/**
 * Adapt browser clipboard shapes to the composer public seam. Browser image
 * clipboard items are not consistently included in `files`, while Finder
 * copies expose a local file URL as a string item.
 */
export async function extractComposerPaste(
  data: ClipboardImageData | null | undefined,
  readImageFileURL?: ReadImageFileURL,
): Promise<ComposerPasteResult> {
  if (!data) return { files: [], urlCandidates: [] };
  const files = values(data.files, COMPOSER_PASTE_MAX_FILES);
  const imageFiles = files.filter((file) => isImageMime(file.type));
  if (imageFiles.length > 0) return { files: imageFiles, urlCandidates: [] };

  const items = values(data.items, COMPOSER_PASTE_MAX_ITEMS);
  const hasAsyncTextItem = items.some((item) => (!item.kind || item.kind === "string")
    && URL_MIME_TYPES.has((item.type ?? "").toLowerCase())
    && typeof item.getAsString === "function");
  const itemFiles = items
    .filter((item) => (!item.kind || item.kind === "file") && isImageMime(item.type ?? ""))
    .map((item) => {
      try { return item.getAsFile?.() ?? undefined; } catch { return undefined; }
    })
    .filter((file): file is File => file !== undefined && isImageMime(file.type));
  if (itemFiles.length > 0) return { files: itemFiles, urlCandidates: [] };

  const textBudget = { remaining: COMPOSER_PASTE_MAX_TEXT_LENGTH };
  const strings = await readClipboardStrings(items, textBudget);
  const clipboardDataStrings = ["text/uri-list", "text/plain"]
    .map((type) => retainClipboardText(safeClipboardData(data, type), textBudget));
  const urls = collectClipboardURLs(strings.concat(clipboardDataStrings));
  // Swift only accepts a single copied file URL as an image paste.
  if (urls.all.length === 1 && urls.local.length === 1 && readImageFileURL
    && isSupportedImageURL(urls.local[0]!)) {
    const payload = await readImageFileURL(urls.local[0]!);
    if (payload) {
      return {
        files: [],
        urlCandidates: [{
          name: payload.name,
          mimeType: payload.mimeType,
          byteLength: payload.byteLength,
          data: payload.data,
        }],
      };
    }
  }
  const fallbackText = hasAsyncTextItem
    ? fallbackClipboardText(strings, clipboardDataStrings)
    : undefined;
  return {
    files: [],
    urlCandidates: [],
    ...(fallbackText ? { fallbackText } : {}),
  };
}

function values<T>(value: ArrayLike<T> | Iterable<T> | undefined, maximum: number): T[] {
  if (!value) return [];
  const result: T[] = [];
  if (typeof (value as Iterable<T>)[Symbol.iterator] === "function") {
    for (const item of value as Iterable<T>) {
      if (result.length >= maximum) break;
      result.push(item);
    }
    return result;
  }
  const length = Math.min(maximum, Math.max(0, Number((value as ArrayLike<T>).length) || 0));
  for (let index = 0; index < length; index += 1) {
    result.push((value as ArrayLike<T>)[index]!);
  }
  return result;
}

function isImageMime(value: string): boolean {
  return value.toLowerCase().startsWith("image/");
}

async function readClipboardStrings(
  items: ClipboardImageItem[],
  budget: { remaining: number },
): Promise<string[]> {
  const strings: string[] = [];
  for (const item of items
    .filter((candidate) => (!candidate.kind || candidate.kind === "string")
      && URL_MIME_TYPES.has((candidate.type ?? "").toLowerCase()))
    .slice(0, COMPOSER_PASTE_MAX_STRING_ITEMS)) {
    if (budget.remaining <= 0) break;
    const value = await readClipboardString(item, budget.remaining);
    if (!value) continue;
    strings.push(value);
    budget.remaining -= value.length;
  }
  return strings;
}

function readClipboardString(item: ClipboardImageItem, maximum: number): Promise<string> {
  return new Promise((resolve) => {
    if (!item.getAsString) { resolve(""); return; }
    try {
      item.getAsString((value) => resolve(typeof value === "string" ? value.slice(0, maximum) : ""));
    } catch { resolve(""); }
  });
}

type ClipboardURLs = { all: string[]; local: string[] };

/** Parse all URLs before local-image filtering so local+remote paste is preserved. */
function collectClipboardURLs(valuesToParse: string[]): ClipboardURLs {
  const all = new Set<string>();
  const local = new Set<string>();
  for (const value of valuesToParse) {
    for (const line of boundedClipboardText(value).split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      try {
        const url = new URL(trimmed);
        if (url.search || url.hash) continue;
        all.add(url.href);
        if (url.protocol === "file:"
          && (!url.hostname || url.hostname === "localhost")) local.add(url.href);
      } catch { /* Clipboard text can contain ordinary non-URL text. */ }
    }
  }
  return { all: [...all], local: [...local] };
}

function hasOneSupportedImageURL(value: string): boolean {
  const urls = collectClipboardURLs([value]);
  return urls.all.length === 1 && urls.local.length === 1 && isSupportedImageURL(urls.local[0]!);
}

function isSupportedImageURL(value: string): boolean {
  try {
    const pathname = decodeURIComponent(new URL(value).pathname).toLowerCase();
    return [".png", ".jpg", ".jpeg", ".gif", ".webp", ".tif", ".tiff", ".heic"]
      .some((extension) => pathname.endsWith(extension));
  } catch {
    return false;
  }
}

function safeClipboardData(data: ClipboardImageData, type: string): string {
  try {
    const value = data.getData?.(type) ?? "";
    return typeof value === "string" ? boundedClipboardText(value) : "";
  } catch { return ""; }
}

function retainClipboardText(value: string, budget: { remaining: number }): string {
  if (budget.remaining <= 0) return "";
  const retained = value.slice(0, budget.remaining);
  budget.remaining -= retained.length;
  return retained;
}

function fallbackClipboardText(itemStrings: string[], directStrings: string[]): string | undefined {
  // Prefer plain text, then URI-list, then async item text to preserve selection content.
  return [directStrings[1] ?? "", directStrings[0] ?? "", ...itemStrings]
    .find((value) => value.length > 0);
}

/** Replace the current selection while returning the resulting caret position. */
export function insertComposerTextAtSelection(
  value: string,
  text: string,
  selectionStart: number,
  selectionEnd: number,
): { value: string; selectionStart: number; selectionEnd: number } {
  const start = clampSelection(selectionStart, value.length);
  const end = Math.max(start, clampSelection(selectionEnd, value.length));
  const next = `${value.slice(0, start)}${text}${value.slice(end)}`;
  const caret = start + text.length;
  return { value: next, selectionStart: caret, selectionEnd: caret };
}

function clampSelection(value: number, length: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.min(length, value)) : length;
}

function boundedClipboardText(value: string): string {
  return value.slice(0, COMPOSER_PASTE_MAX_TEXT_LENGTH);
}
