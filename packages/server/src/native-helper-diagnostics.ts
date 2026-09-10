import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

// Only protocol field names and enum tags can appear verbatim in diagnostics.
// Session IDs, titles, command text, paths, and arbitrary extra keys never do.
const fields = new Set([
  "version", "id", "ok", "type", "event", "result", "error", "code", "message",
  "sessionId", "toolUseId", "intent", "action", "status", "trusted", "screens",
  "displayId", "name", "isBuiltIn", "frame", "visibleFrame", "scale", "isMain",
  "x", "y", "width", "height",
]);
const tags = new Set([
  "event", "activate_pill", "open_sessions", "toggle_sessions", "open_settings",
  "refresh_usage", "notification_permission", "notification_action", "standard", "chat",
  "activate", "approve", "deny", "not_determined", "denied", "authorized",
  "accepted", "screen_topology", "accessibility_status", "notification_status",
  "invalid_request", "unsupported", "failed",
]);
const tagFields = new Set(["type", "event", "code", "intent", "action", "status"]);

type Issue = { code: string; path: PropertyKey[]; errors?: Issue[][] };

export async function saveNativeHelperDiagnostic(
  dataRoot: string,
  kind: "invalid_response" | "invalid_json" | "oversized_frame",
  frameBytes: number,
  value: unknown,
  issues: readonly Issue[],
  pendingMethods: string[],
): Promise<void> {
  const paths: Array<{ code: string; path: Array<string | number> }> = [];
  function collect(values: readonly Issue[]) {
    for (const issue of values) {
      if (paths.length >= 12) break;
      if (issue.errors) {
        for (const branch of issue.errors) collect(branch);
      } else {
        paths.push({ code: issue.code, path: issue.path.slice(0, 8).map(key =>
          typeof key === "number" ? key : fields.has(String(key)) ? String(key) : "[field]",
        ) });
      }
    }
  }
  collect(issues);
  const diagnostic = {
    observedAt: new Date().toISOString(), kind, frameBytes,
    pendingMethods: [...new Set(pendingMethods)].slice(0, 8),
    issues: paths, shape: describe(value, "", { remaining: 60 }),
  };
  let text = JSON.stringify(diagnostic, null, 2);
  if (Buffer.byteLength(text) > 16_384) text = JSON.stringify({ ...diagnostic, shape: "[omitted]" });
  const directory = path.join(dataRoot, "diagnostics");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await writeFile(path.join(directory, "native-helper-protocol-error.json"), text, { mode: 0o600 });
}

function describe(value: unknown, field: string, budget: { remaining: number }): unknown {
  if (budget.remaining-- <= 0) return "[omitted]";
  if (value === null) return { type: "null" };
  if (typeof value === "string") return {
    type: "string", length: value.length, bytes: Buffer.byteLength(value),
    ...(tagFields.has(field) && tags.has(value) ? { tag: value } : {}),
  };
  if (typeof value === "number") return {
    type: "number", integer: Number.isInteger(value), negative: value < 0,
    ...(field === "version" ? { value } : {}),
  };
  if (typeof value !== "object") return { type: typeof value };
  if (Array.isArray(value)) return {
    type: "array", length: value.length,
    ...(value.length ? { first: describe(value[0], "", budget) } : {}),
  };
  const entries = Object.entries(value);
  return {
    type: "object",
    extraFields: entries.filter(([key]) => !fields.has(key)).length,
    fields: Object.fromEntries(entries.filter(([key]) => fields.has(key)).slice(0, 16)
      .map(([key, child]) => [key, describe(child, key, budget)])),
  };
}
