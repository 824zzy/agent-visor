import os from "node:os";
import type { ProviderAdapter } from "../sessions.js";
import { AuggieProvider } from "./auggie.js";
import { ClaudeProvider, type ClaudePresenceReport } from "./claude.js";
import { CodexProvider } from "./codex.js";
import { CursorProvider } from "./cursor.js";
import { LiveProviderEnvironment, type GhosttyTerminalView } from "./environment.js";
import type { CodexHome } from "./codex-instances.js";
import { PiProvider } from "./pi.js";
import { ZedProvider } from "./zed.js";
import { PaseoProvider } from "./paseo.js";
import { PaseoClient } from "./paseo-client.js";

export function liveProviders(
  home = os.homedir(),
  observedWindowMs?: number | (() => number),
  codexHomes: () => CodexHome[] = () => [],
  saveDiscoveredCodexHome?: (home: CodexHome) => Promise<void>,
  ignoredCodexHomes: () => string[] = () => [],
  ghosttyTerminalViews?: (conversationTitles?: readonly string[]) => Promise<GhosttyTerminalView[]>,
  reportClaudePresence?: (report: ClaudePresenceReport) => void,
): ProviderAdapter[] {
  const environment = new LiveProviderEnvironment(home, { observedWindowMs, ghosttyTerminalViews });
  return [
    new PaseoProvider(new PaseoClient(home)),
    new ClaudeProvider(environment, reportClaudePresence),
    new CodexProvider(environment, codexHomes, saveDiscoveredCodexHome, ignoredCodexHomes),
    new PiProvider(environment),
    new CursorProvider(environment),
    new ZedProvider(environment),
    new AuggieProvider(environment),
  ];
}
