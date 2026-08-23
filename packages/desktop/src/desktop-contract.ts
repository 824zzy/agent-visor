export type RendererLocation =
  | { kind: "url"; value: string }
  | { kind: "file"; path: string };

export function rendererLocation(base: string): RendererLocation {
  if (base.startsWith("http://") || base.startsWith("https://")) {
    return { kind: "url", value: new URL(base).toString() };
  }
  return { kind: "file", path: base };
}

export function daemonUrlFromReadyMessage(value: unknown): string | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const message = value as Record<string, unknown>;
  if (message.type !== "ready" || typeof message.url !== "string") return undefined;
  return localDaemonUrl(message.url);
}

export type NativeAction =
  | { action: "open_sessions" }
  | { action: "open_owner"; owner: string; sessionId: string };

export function nativeActionFromDaemonMessage(value: unknown): NativeAction | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const message = value as Record<string, unknown>;
  if (message.type !== "native_action") return undefined;
  if (message.action === "open_sessions") return { action: "open_sessions" };
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
  | {
    action: "notify";
    notification: {
      id: string;
      sessionId: string;
      title: string;
      body: string;
      owner: string;
      sound: string;
    };
  };

export function nativeEffectFromDaemonMessage(value: unknown): NativeEffect | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const message = value as Record<string, unknown>;
  if (message.type !== "native_effect") return undefined;
  if (message.action === "request_notifications") return { action: "request_notifications" };
  if (message.action === "notify") {
    const notification = message.notification;
    if (typeof notification !== "object" || notification === null) return undefined;
    const item = notification as Record<string, unknown>;
    if (typeof item.id !== "string" || !item.id || item.id.length > 128
      || typeof item.sessionId !== "string" || !item.sessionId || item.sessionId.length > 128
      || typeof item.title !== "string" || !item.title || item.title.length > 256
      || typeof item.body !== "string" || !item.body || item.body.length > 1_024
      || typeof item.owner !== "string" || !ownerApplication(item.owner)
      || typeof item.sound !== "string" || item.sound.length > 64) return undefined;
    return {
      action: "notify",
      notification: {
        id: item.id,
        sessionId: item.sessionId,
        title: item.title,
        body: item.body,
        owner: item.owner,
        sound: item.sound,
      },
    };
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
