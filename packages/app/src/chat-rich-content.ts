import type { ChatItem } from "@agent-visor/protocol";

/**
 * Provider-neutral presentation model for one canonical Chat text value.
 *
 * The parser is deliberately presentation-only. It does not trim, repair, or
 * otherwise write back provider text. A renderer can therefore use this
 * document while the original value remains the source used for copying,
 * reconciliation, and accessibility fallback.
 */
export type ChatRichInline =
  | { kind: "text"; text: string }
  | { kind: "strong"; text: string }
  | { kind: "emphasis"; text: string }
  | { kind: "strike"; text: string }
  | { kind: "code"; text: string }
  | { kind: "link"; text: string; href: string }
  | { kind: "local-reference"; text: string; href: string }
  | { kind: "math"; text: string };

export type ChatRichBlock =
  | { kind: "paragraph"; inlines: ChatRichInline[] }
  | { kind: "heading"; level: number; inlines: ChatRichInline[] }
  | { kind: "blockquote"; inlines: ChatRichInline[] }
  | { kind: "list"; ordered: boolean; items: ChatRichInline[][] }
  | { kind: "code"; language?: string; text: string }
  | { kind: "table"; header: ChatRichInline[][]; rows: ChatRichInline[][][] }
  | { kind: "math"; text: string }
  | { kind: "thematic-break" };

export type ChatCodeTokenKind = "plain" | "keyword" | "string" | "comment" | "number" | "literal";

export type ChatCodeToken = {
  kind: ChatCodeTokenKind;
  text: string;
};

export type ChatMathPresentation = {
  source: string;
  mathML?: string;
};

const CHAT_CODE_TOKEN_INPUT_LIMIT = 32_768;
const CHAT_MATH_INPUT_LIMIT = 4_096;
// ponytail: keep local-reference parsing bounded; a larger authored path
// requires a dedicated disclosure/copy surface rather than more inline work.
const CHAT_LOCAL_REFERENCE_INPUT_LIMIT = 4_096;

export type ChatRichDocument = {
  source: string;
  blocks: ChatRichBlock[];
};

/**
 * Parse Markdown-like provider text into safe renderable blocks. The
 * supported syntax matches the Swift chat surface: headings, paragraphs,
 * lists, quotes, fenced code, tables, emphasis, strike-through, links, and
 * LaTeX delimiters. Unknown or malformed syntax stays literal text.
 */
