import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const productName = "Agent Visor";
export const electronDataName = "Agent Visor Next";

export function integrationResourcesPath(resourcesPath: string, sourcePath: string): string {
  const bundled = path.join(resourcesPath, "AgentIntegrations");
  return existsSync(bundled) ? bundled : sourcePath;
}

export function windowCloseAction(quitting: boolean): "hide" | "close" {
  return quitting ? "close" : "hide";
}

export type RendererLocation =
  | { kind: "url"; value: string }
  | { kind: "file"; path: string };

export function rendererLocation(base: string): RendererLocation | undefined {
  if (base.startsWith("http://") || base.startsWith("https://")) {
    try {
      const url = new URL(base);
      if (!isApprovedDevRendererURL(url)) return undefined;
      return { kind: "url", value: url.toString() };
    } catch {
      return undefined;
    }
  }
  return { kind: "file", path: path.resolve(base) };
}

/**
 * Check a renderer frame or navigation against the location loaded by the
 * main window. Dev renderers are limited to the explicit loopback origins;
 * packaged renderers must stay on their exact entry file.
 */
export function rendererURLAllowed(location: RendererLocation, value: string): boolean {
  try {
    const url = new URL(value);
    if (location.kind === "url") {
      const expected = new URL(location.value);
      return isApprovedDevRendererURL(url) && url.origin === expected.origin;
    }
    if (url.protocol !== "file:" || url.search || url.hash) return false;
    return path.resolve(fileURLToPath(url)) === path.resolve(location.path);
  } catch {
    return false;
  }
}

/** Validate renderer-requested links before they cross into the host OS. */
export function safeExternalURL(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const raw = value.trim();
  // ponytail: keep renderer-controlled external navigation bounded; extending
  // this cap requires reviewing both IPC and host-app URL handling.
  if (!raw || raw.length > 4_096 || /[\u0000-\u001f\u007f]/.test(raw)) return undefined;
  try {
    const url = new URL(raw);
    return ["http:", "https:", "mailto:"].includes(url.protocol) ? raw : undefined;
  } catch {
    return undefined;
  }
}

function isApprovedDevRendererURL(url: URL): boolean {
  return url.protocol === "http:"
    && (url.hostname === "127.0.0.1" || url.hostname === "localhost")
    && Boolean(url.port)
    && !url.username
    && !url.password
    && !url.hash;
}

export function daemonUrlFromReadyMessage(value: unknown): string | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const message = value as Record<string, unknown>;
  if (message.type !== "ready" || typeof message.url !== "string") return undefined;
  return localDaemonUrl(message.url);
}

export type NativeAction =
  | { action: "open_sessions" }
  | { action: "toggle_sessions" }
  | { action: "open_settings" }
  | { action: "open_chat"; sessionId: string }
  | { action: "open_owner"; owner: string; sessionId: string }
  | { action: "open_session_url"; url: string };

export function nativeActionFromDaemonMessage(value: unknown): NativeAction | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const message = value as Record<string, unknown>;
  if (message.type !== "native_action") return undefined;
  if (message.action === "open_sessions"
    || message.action === "toggle_sessions"
    || message.action === "open_settings") {
    return { action: message.action };
  }
  if (message.action === "open_chat") {
    return typeof message.sessionId === "string"
      && message.sessionId.length > 0
      && message.sessionId.length <= 128
      ? { action: "open_chat", sessionId: message.sessionId }
      : undefined;
  }
  if (message.action === "open_session_url" && typeof message.url === "string") {
    try {
      const url = new URL(message.url);
      return url.protocol === "codex:" && url.hostname === "threads"
        && /^\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(url.pathname)
        ? { action: "open_session_url", url: message.url }
        : undefined;
    } catch { return undefined; }
  }
  if (message.action !== "open_owner"
    || typeof message.owner !== "string"
    || typeof message.sessionId !== "string"
    || !message.sessionId
    || message.sessionId.length > 128
    || !ownerApplication(message.owner)) return undefined;
  return { action: "open_owner", owner: message.owner, sessionId: message.sessionId };
}

export type NativeEffect =
  | { action: "set_login_item"; enabled: boolean }
  | { action: "open_update"; url: string }
  | { action: "request_notifications" }
  | { action: "set_badge"; count: number };

export function nativeEffectFromDaemonMessage(value: unknown): NativeEffect | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const message = value as Record<string, unknown>;
  if (message.type !== "native_effect") return undefined;
  if (message.action === "request_notifications") return { action: "request_notifications" };
  if (message.action === "set_badge") {
    return Number.isInteger(message.count) && Number(message.count) >= 0 && Number(message.count) <= 512
      ? { action: "set_badge", count: Number(message.count) }
      : undefined;
  }
  if (message.action === "set_login_item" && typeof message.enabled === "boolean") {
    return { action: "set_login_item", enabled: message.enabled };
  }
  if (message.action !== "open_update" || typeof message.url !== "string") return undefined;
  try {
    const url = new URL(message.url);
    const valid = url.protocol === "https:"
      && url.hostname === "github.com"
      && /^\/824zzy\/agent-visor\/releases\/tag\/v\d+\.\d+\.\d+$/.test(url.pathname);
    return valid ? { action: "open_update", url: message.url } : undefined;
  } catch {
    return undefined;
  }
}

export function ownerApplication(owner: string): string | undefined {
  return {
    Auggie: "Auggie",
    Claude: "Claude",
    "Claude Code": "Claude",
    Codex: "Codex",
    Cursor: "Cursor",
    Ghostty: "Ghostty",
    iTerm2: "iTerm",
    Pi: "Pi",
    Terminal: "Terminal",
    Zed: "Zed",
  }[owner];
}

export function daemonUrlFromArguments(arguments_: string[]): string | undefined {
  const prefix = "--agent-visor-daemon=";
  const argument = arguments_.find((value) => value.startsWith(prefix));
  return argument ? localDaemonUrl(argument.slice(prefix.length)) : undefined;
}

function localDaemonUrl(value: string): string | undefined {
  try {
    const url = new URL(value);
    const isLocal = url.protocol === "ws:"
      && url.hostname === "127.0.0.1"
      && /^\d+$/.test(url.port)
      && Boolean(url.searchParams.get("token"));
    return isLocal ? value : undefined;
  } catch {
    return undefined;
  }
}
