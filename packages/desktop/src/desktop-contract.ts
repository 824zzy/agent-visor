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