export function parseChatRichText(source: string): ChatRichDocument {
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  const blocks: ChatRichBlock[] = [];
  let index = 0;

  while (index < lines.length) {
    if (!lines[index]!.trim()) {
      index += 1;
      continue;
    }

    const fence = parseFenceStart(lines[index]!);
    if (fence) {
      const codeLines: string[] = [];
      index += 1;
      while (index < lines.length && !isFenceEnd(lines[index]!, fence.marker)) {
        codeLines.push(lines[index]!);
        index += 1;
      }
      if (index < lines.length) index += 1;
      blocks.push({
        kind: "code",
        ...(fence.language ? { language: fence.language } : {}),
        text: codeLines.join("\n"),
      });
      continue;
    }

    const mathStart = lines[index]!.trim() === "$$";
    if (mathStart) {
      const mathLines: string[] = [];
      index += 1;
      while (index < lines.length && lines[index]!.trim() !== "$$") {
        mathLines.push(lines[index]!);
        index += 1;
      }
      if (index < lines.length) index += 1;
      blocks.push({ kind: "math", text: mathLines.join("\n") });
      continue;
    }

    const heading = /^( {0,3})(#{1,6})\s+(.*)$/.exec(lines[index]!);
    if (heading) {
      blocks.push({
        kind: "heading",
        level: heading[2]!.length,
        inlines: parseChatRichInline(heading[3]!),
      });
      index += 1;
      continue;
    }

    if (isThematicBreak(lines[index]!)) {
      blocks.push({ kind: "thematic-break" });
      index += 1;
      continue;
    }

    const table = parseTable(lines, index);
    if (table) {
      blocks.push(table.block);
      index = table.nextIndex;
      continue;
    }

    const quote = /^ {0,3}>\s?(.*)$/.exec(lines[index]!);
    if (quote) {
      const quoteLines: string[] = [];
      while (index < lines.length) {
        const match = /^ {0,3}>\s?(.*)$/.exec(lines[index]!);
        if (!match) break;
        quoteLines.push(match[1]!);
        index += 1;
      }
      blocks.push({ kind: "blockquote", inlines: parseChatRichInline(quoteLines.join("\n")) });
      continue;
    }

    const list = parseList(lines, index);
    if (list) {
      blocks.push(list.block);
      index = list.nextIndex;
      continue;
    }

    const paragraphLines: string[] = [];
    while (index < lines.length && lines[index]!.trim()) {
      const line = lines[index]!;
      if (paragraphLines.length && ((parseFenceStart(line) && !hasUnclosedInlineFence(paragraphLines.join("\n")))
        || /^( {0,3})#{1,6}\s+/.test(line)
        || isThematicBreak(line)
        || /^ {0,3}>\s?/.test(line)
        || parseListItem(line)
        || (line.includes("|") && isTableDivider(lines[index + 1])))) break;
      paragraphLines.push(line);
      index += 1;
    }
    if (paragraphLines.length) {
      blocks.push({ kind: "paragraph", inlines: parseChatRichInline(paragraphLines.join("\n")) });
    } else {
      // A malformed block marker must still remain visible and selectable.
      blocks.push({ kind: "paragraph", inlines: [{ kind: "text", text: lines[index]! }] });
      index += 1;
    }
  }

  return { source, blocks };
}

/** Parse only inline presentation syntax. Malformed spans are literal. */
export function parseChatRichInline(source: string): ChatRichInline[] {
  const result: ChatRichInline[] = [];
  let index = 0;
  let textStart = 0;

  const flushText = (end: number) => {
    if (end > textStart) appendInline(result, { kind: "text", text: source.slice(textStart, end) });
  };

  while (index < source.length) {
    const link = parseLink(source, index);
    if (link) {
      flushText(index);
      appendInline(result, link.inline);
      index = link.nextIndex;
      textStart = index;
      continue;
    }

    const fencedCodeEnd = source.startsWith("```", index) ? source.indexOf("```", index + 3) : -1;
    if (fencedCodeEnd > index + 3) {
      const payload = source.slice(index + 3, fencedCodeEnd);
      const firstLineBreak = payload.indexOf("\n");
      const code = firstLineBreak >= 0 ? payload.slice(firstLineBreak + 1) : payload;
      flushText(index);
      appendInline(result, { kind: "code", text: code });
      index = fencedCodeEnd + 3;
      textStart = index;
      continue;
    }

    const codeEnd = source[index] === "`" ? source.indexOf("`", index + 1) : -1;
    if (codeEnd > index + 1) {
      flushText(index);
      appendInline(result, { kind: "code", text: source.slice(index + 1, codeEnd) });
      index = codeEnd + 1;
      textStart = index;
      continue;
    }

    const math = source[index] === "$" ? findMathEnd(source, index) : undefined;
    if (math) {
      flushText(index);
      appendInline(result, { kind: "math", text: source.slice(index + math.openLength, math.end) });
      index = math.end + math.closeLength;
      textStart = index;
      continue;
    }

    // Intraword underscore runs are literal text. Skip the complete run so
    // the boundary check stays linear even for very long authored identifiers.
    if (source[index] === "_" && (index === 0 || source[index - 1] !== "_")) {
      const runEnd = underscoreRunEnd(source, index);
      if (isIntrawordUnderscoreRun(source, index, runEnd)) {
        index = runEnd;
        continue;
      }
    }

    const delimiter = delimiterAt(source, index);
    if (delimiter) {
      const end = source.indexOf(delimiter.marker, index + delimiter.marker.length);
      if (end > index + delimiter.marker.length) {
        const value = source.slice(index + delimiter.marker.length, end);
        if (!value.includes("\n") || delimiter.marker === "~~") {
          flushText(index);
          appendInline(result, { kind: delimiter.kind, text: value });
          index = end + delimiter.marker.length;
          textStart = index;
          continue;
        }
      }
    }

    index += 1;
  }

  flushText(source.length);
  return result;
}

/** Allow only explicit, user-safe link protocols. */
export function safeChatLink(value: string): string | undefined {
  const raw = value.trim();
  // ponytail: keep external-link validation bounded; if longer authored URLs
  // become a product requirement, add a reviewed link model before raising this cap.
  if (!raw || raw.length > 4_096) return undefined;
  try {
    const parsed = new URL(raw);
    if (!["http:", "https:", "mailto:"].includes(parsed.protocol)) return undefined;
    // Return the authored URL after protocol validation. URL#toString() can
    // add a trailing slash or otherwise normalize text the provider emitted.
    return raw;
  } catch {
    return undefined;
  }
}

export type ChatLocalReference = {
  label: string;
  path: string;
};

/**
 * Project an absolute local evidence path into a compact, non-opening label.
 * The full authored path remains in the path field for accessibility and disclosure.
 */
export function chatLocalReference(value: string, authoredLabel?: string): ChatLocalReference | undefined {
  const path = value.trim();
  if (!path || path.length > CHAT_LOCAL_REFERENCE_INPUT_LIMIT || /[\0\r\n]/.test(path)) return undefined;
  const normalized = path.replaceAll("\\", "/");
  const location = /(?::\d+(?::\d+)?|#L\d+(?:-L\d+)?)$/.exec(normalized);
  const basePath = location ? normalized.slice(0, location.index) : normalized;
  const absolute = (basePath.startsWith("/") && !basePath.startsWith("//"))
    || /^[A-Za-z]:\//.test(basePath);
  if (!absolute || basePath.endsWith("/") || basePath.endsWith("/.") || basePath.endsWith("/..")) return undefined;
  const basename = basePath.slice(basePath.lastIndexOf("/") + 1);
  if (!basename || basename === "." || basename === "..") return undefined;
  const suffix = location ? normalized.slice(location.index) : "";
  const label = authoredLabel?.trim() ? stripInlineMarkers(authoredLabel).trim() : basename + suffix;
  return { label: label || basename + suffix, path };
}

/**
 * Tokenize the common fenced languages without changing the source text.
 * Unknown languages and oversized input intentionally fall back to one
 * literal token so presentation can never hide provider-authored content.
 */
export function tokenizeChatCode(source: string, language?: string): ChatCodeToken[] {
  const normalizedLanguage = normalizeCodeLanguage(language);
  if (!normalizedLanguage || source.length > CHAT_CODE_TOKEN_INPUT_LIMIT) {
    return [{ kind: "literal", text: source }];
  }

  const tokens: ChatCodeToken[] = [];
  let index = 0;
  let plainStart = 0;
  const flushPlain = (end: number) => {
    if (end > plainStart) appendCodeToken(tokens, { kind: "plain", text: source.slice(plainStart, end) });
  };

  while (index < source.length) {
    const lineComment = source.startsWith("//", index)
      && (normalizedLanguage === "javascript" || normalizedLanguage === "typescript");
    const hashComment = source[index] === "#"
      && (normalizedLanguage === "python" || normalizedLanguage === "bash");
    if (lineComment || hashComment) {
      const end = source.indexOf("\n", index);
      const commentEnd = end < 0 ? source.length : end;
      flushPlain(index);
      appendCodeToken(tokens, { kind: "comment", text: source.slice(index, commentEnd) });
      index = commentEnd;
      plainStart = commentEnd;
      continue;
    }

    if ((normalizedLanguage === "javascript" || normalizedLanguage === "typescript")
      && source.startsWith("/*", index)) {
      const close = source.indexOf("*/", index + 2);
      const commentEnd = close < 0 ? source.length : close + 2;
      flushPlain(index);
      appendCodeToken(tokens, { kind: "comment", text: source.slice(index, commentEnd) });
      index = commentEnd;
      plainStart = commentEnd;
      continue;
    }

    const quote = source[index];
    if (quote === "'" || quote === '"' || (quote === "`" && normalizedLanguage !== "bash")) {
      const end = quotedCodeEnd(source, index, quote);
      flushPlain(index);
      appendCodeToken(tokens, { kind: "string", text: source.slice(index, end) });
      index = end;
      plainStart = end;
      continue;
    }

    const number = /^(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)/.exec(source.slice(index));
    if (number) {
      const end = index + number[0].length;
      flushPlain(index);
      appendCodeToken(tokens, { kind: "number", text: number[0] });
      index = end;
      plainStart = end;
      continue;
    }

    const identifier = /^[A-Za-z_$][A-Za-z0-9_$-]*/.exec(source.slice(index));
    if (identifier) {
      const end = index + identifier[0].length;
      flushPlain(index);
      appendCodeToken(tokens, {
        kind: codeKeywords(normalizedLanguage).has(identifier[0]) ? "keyword" : "plain",
        text: identifier[0],
      });
      index = end;
      plainStart = end;
      continue;
    }

    index += 1;
  }
  flushPlain(source.length);
  return tokens;
}

/** Convert the supported LaTeX subset into real MathML, or expose source fallback. */
export function presentChatMath(source: string, display = false): ChatMathPresentation {
  // ponytail: bound formula parsing to keep malformed/provider-authored math
  // from consuming unbounded renderer or accessibility work.
  if (!source || source.length > CHAT_MATH_INPUT_LIMIT) return { source };
  const parser = new ChatMathParser(source);
  const expression = parser.parse();
  if (!expression || !parser.atEnd()) return { source };
  const displayAttribute = display ? ' display="block"' : "";
  return {
    source,
    mathML: `<math xmlns="http://www.w3.org/1998/Math/MathML"${displayAttribute}>${expression}</math>`,
  };
}

export type ChatToolPresentation =
  | { kind: "plan"; title: string; text: string; filePath?: string }
  | { kind: "edit"; filePath?: string; oldText?: string; newText?: string }
  | { kind: "generic"; summary: string; inputText: string; resultText?: string };

/** Project provider tool payloads into Swift-shaped plan/edit/detail rows. */
export function chatToolPresentation(
  item: Extract<ChatItem, { kind: "tool" }>,
): ChatToolPresentation {
  const name = item.name.toLowerCase();
  const input = item.input;
  const filePath = textField(input, ["file_path", "path"]);
  const oldText = textField(input, ["old_string", "oldText", "old_text"]);
  const newText = textField(input, ["new_string", "newText", "new_text"]);
  if (item.family === "edit" || oldText !== undefined || newText !== undefined || name.includes("edit")) {
    return { kind: "edit", ...(filePath ? { filePath } : {}), ...(oldText ? { oldText } : {}), ...(newText ? { newText } : {}) };
  }

  const planText = textField(input, ["plan", "content", "summary", "description"]);
  const planPath = textField(input, ["planFilePath", "plan_file_path"]);
  if (item.family === "plan_mode" || name.includes("plan")) {
    return {
      kind: "plan",
      title: item.name,
      text: planText ?? item.result ?? "",
      ...(planPath ? { filePath: planPath } : {}),
    };
  }

  return {
    kind: "generic",
    summary: toolSummary(input),
    inputText: safeJSON(input),
    ...(item.result ? { resultText: item.result } : {}),
  };
}

function parseFenceStart(line: string): { marker: string; language?: string } | undefined {
  const match = /^ {0,3}(`{3,}|~{3,})([^\s]*)?.*$/.exec(line);
  if (!match) return undefined;
  const language = match[2]?.replace(/[^a-zA-Z0-9_+#.-]/g, "").slice(0, 32);
  return { marker: match[1]!, ...(language ? { language } : {}) };
}

function isFenceEnd(line: string, marker: string): boolean {
  return new RegExp(`^ {0,3}${marker[0]}{${marker.length},}\\s*$`).test(line);
}

function hasUnclosedInlineFence(value: string): boolean {
  return (value.match(/```/g)?.length ?? 0) % 2 === 1;
}

function isThematicBreak(line: string): boolean {
  return /^ {0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$/.test(line);
}

function parseTable(lines: string[], start: number): { block: Extract<ChatRichBlock, { kind: "table" }>; nextIndex: number } | undefined {
  const divider = lines[start + 1];
  if (!lines[start]!.includes("|") || !isTableDivider(divider)) return undefined;
  const header = splitTableRow(lines[start]!);
  const rows: ChatRichInline[][][] = [];
  let index = start + 2;
  while (index < lines.length && lines[index]!.trim() && lines[index]!.includes("|")) {
    rows.push(splitTableRow(lines[index]!).map((cell) => parseChatRichInline(cell)));
    index += 1;
  }
  return { block: { kind: "table", header: header.map((cell) => parseChatRichInline(cell)), rows }, nextIndex: index };
}

function isTableDivider(line: string | undefined): boolean {
  return Boolean(line && /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line));
}

function splitTableRow(line: string): string[] {
  const trimmed = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  return trimmed.split(/(?<!\\)\|/).map((cell) => cell.replace(/\\\|/g, "|").trim());
}

function parseList(lines: string[], start: number): { block: Extract<ChatRichBlock, { kind: "list" }>; nextIndex: number } | undefined {
  const first = parseListItem(lines[start]!);
  if (!first) return undefined;
  const items: ChatRichInline[][] = [parseChatRichInline(first.text)];
  let index = start + 1;
  while (index < lines.length) {
    const next = parseListItem(lines[index]!);
    if (!next || next.ordered !== first.ordered) break;
    items.push(parseChatRichInline(next.text));
    index += 1;
  }
  return { block: { kind: "list", ordered: first.ordered, items }, nextIndex: index };
}

function parseListItem(line: string): { ordered: boolean; text: string } | undefined {
  const match = /^ {0,3}((?:[-+*])|(?:\d+[.)]))\s+(.*)$/.exec(line);
  if (!match) return undefined;
  return { ordered: /^\d/.test(match[1]!), text: match[2]! };
}

