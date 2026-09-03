const openTag = "<oai-mem-citation>";
const entry = /^[^<>|\r\n]+:\d+(?:-\d+)?\|note=\[[^\r\n]*\]$/;
const rollout = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

/**
 * Codex appends structured memory provenance to assistant output. Normalize
 * it before canonical items, paging, and accessibility, leaving source files
 * untouched. This is not a general XML filter: quoted examples and malformed
 * envelopes retain their exact text, as do messages from other providers.
 */
export function normalizeCodexAssistantText(source: string): string {
  return presentDirectives(stripMemoryCitations(source));
}

function stripMemoryCitations(source: string): string {
  if (!source.includes(openTag)) return source;
  const protectedRanges = literalRanges(source);
  const retained: string[] = [];
  let cursor = 0;
  let search = 0;
  let protectedIndex = 0;
  while (search < source.length) {
    const start = source.indexOf(openTag, search);
    if (start < 0) break;
    search = start + openTag.length;
    while (protectedRanges[protectedIndex] && protectedRanges[protectedIndex]![1] <= start) protectedIndex += 1;
    const protectedRange = protectedRanges[protectedIndex];
    if (protectedRange && protectedRange[0] <= start) continue;
    const end = citationEnd(source, search);
    if (end === undefined) continue;
    retained.push(source.slice(cursor, start));
    cursor = end;
    search = end;
  }
  if (cursor === 0) return source;
  retained.push(source.slice(cursor));
  return retained.map((part, index) => {
    // Remove separators belonging to the metadata without changing leading
    // indentation in an answer or in a following indented code block.
    const withoutBlankLines = index === 0 ? part : part.replace(/^(?:[ \t]*\r?\n)+/, "");
    return withoutBlankLines.trimEnd();
  }).filter((part) => part.trim()).join("\n\n");
}

/** Native review/task cards become inert readable text, never local actions. */
function presentDirectives(source: string): string {
  if (!/(?:^|\n) {0,3}::(?:code-comment|inbox-item)\{/.test(source)) return source;
  const protectedRanges = literalRanges(source);
  return source.replace(/^ {0,3}::(code-comment|inbox-item)\{([^\r\n]*)\}[ \t]*$/gm, (raw, name: string, attributes: string, offset: number) => {
    if (protectedRanges.some(([start, end]) => start <= offset && offset < end)) return raw;
    const values = directiveAttributes(attributes);
    if (!values || typeof values.title !== "string" || !values.title.trim()) return raw;
    if (name === "inbox-item") {
      if (typeof values.summary !== "string" || Object.keys(values).some((key) => !["title", "summary"].includes(key))) return raw;
      return `**${values.title}**\n\n${values.summary}`;
    }
    if (typeof values.body !== "string" || typeof values.file !== "string" || !values.file.trim()
      || Object.keys(values).some((key) => !["title", "body", "file", "start", "end", "priority"].includes(key))) return raw;
    for (const key of ["start", "end"]) {
      const value = values[key];
      if (value !== undefined && (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1)) return raw;
    }
    if (values.end !== undefined && (values.start === undefined || Number(values.end) < Number(values.start))) return raw;
    if (values.priority !== undefined && (typeof values.priority !== "number" || ![0, 1, 2, 3].includes(values.priority))) return raw;
    const location = `${values.file}${values.start === undefined ? "" : `:${values.start}${values.end === undefined ? "" : `-${values.end}`}`}`;
    return `**${values.title}**\n\n${values.body}\n\nLocation: ${location}${values.priority === undefined ? "" : `\nPriority: ${values.priority}`}`;
  });
}

function directiveAttributes(source: string): Record<string, string | number> | undefined {
  const values: Record<string, string | number> = Object.create(null) as Record<string, string | number>;
  let remainder = source.trim();
  while (remainder) {
    const match = /^([a-zA-Z_]+)=("(?:[^"\\]|\\.)*"|-?\d+)(?:\s+|$)/.exec(remainder);
    if (!match || Object.hasOwn(values, match[1]!)) return undefined;
    try { values[match[1]!] = JSON.parse(match[2]!) as string | number; } catch { return undefined; }
    remainder = remainder.slice(match[0].length);
  }
  return values;
}

/** Full envelopes and valid prefixes of a streaming trailer share a grammar. */
function citationEnd(source: string, start: number): number | undefined {
  let cursor = start;
  let partial = false;
  const token = (expected: string): boolean => {
    cursor += /^\s*/.exec(source.slice(cursor))![0].length;
    if (source.startsWith(expected, cursor)) { cursor += expected.length; return true; }
    if (expected.startsWith(source.slice(cursor))) { partial = true; cursor = source.length; return true; }
    return false;
  };
  const rows = (closing: string, complete: RegExp, prefix: RegExp): boolean => {
    const close = source.indexOf(closing, cursor);
    if (close >= 0) {
      const values = source.slice(cursor, close).split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
      if (!values.every((value) => complete.test(value))) return false;
      cursor = close + closing.length;
      return true;
    }
    const lines = source.slice(cursor).split(/\r?\n/);
    const last = lines.pop()!.trim();
    if (!lines.every((line) => !line.trim() || complete.test(line.trim()))) return false;
    if (last && !closing.startsWith(last) && !prefix.test(last)) return false;
    partial = true;
    cursor = source.length;
    return true;
  };
  if (!token("<citation_entries>")) return undefined;
  if (partial) return cursor;
  if (!rows("</citation_entries>", entry, /^[^<>\r\n]*$/)) return undefined;
  if (partial) return cursor;
  if (!token("<rollout_ids>")) return undefined;
  if (partial) return cursor;
  if (!rows("</rollout_ids>", rollout, /^[0-9a-f-]*$/i)) return undefined;
  if (partial) return cursor;
  if (!token("</oai-mem-citation>")) return undefined;
  return cursor;
}

function literalRanges(source: string): Array<[number, number]> {
  const ranges: Array<[number, number]> = [];
  let offset = 0;
  let fence: string | undefined;
  for (const line of source.split("\n")) {
    const marker = /^ {0,3}(`{3,}|~{3,})/.exec(line)?.[1];
    if (fence) {
      ranges.push([offset, offset + line.length + 1]);
      if (marker && marker[0] === fence[0] && marker.length >= fence.length
        && !line.slice(line.indexOf(marker) + marker.length).trim()) fence = undefined;
    } else if (marker) {
      fence = marker;
      ranges.push([offset, offset + line.length + 1]);
    } else if (/^(?: {4}|\t| {0,3}>)/.test(line)) {
      ranges.push([offset, offset + line.length + 1]);
    }
    offset += line.length + 1;
  }
  let protectedIndex = 0;
  const ticks = [...source.matchAll(/`+/g)].filter((tick) => {
    while (ranges[protectedIndex] && ranges[protectedIndex]![1] <= tick.index!) protectedIndex += 1;
    const range = ranges[protectedIndex];
    return !range || tick.index! < range[0];
  });
  const nextMatching = new Map<number, number>();
  const closing = new Map<number, number>();
  for (let index = ticks.length - 1; index >= 0; index -= 1) {
    const length = ticks[index]![0].length;
    const next = nextMatching.get(length);
    if (next !== undefined) closing.set(index, next);
    nextMatching.set(length, index);
  }
  for (let index = 0; index < ticks.length; index += 1) {
    const first = ticks[index]!;
    const endIndex = closing.get(index);
    if (endIndex === undefined) continue;
    const last = ticks[endIndex]!;
    ranges.push([first.index!, last.index! + last[0].length]);
    index = endIndex;
  }
  return ranges.sort((a, b) => a[0] - b[0]);
}