function parseLink(source: string, start: number): { inline: ChatRichInline; nextIndex: number } | undefined {
  if (source[start] !== "[") return undefined;
  const closeLabel = source.indexOf("](", start + 1);
  if (closeLabel < 0) return undefined;
  const closeURL = source.indexOf(")", closeLabel + 2);
  if (closeURL < 0) return undefined;
  const label = source.slice(start + 1, closeLabel);
  if (!label) return undefined;
  const authoredHref = source.slice(closeLabel + 2, closeURL);
  const href = safeChatLink(authoredHref);
  if (href) {
    return { inline: { kind: "link", text: stripInlineMarkers(label), href }, nextIndex: closeURL + 1 };
  }
  const localReference = chatLocalReference(authoredHref, label);
  if (localReference) {
    return {
      inline: { kind: "local-reference", text: localReference.label, href: localReference.path },
      nextIndex: closeURL + 1,
    };
  }
  return undefined;
}

function findMathEnd(source: string, start: number): { openLength: number; closeLength: number; end: number } | undefined {
  const openLength = source.startsWith("$$", start) ? 2 : 1;
  const close = source.indexOf("$".repeat(openLength), start + openLength);
  if (close <= start + openLength) return undefined;
  if (openLength === 1 && /\s/.test(source[start + 1] ?? "")) return undefined;
  return { openLength, closeLength: openLength, end: close };
}

function delimiterAt(source: string, index: number): { marker: string; kind: "strong" | "emphasis" | "strike" } | undefined {
  if (source.startsWith("**", index)) {
    return { marker: "**", kind: "strong" };
  }
  if (source.startsWith("__", index)) {
    return { marker: "__", kind: "strong" };
  }
  if (source.startsWith("~~", index)) return { marker: "~~", kind: "strike" };
  if (source[index] === "*" || source[index] === "_") {
    return { marker: source[index]!, kind: "emphasis" };
  }
  return undefined;
}

function underscoreRunEnd(source: string, index: number): number {
  let runEnd = index;
  while (runEnd < source.length && source[runEnd] === "_") runEnd += 1;
  return runEnd;
}

function isIntrawordUnderscoreRun(source: string, index: number, runEnd: number): boolean {
  const previous = source[index - 1];
  const next = source[runEnd];
  return Boolean(previous && next && /[\p{L}\p{N}]/u.test(previous) && /[\p{L}\p{N}]/u.test(next));
}

function appendInline(result: ChatRichInline[], inline: ChatRichInline): void {
  const previous = result[result.length - 1];
  if (previous?.kind === "text" && inline.kind === "text") {
    previous.text += inline.text;
  } else {
    result.push(inline);
  }
}

function stripInlineMarkers(value: string): string {
  return value.replace(/[*_~`]/g, "");
}

function textField(input: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) if (typeof input[key] === "string" && input[key]) return input[key] as string;
  return undefined;
}

function safeJSON(input: Record<string, unknown>): string {
  try { return JSON.stringify(input, null, 2) ?? "{}"; } catch { return "{}"; }
}

function toolSummary(input: Record<string, unknown>): string {
  for (const key of ["command", "path", "file_path", "query", "description"]) {
    if (typeof input[key] === "string") return input[key] as string;
  }
  return "";
}

function normalizeCodeLanguage(language: string | undefined): "javascript" | "typescript" | "json" | "python" | "bash" | undefined {
  const value = language?.toLowerCase().replace(/[^a-z0-9+#-]/g, "");
  if (!value) return undefined;
  if (["js", "jsx", "javascript", "mjs", "cjs"].includes(value)) return "javascript";
  if (["ts", "tsx", "typescript"].includes(value)) return "typescript";
  if (["json", "jsonc"].includes(value)) return "json";
  if (["py", "python"].includes(value)) return "python";
  if (["sh", "shell", "bash", "zsh", "console"].includes(value)) return "bash";
  return undefined;
}

function codeKeywords(language: "javascript" | "typescript" | "json" | "python" | "bash"): Set<string> {
  if (language === "json") return new Set(["true", "false", "null"]);
  if (language === "python") return new Set([
    "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
    "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
    "in", "is", "lambda", "None", "not", "or", "pass", "raise", "return", "True", "try",
    "while", "with", "yield",
  ]);
  if (language === "bash") return new Set([
    "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in",
    "then", "until", "while", "select", "time",
  ]);
  return new Set([
    "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
    "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from",
    "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new",
    "null", "of", "package", "private", "protected", "public", "return", "static", "super",
    "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void",
    "while", "with", "yield",
  ]);
}

function quotedCodeEnd(source: string, start: number, quote: string): number {
  let index = start + 1;
  while (index < source.length) {
    if (source[index] === "\\") {
      index += 2;
      continue;
    }
    if (source[index] === quote) return index + 1;
    index += 1;
  }
  return source.length;
}

function appendCodeToken(tokens: ChatCodeToken[], token: ChatCodeToken): void {
  const previous = tokens[tokens.length - 1];
  if (previous?.kind === token.kind && (token.kind === "plain" || token.kind === "comment")) {
    previous.text += token.text;
  } else {
    tokens.push(token);
  }
}

const MATH_COMMANDS: Readonly<Record<string, { kind: "mi" | "mo"; value: string }>> = {
  alpha: { kind: "mi", value: "α" },
  beta: { kind: "mi", value: "β" },
  gamma: { kind: "mi", value: "γ" },
  delta: { kind: "mi", value: "δ" },
  epsilon: { kind: "mi", value: "ϵ" },
  theta: { kind: "mi", value: "θ" },
  lambda: { kind: "mi", value: "λ" },
  mu: { kind: "mi", value: "μ" },
  pi: { kind: "mi", value: "π" },
  sigma: { kind: "mi", value: "σ" },
  phi: { kind: "mi", value: "ϕ" },
  omega: { kind: "mi", value: "ω" },
  Gamma: { kind: "mi", value: "Γ" },
  Delta: { kind: "mi", value: "Δ" },
  Lambda: { kind: "mi", value: "Λ" },
  Pi: { kind: "mi", value: "Π" },
  Sigma: { kind: "mi", value: "Σ" },
  Phi: { kind: "mi", value: "Φ" },
  Omega: { kind: "mi", value: "Ω" },
  times: { kind: "mo", value: "×" },
  cdot: { kind: "mo", value: "⋅" },
  pm: { kind: "mo", value: "±" },
  le: { kind: "mo", value: "≤" },
  leq: { kind: "mo", value: "≤" },
  ge: { kind: "mo", value: "≥" },
  geq: { kind: "mo", value: "≥" },
  neq: { kind: "mo", value: "≠" },
  ne: { kind: "mo", value: "≠" },
  to: { kind: "mo", value: "→" },
  rightarrow: { kind: "mo", value: "→" },
  infty: { kind: "mi", value: "∞" },
  sum: { kind: "mo", value: "∑" },
  prod: { kind: "mo", value: "∏" },
  int: { kind: "mo", value: "∫" },
};

class ChatMathParser {
  private index = 0;

  constructor(private readonly source: string) {}

  parse(): string | undefined {
    const expression = this.parseExpression(false);
    return expression || undefined;
  }

  atEnd(): boolean {
    this.skipWhitespace();
    return this.index === this.source.length;
  }

  private parseExpression(stopAtBrace: boolean): string {
    const parts: string[] = [];
    while (this.index < this.source.length) {
      this.skipWhitespace();
      if (this.source[this.index] === "}") {
        if (stopAtBrace) break;
        return "";
      }
      const atom = this.parseAtom();
      if (!atom) return "";
      let scripted = atom;
      let superscript: string | undefined;
      let subscript: string | undefined;
      while (this.source[this.index] === "^" || this.source[this.index] === "_") {
        const marker = this.source[this.index];
        this.index += 1;
        const value = this.parseScriptArgument();
        if (!value) return "";
        if (marker === "^") superscript = value;
        else subscript = value;
      }
      if (superscript && subscript) scripted = `<msubsup>${atom}${subscript}${superscript}</msubsup>`;
      else if (superscript) scripted = `<msup>${atom}${superscript}</msup>`;
      else if (subscript) scripted = `<msub>${atom}${subscript}</msub>`;
      parts.push(scripted);
    }
    if (stopAtBrace) {
      if (this.source[this.index] !== "}") return "";
      this.index += 1;
    }
    return parts.join("");
  }

  private parseAtom(): string | undefined {
    this.skipWhitespace();
    const character = this.source[this.index];
    if (!character) return undefined;
    if (character === "{") {
      this.index += 1;
      const group = this.parseExpression(true);
      return group ? `<mrow>${group}</mrow>` : undefined;
    }
    if (character === "}") return undefined;
    if (character === "\\") return this.parseCommand();
    this.index += 1;
    if (/[A-Za-z]/.test(character)) return `<mi>${escapeMathML(character)}</mi>`;
    if (/[0-9]/.test(character)) {
      let value = character;
      while (/[0-9.]/.test(this.source[this.index] ?? "")) value += this.source[this.index++];
      return `<mn>${escapeMathML(value)}</mn>`;
    }
    if (/[,;:!?=+\-*/<>()[\]|]/.test(character)) return `<mo>${escapeMathML(character)}</mo>`;
    return undefined;
  }

  private parseCommand(): string | undefined {
    this.index += 1;
    const match = /^[A-Za-z]+/.exec(this.source.slice(this.index));
    if (!match) {
      const escaped = this.source[this.index];
      if (!escaped) return undefined;
      this.index += 1;
      return `<mo>${escapeMathML(escaped)}</mo>`;
    }
    this.index += match[0].length;
    const command = match[0];
    if (command === "frac") {
      const numerator = this.parseRequiredGroup();
      const denominator = this.parseRequiredGroup();
      return numerator && denominator ? `<mfrac>${numerator}${denominator}</mfrac>` : undefined;
    }
    if (command === "sqrt") {
      const radicand = this.parseRequiredGroup();
      return radicand ? `<msqrt>${radicand}</msqrt>` : undefined;
    }
    if (command === "text" || command === "mathrm" || command === "mathbf") {
      const value = this.parseTextGroup();
      return value === undefined ? undefined : `<mtext>${escapeMathML(value)}</mtext>`;
    }
    if (command === "left" || command === "right") {
      this.skipWhitespace();
      const delimiter = this.source[this.index];
      if (!delimiter || !"([{}])|.".includes(delimiter)) return undefined;
      this.index += 1;
      return `<mo>${escapeMathML(delimiter === "." ? "" : delimiter)}</mo>`;
    }
    const known = MATH_COMMANDS[command];
    return known ? `<${known.kind}>${escapeMathML(known.value)}</${known.kind}>` : undefined;
  }

  private parseRequiredGroup(): string | undefined {
    this.skipWhitespace();
    if (this.source[this.index] !== "{") return undefined;
    this.index += 1;
    const group = this.parseExpression(true);
    return group ? `<mrow>${group}</mrow>` : undefined;
  }

  private parseTextGroup(): string | undefined {
    this.skipWhitespace();
    if (this.source[this.index] !== "{") return undefined;
    this.index += 1;
    const start = this.index;
    let depth = 1;
    while (this.index < this.source.length && depth > 0) {
      if (this.source[this.index] === "{") depth += 1;
      else if (this.source[this.index] === "}") depth -= 1;
      this.index += 1;
    }
    if (depth !== 0) return undefined;
    return this.source.slice(start, this.index - 1);
  }

  private parseScriptArgument(): string | undefined {
    this.skipWhitespace();
    if (this.source[this.index] === "{") return this.parseRequiredGroup();
    const atom = this.parseAtom();
    return atom ? `<mrow>${atom}</mrow>` : undefined;
  }

  private skipWhitespace(): void {
    while (/\s/.test(this.source[this.index] ?? "")) this.index += 1;
  }
}

function escapeMathML(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
